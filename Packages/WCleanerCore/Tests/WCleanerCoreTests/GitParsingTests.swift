import XCTest
@testable import WCleanerCore

final class GitStatusParserTests: XCTestCase {
    private func nul(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            data.append(contentsOf: Array(field.utf8))
            data.append(0)
        }
        return data
    }

    func testCleanStatus() throws {
        let summary = try GitStatusParser.parse(nul([
            "# branch.oid 43683ef15bec5e7cbe594744b911ec0d40afa752",
            "# branch.head feat/x",
            "# branch.upstream origin/feat/x",
            "# branch.ab +0 -3",
        ]))
        XCTAssertTrue(summary.isCompletelyClean)
        XCTAssertEqual(summary.branchHead, "feat/x")
        XCTAssertEqual(summary.upstream, "origin/feat/x")
        XCTAssertEqual(summary.ahead, 0)
        XCTAssertEqual(summary.behind, 3)
    }

    func testCountsEveryKindOfChange() throws {
        let summary = try GitStatusParser.parse(nul([
            "# branch.head main",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
            "1 .M N... 100644 100644 100644 aaaa bbbb unstaged file.txt",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt",
            "1 .M SC.. 160000 160000 160000 aaaa bbbb vendor/sub",
            "? untracked dir/",
            "! node_modules/",
            "! build.log",
        ]))
        XCTAssertEqual(summary.stagedCount, 2)
        XCTAssertEqual(summary.unstagedCount, 2)
        XCTAssertEqual(summary.unmergedCount, 1)
        XCTAssertEqual(summary.untrackedCount, 1)
        XCTAssertEqual(summary.ignoredCount, 2)
        XCTAssertEqual(summary.submoduleChangeCount, 1)
        XCTAssertFalse(summary.isCompletelyClean)
    }

    func testListsIgnoredPathsUpToTheLimit() throws {
        let summary = try GitStatusParser.parse(nul(["! node_modules/", "! dir with space/.env"]))
        XCTAssertEqual(summary.ignoredPaths, ["node_modules/", "dir with space/.env"])
        XCTAssertTrue(summary.ignoredPathsComplete)

        let many = (0...GitStatusSummary.ignoredPathLimit).map { "! file\($0).log" }
        let truncated = try GitStatusParser.parse(nul(many))
        XCTAssertEqual(truncated.ignoredCount, GitStatusSummary.ignoredPathLimit + 1)
        XCTAssertEqual(truncated.ignoredPaths.count, GitStatusSummary.ignoredPathLimit)
        XCTAssertFalse(truncated.ignoredPathsComplete)
    }

    func testListsChangedPathsForDisplay() throws {
        let summary = try GitStatusParser.parse(nul([
            "1 .M N... 100644 100644 100644 aaaa bbbb dir/unstaged file.txt",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt",
            "? notes/",
            "! ignored.log",
        ]))
        XCTAssertEqual(summary.changedPaths, ["dir/unstaged file.txt", "new name.txt", "conflict.txt", "notes/"])
    }

    func testIgnoredEntryWithoutPathFailsClosed() {
        XCTAssertThrowsError(try GitStatusParser.parse(nul(["!"])))
        XCTAssertThrowsError(try GitStatusParser.parse(nul(["! "])))
    }

    func testIgnoredOnlyIsNotClean() throws {
        let summary = try GitStatusParser.parse(nul(["! .env"]))
        XCTAssertFalse(summary.isCompletelyClean)
    }

    func testUnknownEntryFailsClosed() {
        XCTAssertThrowsError(try GitStatusParser.parse(nul(["Z mystery"])))
    }

    func testTruncatedRenameFailsClosed() {
        XCTAssertThrowsError(try GitStatusParser.parse(nul(["2 R. N... 100644 100644 100644 aaaa bbbb R100 new.txt"])))
    }
}

final class RemoteURLParserTests: XCTestCase {
    func testParsesCommonGitHubRemoteForms() {
        let expected = HostedRepositoryRef(host: "github.com", owner: "alhamsya", name: "wcleaner")
        let forms = [
            "https://github.com/alhamsya/wcleaner",
            "https://github.com/alhamsya/wcleaner.git",
            "https://github.com/alhamsya/wcleaner/",
            "git@github.com:alhamsya/wcleaner.git",
            "github.com:alhamsya/wcleaner",
            "ssh://git@github.com/alhamsya/wcleaner.git",
            "git://github.com/alhamsya/wcleaner.git",
            "https://ghp_secret@github.com/alhamsya/wcleaner.git",
            "https://user:pass@github.com/alhamsya/wcleaner.git",
        ]
        for form in forms {
            XCTAssertEqual(RemoteURLParser.parse(form), expected, form)
        }
    }

