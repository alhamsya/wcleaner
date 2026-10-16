import XCTest
@testable import WCleanerCore

/// Real Git against disposable repositories only.
final class GitIntegrationTests: XCTestCase {
    private var fixture: TemporaryGitRepository!
    private let git = TemporaryGitRepository.client

    override func setUpWithError() throws {
        fixture = try TemporaryGitRepository()
    }

    override func tearDown() {
        fixture?.cleanup()
    }

    func testWorktreeListParsesRealOutputIncludingSpaces() async throws {
        let spaced = try fixture.addWorktree("wt with spaces & symbols", branch: "feature/space")
        let records = try await git.worktreeList(repositoryPath: fixture.repositoryPath)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, fixture.repositoryPath)
        XCTAssertEqual(records[0].branchName, "main")
        XCTAssertEqual(records[1].path, spaced)
        XCTAssertEqual(records[1].branchName, "feature/space")
        XCTAssertEqual(records[1].head, try fixture.head())
    }

    func testLockedAndDetachedWorktreesAreReported() async throws {
        let detached = fixture.root + "/detached"
        try fixture.git(["worktree", "add", "-q", "--detach", detached])
        try fixture.git(["worktree", "lock", "--reason", "external\ndrive", detached])
        let records = try await git.worktreeList(repositoryPath: fixture.repositoryPath)
        let record = try XCTUnwrap(records.first { $0.path == detached })
        XCTAssertTrue(record.isDetached)
        XCTAssertTrue(record.isLocked)
        XCTAssertEqual(record.lockReason, "external\ndrive")
    }

    func testPrunableWorktreeIsReported() async throws {
        let path = try fixture.addWorktree("gone", branch: "gone")
        try FileManager.default.removeItem(atPath: path)
        let records = try await git.worktreeList(repositoryPath: fixture.repositoryPath)
        XCTAssertTrue(try XCTUnwrap(records.first { $0.path == path }).isPrunable)
    }

    func testInspectionOfCleanWorktree() async throws {
        let path = try fixture.addWorktree("clean", branch: "clean")
        let record = try await git.worktreeList(repositoryPath: fixture.repositoryPath).first { $0.path == path }!
        let inspection = await WorktreeInspector(git: git).inspect(record: record, commonDirectory: try fixture.commonDirectory(), depth: .deep)
        XCTAssertTrue(inspection.exists)
        XCTAssertEqual(inspection.gitFileStatus, .valid)
        XCTAssertFalse(inspection.isSymlinkAmbiguous)
        XCTAssertEqual(inspection.status?.isCompletelyClean, true)
        XCTAssertEqual(inspection.headSHA, record.head)
        XCTAssertEqual(inspection.hasGitlinks, false)
        XCTAssertTrue(inspection.operationsInProgress.isEmpty)
    }

    func testInspectionDetectsUntrackedIgnoredAndModifiedFiles() async throws {
        let path = try fixture.addWorktree("dirty", branch: "dirty")
        try fixture.write(".gitignore", "*.log\nbuild/\n", in: path)
        try fixture.git(["add", ".gitignore"], in: path)
        try fixture.git(["commit", "-q", "-m", "ignore"], in: path)
        let records = try await git.worktreeList(repositoryPath: fixture.repositoryPath)
        let record = try XCTUnwrap(records.first { $0.path == path })
        let inspector = WorktreeInspector(git: git)
        let common = try fixture.commonDirectory()

        var inspection = await inspector.inspect(record: record, commonDirectory: common, depth: .standard)
        XCTAssertEqual(inspection.status?.isCompletelyClean, true)

        try fixture.write("debug.log", "ignored but valuable\n", in: path)
        inspection = await inspector.inspect(record: record, commonDirectory: common, depth: .standard)
        XCTAssertEqual(inspection.status?.ignoredCount, 1, "Ignored files must be detected explicitly")

        try fixture.write("build/output.bin", "x", in: path)
        try fixture.write("notes.txt", "untracked\n", in: path)
        try fixture.write("README.md", "changed\n", in: path)
        inspection = await inspector.inspect(record: record, commonDirectory: common, depth: .standard)
        XCTAssertEqual(inspection.status?.untrackedCount, 1)
        XCTAssertEqual(inspection.status?.unstagedCount, 1)
        XCTAssertEqual(inspection.status?.ignoredCount, 2)
    }

    func testInspectionDetectsInProgressOperationAndGitmodules() async throws {
        let path = try fixture.addWorktree("ops", branch: "ops")
        let records = try await git.worktreeList(repositoryPath: fixture.repositoryPath)
        let record = try XCTUnwrap(records.first { $0.path == path })
        let common = try fixture.commonDirectory()
        let gitDirectory = common + "/worktrees/ops"
        FileManager.default.createFile(atPath: gitDirectory + "/MERGE_HEAD", contents: Data(try fixture.head().utf8))
        try fixture.write(".gitmodules", "[submodule \"x\"]\n", in: path)
        let inspection = await WorktreeInspector(git: git).inspect(record: record, commonDirectory: common, depth: .standard)
        XCTAssertEqual(inspection.operationsInProgress, ["merge"])
        XCTAssertTrue(inspection.hasGitmodulesFile)
    }

    func testIndependentRepositoryIsNotALinkedWorktree() async throws {
        let other = try TemporaryGitRepository(name: "other")
        defer { other.cleanup() }
        let record = WorktreeRecord(path: other.repositoryPath, head: try other.head(), branchRef: "refs/heads/main")
        let inspection = await WorktreeInspector(git: git).inspect(record: record, commonDirectory: try fixture.commonDirectory(), depth: .standard)
        XCTAssertEqual(inspection.gitFileStatus, .isDirectory)
    }

    func testWorktreeOfAnotherRepositoryIsRejected() async throws {
        let other = try TemporaryGitRepository(name: "other")
        defer { other.cleanup() }
        let foreign = try other.addWorktree("foreign", branch: "foreign")
        let record = WorktreeRecord(path: foreign, head: try other.head(of: foreign), branchRef: "refs/heads/foreign")
        let inspection = await WorktreeInspector(git: git).inspect(record: record, commonDirectory: try fixture.commonDirectory(), depth: .standard)
        guard case .mismatch = inspection.gitFileStatus else {
            return XCTFail("Expected mismatch, got \(inspection.gitFileStatus)")
        }
    }

    func testSymlinkedPathIsAmbiguous() async throws {
        let path = try fixture.addWorktree("real", branch: "real")
        let link = fixture.root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        let record = WorktreeRecord(path: link, head: try fixture.head(of: path), branchRef: "refs/heads/real")
        let inspection = await WorktreeInspector(git: git).inspect(record: record, commonDirectory: try fixture.commonDirectory(), depth: .standard)
        XCTAssertTrue(inspection.isSymlinkAmbiguous)
    }

    func testRemotesAndUpstreamAreRead() async throws {
        try fixture.git(["remote", "add", "origin", "https://user:ghp_secret@github.com/octo/repo.git"])
        try fixture.git(["remote", "add", "upstream", "git@github.com:upstream/repo.git"])
        let path = try fixture.addWorktree("tracked", branch: "feature/x")
        try fixture.git(["config", "branch.feature/x.remote", "origin"], in: path)
        try fixture.git(["config", "branch.feature/x.merge", "refs/heads/feature/renamed"], in: path)

        let remotes = try await git.remotes(repositoryPath: fixture.repositoryPath)
        XCTAssertEqual(Set(remotes.map(\.name)), ["origin", "upstream"])
        XCTAssertFalse(remotes.contains { $0.url.contains("ghp_secret") }, "Credentials in remote URLs must be stripped")

        let upstream = try await git.upstream(branch: "feature/x", repositoryPath: fixture.repositoryPath)
        XCTAssertEqual(upstream, BranchUpstream(remoteName: "origin", remoteBranch: "feature/renamed"))
        let none = try await git.upstream(branch: "main", repositoryPath: fixture.repositoryPath)
        XCTAssertNil(none)
    }
}

