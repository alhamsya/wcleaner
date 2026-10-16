import XCTest
@testable import WCleanerCore

/// Runs only in a fresh folder under the temporary directory, deleted afterwards.
final class NestedGitScannerTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WCleanerTests-nested-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/wt", withIntermediateDirectories: true)
        try "gitdir: /elsewhere\n".write(toFile: root + "/wt/.git", atomically: true, encoding: .utf8)
        try "readme\n".write(toFile: root + "/wt/README.md", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func make(_ relative: String, directory: Bool = true) throws {
        let path = root + "/wt/" + relative
        if directory {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func testGitNamesInAnyCaseAndWithIgnorableCodePoints() {
        XCTAssertTrue(NestedGitScanner.isGitName(".git"))
        XCTAssertTrue(NestedGitScanner.isGitName(".GIT"))
        XCTAssertTrue(NestedGitScanner.isGitName(".Git"))
        XCTAssertTrue(NestedGitScanner.isGitName(".g\u{200C}it"))
        XCTAssertTrue(NestedGitScanner.isGitName("\u{FEFF}.git"))
        XCTAssertFalse(NestedGitScanner.isGitName(".gitignore"))
        XCTAssertFalse(NestedGitScanner.isGitName("git"))
        XCTAssertFalse(NestedGitScanner.isGitName(".github"))
    }

    func testCleanWorktreeHasNoNestedEntriesAndTopLevelGitFileIsIgnored() throws {
        try make("src/main.swift", directory: false)
        try make(".github/workflows")
        XCTAssertEqual(try NestedGitScanner.scan(worktreePath: root + "/wt"), [])
    }

    func testNestedGitFoldersAndFilesAreFound() throws {
        try make("docs/.git/notes.txt", directory: false)
        try make("vendor/lib/.GIT")
        try make("tools/.git", directory: false)
        let found = try NestedGitScanner.scan(worktreePath: root + "/wt").sorted()
        XCTAssertEqual(found, ["docs/.git", "tools/.git", "vendor/lib/.GIT"])
    }

    func testSymbolicLinksAreNotFollowed() throws {
        try FileManager.default.createDirectory(atPath: root + "/outside/.git", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/wt/linked", withDestinationPath: root + "/outside")
        XCTAssertEqual(try NestedGitScanner.scan(worktreePath: root + "/wt"), [])

        try FileManager.default.createSymbolicLink(atPath: root + "/wt/src-.git-link", withDestinationPath: root + "/outside")
        try FileManager.default.createDirectory(atPath: root + "/wt/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/wt/sub/.git", withDestinationPath: root + "/outside/.git")
        XCTAssertEqual(try NestedGitScanner.scan(worktreePath: root + "/wt"), ["sub/.git"], "A symlink named .git is reported")
    }

    /// Regression: skipping the descendants of a file or symlink must not skip a sibling folder. Many
    /// folders make the result independent of the order in which the file system lists them.
    func testEveryFolderIsScannedWhateverTheListingOrder() throws {
        try FileManager.default.createDirectory(atPath: root + "/outside", withIntermediateDirectories: true)
        var expected: [String] = []
        for index in 0..<40 {
            try make("pkg\(index)/deep/.git")
            expected.append("pkg\(index)/deep/.git")
            try FileManager.default.createSymbolicLink(atPath: root + "/wt/link\(index)", withDestinationPath: root + "/outside")
            try make("file\(index).txt", directory: false)
        }
        let found = try NestedGitScanner.scan(worktreePath: root + "/wt", reportLimit: 100).sorted()
        XCTAssertEqual(found, expected.sorted())
    }

    func testLimitsFailClosed() throws {
        try make("a/b/c/d", directory: true)
        XCTAssertThrowsError(try NestedGitScanner.scan(worktreePath: root + "/wt", maximumEntries: 3)) { error in
            XCTAssertEqual(error as? NestedGitScanner.ScanError, .tooManyEntries(3))
        }
    }

    func testUnreadableFolderFailsClosed() throws {
        try make("private/inner", directory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/wt/private")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/wt/private") }
        XCTAssertThrowsError(try NestedGitScanner.scan(worktreePath: root + "/wt"))
    }
}