    func testSSHOverHTTPSPort() {
        let ref = RemoteURLParser.parse("ssh://git@ssh.github.com:443/octo/repo.git")
        XCTAssertEqual(ref?.host, "ssh.github.com")
        XCTAssertEqual(ref?.fullName, "octo/repo")
    }

    func testHostAliasIsPreservedForLaterResolution() {
        XCTAssertEqual(RemoteURLParser.parse("git@github-work:octo/repo.git")?.host, "github-work")
    }

    func testRejectsNonRepositoryPaths() {
        XCTAssertNil(RemoteURLParser.parse("https://github.com/alhamsya"))
        XCTAssertNil(RemoteURLParser.parse("https://github.com/a/b/c"))
        XCTAssertNil(RemoteURLParser.parse("/local/path/repo.git"))
        XCTAssertNil(RemoteURLParser.parse("file:///tmp/repo.git"))
        XCTAssertNil(RemoteURLParser.parse("https://github.com/../etc"))
        XCTAssertNil(RemoteURLParser.parse("https://github.com/own er/repo"))
        XCTAssertNil(RemoteURLParser.parse(""))
    }

    func testCredentialsAreRedacted() {
        XCTAssertEqual(
            RemoteURLParser.redactingCredentials("https://user:ghp_secret@github.com/a/b.git"),
            "https://github.com/a/b.git"
        )
        XCTAssertEqual(
            RemoteURLParser.redactingCredentials("https://ghp_secret@github.com/a/b.git"),
            "https://github.com/a/b.git"
        )
        XCTAssertEqual(
            RemoteURLParser.redactingCredentials("ssh://git@github.com/a/b.git"),
            "ssh://git@github.com/a/b.git"
        )
        XCTAssertFalse(GitRemote(name: "origin", url: "https://x:ghp_secret@github.com/a/b").url.contains("ghp_secret"))
    }

    func testParsesGitConfigOutput() {
        var data = Data("remote.origin.url\nhttps://github.com/a/b.git".utf8)
        data.append(0)
        data.append(contentsOf: Array("remote.up.stream.url\ngit@github.com:c/d.git".utf8))
        data.append(0)
        let remotes = GitRemote.parseConfigOutput(data)
        XCTAssertEqual(remotes, [
            GitRemote(name: "origin", url: "https://github.com/a/b.git"),
            GitRemote(name: "up.stream", url: "git@github.com:c/d.git"),
        ])
    }
}

final class PathCanonicalizerTests: XCTestCase {
    func testStandardizeDoesNotStripPrivatePrefix() {
        XCTAssertEqual(PathCanonicalizer.standardize("/private/tmp/x/"), "/private/tmp/x")
        XCTAssertEqual(PathCanonicalizer.standardize("/a//b/./c/../d"), "/a/b/d")
    }

    func testInsideComparesWholeComponents() {
        XCTAssertTrue(PathCanonicalizer.isPath("/a/b/c", inside: "/a/b"))
        XCTAssertTrue(PathCanonicalizer.isPath("/a/b", inside: "/a/b"))
        XCTAssertFalse(PathCanonicalizer.isPath("/a/bc", inside: "/a/b"))
        XCTAssertFalse(PathCanonicalizer.isPath("/a", inside: "/a/b"))
    }

    func testRealPathResolvesSymlinks() throws {
        let resolved = PathCanonicalizer.realPath("/tmp")
        XCTAssertEqual(resolved, "/private/tmp")
        XCTAssertNil(PathCanonicalizer.realPath("/definitely/not/here"))
    }
}

final class GitVersionTests: XCTestCase {
    func testParsesAppleAndHomebrewVersions() {
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.39.5 (Apple Git-154)\n"), GitVersion(major: 2, minor: 39, patch: 5))
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.47.0"), GitVersion(major: 2, minor: 47, patch: 0))
        XCTAssertNil(GitVersion(versionOutput: "garbage"))
        XCTAssertTrue(GitVersion(major: 2, minor: 35, patch: 9) < GitClient.minimumVersion)
    }

    func testEnvironmentIsAllowListed() {
        let environment = GitEnvironment.make(from: ["HOME": "/Users/x", "GIT_DIR": "/evil", "GIT_WORK_TREE": "/evil", "SECRET": "x"])
        XCTAssertEqual(environment["HOME"], "/Users/x")
        XCTAssertNil(environment["GIT_DIR"])
        XCTAssertNil(environment["GIT_WORK_TREE"])
        XCTAssertNil(environment["SECRET"])
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
    }
}
