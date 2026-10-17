import XCTest
@testable import WCleanerCore

final class DisposablePathsTests: XCTestCase {
    func testNormalizesExactRelativePaths() {
        XCTAssertEqual(DisposablePaths.normalize("node_modules"), "node_modules")
        XCTAssertEqual(DisposablePaths.normalize("  ./build/ "), "build")
        XCTAssertEqual(DisposablePaths.normalize("/.code-review-graph/"), ".code-review-graph")
        XCTAssertEqual(DisposablePaths.normalize("app/dist"), "app/dist")
        XCTAssertEqual(DisposablePaths.normalize(".gitignore"), ".gitignore")
    }

    func testRejectsAnythingThatIsNotAnExactSafePath() {
        for input in ["", "   ", "/", ".", "..", "../x", "a/../b", "a//b", "a/./b", "*.log", "build?", "[ab]", "a\\b",
                      ".git", "sub/.git", ".GIT/x", "a\nb", "a\u{0}b"] {
            XCTAssertNil(DisposablePaths.normalize(input), "\(input.debugDescription) must be rejected")
        }
    }

    func testNormalizedListDropsInvalidAndDuplicateEntries() {
        XCTAssertEqual(DisposablePaths.normalizedList(["build/", "./build", "..", "node_modules"]), ["build", "node_modules"])
    }

    func testCoversThePathAndEverythingInsideIt() {
        let disposable = ["build", ".code-review-graph"]
        XCTAssertTrue(DisposablePaths.covers(disposable, "build/"))
        XCTAssertTrue(DisposablePaths.covers(disposable, "build"))
        XCTAssertTrue(DisposablePaths.covers(disposable, "build/out/a.o"))
        XCTAssertTrue(DisposablePaths.covers(disposable, ".code-review-graph/"))

        XCTAssertFalse(DisposablePaths.covers(disposable, "build.log"))
        XCTAssertFalse(DisposablePaths.covers(disposable, "buildx/"))
        XCTAssertFalse(DisposablePaths.covers(disposable, "app/build/"))
        XCTAssertFalse(DisposablePaths.covers(disposable, ".env"))
        XCTAssertFalse(DisposablePaths.covers(disposable, "/"))
        XCTAssertFalse(DisposablePaths.covers([], "build/"))
    }

    func testRepositoriesSavedBeforeTheListExistDecodeWithAnEmptyList() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","displayName":"repo","path":"/r","commonDirectory":"/r/.git",
         "isBare":false,"addedAt":0}
        """
        let repository = try JSONDecoder().decode(RegisteredRepository.self, from: Data(json.utf8))
        XCTAssertEqual(repository.disposableIgnoredPaths, [])
        XCTAssertNil(repository.pullRequestRemote)
    }

    func testStoredListIsNormalizedAndInvalidEntriesAreDropped() throws {
        var repository = RegisteredRepository(displayName: "repo", path: "/r", commonDirectory: "/r/.git")
        repository.disposableIgnoredPaths = ["build", "../outside", ".git", "node_modules/"]
        let decoded = try JSONDecoder().decode(RegisteredRepository.self, from: JSONEncoder().encode(repository))
        XCTAssertEqual(decoded.disposableIgnoredPaths, ["build", "node_modules"])
    }
}