final class RepositoryRegistryTests: XCTestCase {
    private var fixture: TemporaryGitRepository!
    private var dataDirectory: AppDataDirectory!

    override func setUpWithError() throws {
        fixture = try TemporaryGitRepository()
        dataDirectory = AppDataDirectory(url: URL(fileURLWithPath: fixture.root + "/appdata"))
    }

    override func tearDown() {
        fixture?.cleanup()
    }

    private func makeRegistry() -> RepositoryRegistry {
        RepositoryRegistry(store: JSONFileStore(directory: dataDirectory, fileName: "repositories.json"), git: TemporaryGitRepository.client)
    }

    func testAddPersistsCanonicalRepository() async throws {
        let registry = makeRegistry()
        let repository = try await registry.add(path: fixture.repositoryPath + "/")
        XCTAssertEqual(repository.path, fixture.repositoryPath)
        XCTAssertEqual(repository.commonDirectory, try fixture.commonDirectory())
        XCTAssertEqual(repository.displayName, "repo")

        let reloaded = await makeRegistry().all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, repository.id)
        XCTAssertEqual(reloaded.first?.path, repository.path)
        XCTAssertEqual(reloaded.first?.commonDirectory, repository.commonDirectory)
        XCTAssertEqual(reloaded.first?.addedAt.timeIntervalSince1970 ?? 0, repository.addedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAddingALinkedWorktreeRegistersThePrimaryAndDeduplicates() async throws {
        let linked = try fixture.addWorktree("linked", branch: "linked")
        let registry = makeRegistry()
        let repository = try await registry.add(path: linked)
        XCTAssertEqual(repository.path, fixture.repositoryPath)
        do {
            try await registry.add(path: fixture.repositoryPath)
            XCTFail("Expected duplicate rejection")
        } catch let error as RepositoryRegistryError {
            XCTAssertEqual(error, .alreadyRegistered("repo"))
        }
    }

    func testRejectsNonRepositoryAndMissingPaths() async throws {
        let registry = makeRegistry()
        let plain = fixture.root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        await XCTAssertThrowsErrorAsync(try await registry.add(path: plain))
        await XCTAssertThrowsErrorAsync(try await registry.add(path: fixture.root + "/missing"))
    }

    func testRemove() async throws {
        let registry = makeRegistry()
        let repository = try await registry.add(path: fixture.repositoryPath)
        try await registry.remove(id: repository.id)
        let all = await registry.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testScannerDetectsReplacedRepository() async throws {
        let registry = makeRegistry()
        var repository = try await registry.add(path: fixture.repositoryPath)
        let scanner = WorktreeScanner(git: TemporaryGitRepository.client)
        let records = try await scanner.scan(repository)
        XCTAssertEqual(records.count, 1)

        repository.commonDirectory = "/somewhere/else/.git"
        do {
            _ = try await scanner.scan(repository)
            XCTFail("Expected repositoryChanged")
        } catch let error as WorktreeScanner.ScanError {
            XCTAssertEqual(error, .repositoryChanged(repository.path))
        }
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
