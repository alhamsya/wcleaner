import XCTest
@testable import WCleanerCore

final class WorktreePorcelainParserTests: XCTestCase {
    private let sha = "43683ef15bec5e7cbe594744b911ec0d40afa752"
    private let sha2 = "1111111111111111111111111111111111111111"

    private func porcelain(_ records: [[String]], trailing: Bool = true) -> Data {
        var data = Data()
        for (index, record) in records.enumerated() {
            for attribute in record {
                data.append(contentsOf: Array(attribute.utf8))
                data.append(0)
            }
            if trailing || index < records.count - 1 {
                data.append(0)
            }
        }
        return data
    }

    func testParsesPrimaryAndLinkedWorktrees() throws {
        let data = porcelain([
            ["worktree /Users/me/repo", "HEAD \(sha)", "branch refs/heads/main"],
            ["worktree /Users/me/wt one", "HEAD \(sha2)", "branch refs/heads/feat/x"],
        ])
        let records = try WorktreePorcelainParser.parse(data)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/Users/me/repo")
        XCTAssertEqual(records[0].branchName, "main")
        XCTAssertEqual(records[1].path, "/Users/me/wt one")
        XCTAssertEqual(records[1].head, sha2)
        XCTAssertEqual(records[1].branchName, "feat/x")
        XCTAssertFalse(records[1].isLocked)
    }

    func testPathsWithNewlinesTabsAndUnicode() throws {
        let weird = "/tmp/wt\nwith newline\tand tab — ünïcødé 🚀"
        let data = porcelain([
            ["worktree /repo", "HEAD \(sha)", "branch refs/heads/main"],
            ["worktree \(weird)", "HEAD \(sha)", "branch refs/heads/x"],
        ])
        let records = try WorktreePorcelainParser.parse(data)
        XCTAssertEqual(records[1].path, weird)
    }

    func testLockedPrunableDetachedAndBare() throws {
        let data = porcelain([
            ["worktree /repo.git", "bare"],
            ["worktree /wt/locked", "HEAD \(sha)", "detached", "locked multi\nline reason"],
            ["worktree /wt/plain-lock", "HEAD \(sha)", "branch refs/heads/a", "locked"],
            ["worktree /wt/gone", "HEAD \(sha)", "branch refs/heads/b", "prunable gitdir file points to non-existent location"],
        ])
        let records = try WorktreePorcelainParser.parse(data)
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records[0].isBare)
        XCTAssertNil(records[0].head)
        XCTAssertTrue(records[1].isDetached)
        XCTAssertTrue(records[1].isLocked)
        XCTAssertEqual(records[1].lockReason, "multi\nline reason")
        XCTAssertNil(records[1].branchName)
        XCTAssertTrue(records[2].isLocked)
        XCTAssertNil(records[2].lockReason)
        XCTAssertTrue(records[3].isPrunable)
        XCTAssertEqual(records[3].prunableReason, "gitdir file points to non-existent location")
    }

    func testMissingTrailingSeparatorStillParsesLastRecord() throws {
        let data = porcelain([
            ["worktree /repo", "HEAD \(sha)", "branch refs/heads/main"],
            ["worktree /wt", "HEAD \(sha)", "branch refs/heads/x"],
        ], trailing: false)
        XCTAssertEqual(try WorktreePorcelainParser.parse(data).count, 2)
    }

    func testUnknownAttributesAreRecorded() throws {
        let data = porcelain([["worktree /wt", "HEAD \(sha)", "branch refs/heads/x", "future-flag value"]])
        let records = try WorktreePorcelainParser.parse(data)
        XCTAssertEqual(records[0].unknownAttributes, ["future-flag"])
    }

    func testRejectsRelativePathsAndBadHeads() {
        XCTAssertThrowsError(try WorktreePorcelainParser.parse(porcelain([["worktree relative/path"]])))
        XCTAssertThrowsError(try WorktreePorcelainParser.parse(porcelain([["worktree /wt", "HEAD nothex"]])))
        XCTAssertThrowsError(try WorktreePorcelainParser.parse(porcelain([["HEAD \(sha)"]])))
    }

    func testRejectsInvalidUTF8() {
        var data = Data("worktree /wt/".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(0)
        data.append(0)
        XCTAssertThrowsError(try WorktreePorcelainParser.parse(data))
    }

    func testEmptyOutput() throws {
        XCTAssertEqual(try WorktreePorcelainParser.parse(Data()), [])
    }
}
