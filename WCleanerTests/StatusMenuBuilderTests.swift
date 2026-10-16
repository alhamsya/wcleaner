import AppKit
import XCTest
import WCleanerCore
@testable import WCleaner

@MainActor
final class StatusMenuBuilderTests: XCTestCase {
    private let head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func decision(_ verdict: CleanupDecision.Verdict, _ reasons: [EligibilityReason] = []) -> CleanupDecision {
        CleanupDecision(verdict: verdict, reasons: reasons, evidence: nil, automaticCleanupAllowed: false)
    }

    private func snapshot() -> MonitorSnapshot {
        let repository = RegisteredRepository(displayName: "repo", path: "/tmp/repo", commonDirectory: "/tmp/repo/.git")
        let primary = WorktreeSnapshot(
            repositoryID: repository.id,
            record: WorktreeRecord(path: "/tmp/repo", head: head, branchRef: "refs/heads/main"),
            isPrimary: true,
            pullRequest: nil,
            decision: decision(.blocked, [.primaryWorktree]),
            diskUsage: .unknown,
            inspection: nil
        )
        let safe = WorktreeSnapshot(
            repositoryID: repository.id,
            record: WorktreeRecord(path: "/tmp/wt/safe", head: head, branchRef: "refs/heads/safe"),
            isPrimary: false,
            pullRequest: .notFound,
            decision: decision(.eligible),
            diskUsage: .measured(bytes: 2_000_000, measuredAt: Date(), partial: false),
            inspection: nil
        )
        let dirty = WorktreeSnapshot(
            repositoryID: repository.id,
            record: WorktreeRecord(path: "/tmp/wt/dirty", head: head, branchRef: "refs/heads/dirty"),
            isPrimary: false,
            pullRequest: .unavailable("HTTP 500"),
            decision: decision(.blocked, [.ignoredFiles(3)]),
            diskUsage: .failed("permission denied"),
            inspection: nil
        )
        return MonitorSnapshot(
            repositories: [RepositorySnapshot(repository: repository, accountResolution: .needsAccount, worktrees: [primary, safe, dirty])],
            lastScanCompletedAt: Date()
        )
    }

    private func build(_ snapshot: MonitorSnapshot, settings: AppSettings = AppSettings()) -> NSMenu {
        let menu = NSMenu()
        StatusMenuBuilder(
            snapshot: snapshot,
            settings: settings,
            accounts: [],
            gitAvailable: true,
            gitDescription: "Git 2.39",
            now: Date(),
            target: nil
        ).populate(menu)
        return menu
    }

    func testStandardActionsArePresentWithKeyEquivalents() throws {
        let menu = build(snapshot())
        let check = try XCTUnwrap(menu.items.first { $0.title == "Check Now" })
        XCTAssertEqual(check.keyEquivalent, "r")
        XCTAssertEqual(menu.items.first { $0.title == "Settings…" }?.keyEquivalent, ",")
        XCTAssertEqual(menu.items.first { $0.title == "Quit WCleaner" }?.keyEquivalent, "q")
        XCTAssertNotNil(menu.items.first { $0.title == "View History…" })
        XCTAssertNil(menu.items.first { $0.title.contains("Pause") }, "Pause is only offered while automatic cleanup is on")
    }

    func testPauseIsOfferedWhenAutomaticCleanupIsOn() {
        var settings = AppSettings()
        settings.cleanupConsentAt = Date()
        settings.autoCleanupEnabled = true
        XCTAssertNotNil(build(snapshot(), settings: settings).items.first { $0.title == "Pause Automatic Cleanup" })
        settings.autoCleanupPaused = true
        XCTAssertNotNil(build(snapshot(), settings: settings).items.first { $0.title == "Resume Automatic Cleanup" })
    }

    func testListsOnlyLinkedWorktreesWithDetailSubmenus() throws {
        let menu = build(snapshot())
        let worktreeItems = menu.items.filter { $0.indentationLevel == 1 && $0.submenu != nil }
        XCTAssertEqual(worktreeItems.map { $0.title.components(separatedBy: "  ").first }, ["safe", "dirty"])
        XCTAssertTrue(worktreeItems[0].title.contains("2 MB"))
        XCTAssertTrue(worktreeItems[1].title.contains("Size unavailable"))

        let safeMenu = try XCTUnwrap(worktreeItems[0].submenu)
        XCTAssertTrue(safeMenu.items.contains { $0.title == "Remove Worktree Now…" })
        XCTAssertTrue(safeMenu.items.contains { $0.title.hasPrefix("HEAD: aaaaaaa") })

        let dirtyMenu = try XCTUnwrap(worktreeItems[1].submenu)
        XCTAssertFalse(dirtyMenu.items.contains { $0.title == "Remove Worktree Now…" }, "Blocked worktrees must not offer removal")
        XCTAssertTrue(dirtyMenu.items.contains { $0.title.contains("ignored file") })
        XCTAssertTrue(dirtyMenu.items.contains { $0.title == "Size: Size unavailable" }, "Failed sizes must not show as 0 B")
    }

    func testEmptyStateOffersAddRepository() {
        let menu = build(MonitorSnapshot())
        XCTAssertNotNil(menu.items.first { $0.title == "No repositories yet" })
        XCTAssertNotNil(menu.items.first { $0.title == "Add Repository…" })
    }

    func testUnknownSizesAreNeverZero() {
        XCTAssertEqual(DiskUsageValue.unknown.displayString, "Size unknown")
        XCTAssertEqual(DiskUsageValue.failed("x").displayString, "Size unavailable")
        var total = DiskUsageTotal()
        total.add(.unknown)
        XCTAssertEqual(total.displayString, "Unknown")
        total.add(.measured(bytes: 1_000_000, measuredAt: Date(), partial: false))
        XCTAssertTrue(total.displayString.hasPrefix("≥ "))
    }
}
