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

    private func evidence(_ number: Int, _ state: PullRequestState) -> PullRequestEvidence {
        PullRequestEvidence(
            number: number, title: "PR \(number)", url: "https://github.com/o/r/pull/\(number)", state: state,
            mergedAt: state == .merged ? Date() : nil, headSHA: head, headRef: "x", headRepositoryID: 1,
            headRepositoryFullName: "o/r", baseRepositoryID: 1, baseRef: "main",
            accountID: AccountID(host: "github.com", userID: 1), fetchedAt: Date(), headRepositoryVerified: true
        )
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

    private func builder(_ snapshot: MonitorSnapshot, settings: AppSettings = AppSettings(), target: (any StatusMenuTarget)? = nil) -> StatusMenuBuilder {
        StatusMenuBuilder(
            snapshot: snapshot,
            settings: settings,
            accounts: [],
            gitAvailable: true,
            gitDescription: "Git 2.39",
            now: Date(),
            target: target
        )
    }

    private func build(_ snapshot: MonitorSnapshot, settings: AppSettings = AppSettings()) -> NSMenu {
        let menu = NSMenu()
        builder(snapshot, settings: settings).populate(menu)
        return menu
    }

    func testCheckNowButtonInTheCardChecksWithoutClosingTheMenu() throws {
        let target = TargetSpy()
        let menu = NSMenu()
        let card = builder(snapshot(), target: target).populate(menu)
        XCTAssertTrue(card.checkButton.isEnabled)
        card.checkButton.performClick(nil)
        XCTAssertEqual(target.checks, 1)

        var scanning = snapshot()
        scanning.isScanning = true
        card.apply(MenuSummary(snapshot: scanning, settings: AppSettings(), now: Date()))
        XCTAssertFalse(card.checkButton.isEnabled, "No second check while one is running")
    }

    func testOpenMenuRowsAreReplacedInPlace() throws {
        let menu = NSMenu()
        let card = builder(snapshot()).populate(menu)
        let footerCount = menu.items.count - menu.indexOfItem(withTag: StatusMenuBuilder.footerTag)

        var updated = snapshot()
        updated.repositories[0].worktrees.removeLast()
        updated.lastScanError = "GitHub rate limit reached"
        XCTAssertTrue(builder(updated).replaceBody(in: menu))

        XCTAssertTrue(menu.items.first?.view === card, "The card stays; only the rows change")
        let rows = menu.items.filter { $0.indentationLevel == 1 && $0.submenu != nil }
        XCTAssertEqual(rows.map { $0.title.components(separatedBy: "\t").first }, ["safe"])
        XCTAssertTrue(menu.items[1].title.contains("rate limit"))
        XCTAssertEqual(menu.items.count - menu.indexOfItem(withTag: StatusMenuBuilder.footerTag), footerCount)
        XCTAssertFalse(builder(updated).replaceBody(in: NSMenu()), "A menu without the markers is left alone")
    }

    /// Offered only when every ignored file that keeps the worktree is listed, so the user approves exact paths.
    func testAllowDeletingIgnoredFilesIsOfferedOnlyForAFullList() throws {
        func submenuTitles(_ reasons: [EligibilityReason]) -> [String] {
            var snapshot = snapshot()
            snapshot.repositories[0].worktrees[2].decision = decision(.blocked, reasons)
            let row = build(snapshot).items.first { $0.title.hasPrefix("dirty") }
            return row?.submenu?.items.map(\.title) ?? []
        }
        let action = "Allow Deleting These Ignored Files…"
        XCTAssertTrue(submenuTitles([.ignoredFiles(2, paths: ["build/", ".code-review-graph/"])]).contains(action))
        XCTAssertFalse(submenuTitles([.ignoredFiles(3, paths: ["build/"])]).contains(action), "Some paths were not listed")
        XCTAssertFalse(submenuTitles([.ignoredFiles(3)]).contains(action))
        XCTAssertFalse(submenuTitles([.untrackedFiles(1)]).contains(action))
    }

    /// Offered for a kept worktree only when nothing local would be lost (the pull request is the only reason).
    func testRemoveAnywayIsOfferedOnlyWhenEveryLocalCheckPassed() throws {
        func submenuTitles(_ decision: CleanupDecision, primary: Bool = false) -> [String] {
            var snapshot = snapshot()
            snapshot.repositories[0].worktrees[2].decision = decision
            snapshot.repositories[0].worktrees[2].isPrimary = primary
            let row = build(snapshot).items.first { $0.title.hasPrefix("dirty") }
            return row?.submenu?.items.map(\.title) ?? []
        }
        let action = "Remove Worktree Anyway…"
        let openPR = CleanupDecision(verdict: .blocked, reasons: [.pullRequestOpen(48)], evidence: nil, automaticCleanupAllowed: false, localBlockingReasons: [])
        XCTAssertTrue(submenuTitles(openPR).contains(action))
        XCTAssertFalse(submenuTitles(openPR).contains("Remove Worktree Now…"))
        XCTAssertFalse(submenuTitles(openPR, primary: true).contains(action))

        let dirty = CleanupDecision(verdict: .blocked, reasons: [.unstagedChanges(7)], evidence: nil, automaticCleanupAllowed: false, localBlockingReasons: [.unstagedChanges(7)])
        XCTAssertFalse(submenuTitles(dirty).contains(action))
        XCTAssertFalse(submenuTitles(decision(.blocked, [.noPullRequest])).contains(action), "Unknown local state is never offered")

        let safe = CleanupDecision(verdict: .eligible, reasons: [], evidence: nil, automaticCleanupAllowed: false, localBlockingReasons: [])
        XCTAssertFalse(submenuTitles(safe).contains(action), "A merged, safe worktree uses the normal removal")
    }

    /// Offered when uncommitted changes are the only local reason, never next to another local problem.
    func testSaveChangesAndRemoveIsOfferedOnlyForStashableChanges() throws {
        func submenuTitles(_ local: [EligibilityReason]?, primary: Bool = false) -> [String] {
            var snapshot = snapshot()
            snapshot.repositories[0].worktrees[2].decision = CleanupDecision(
                verdict: .blocked, reasons: (local ?? []) + [.needsAccount], evidence: nil, automaticCleanupAllowed: false, localBlockingReasons: local
            )
            snapshot.repositories[0].worktrees[2].isPrimary = primary
            let row = build(snapshot).items.first { $0.title.hasPrefix("dirty") }
            return row?.submenu?.items.map(\.title) ?? []
        }
        let action = "Save Changes and Remove Worktree…"
        XCTAssertTrue(submenuTitles([.unstagedChanges(7)]).contains(action))
        XCTAssertTrue(submenuTitles([.stagedChanges(1), .untrackedFiles(2)]).contains(action))
        XCTAssertFalse(submenuTitles([.unstagedChanges(7)], primary: true).contains(action))
        XCTAssertFalse(submenuTitles([.unstagedChanges(1), .ignoredFiles(1)]).contains(action))
        XCTAssertFalse(submenuTitles([.unmergedChanges(1)]).contains(action))
        XCTAssertFalse(submenuTitles(nil).contains(action))
        XCTAssertFalse(submenuTitles([]).contains(action), "A clean worktree gets Remove Worktree Anyway instead")
        XCTAssertTrue(submenuTitles([]).contains("Remove Worktree Anyway…"))
    }

    func testCircleStatusIconsUseAWhiteGlyphOnAColouredCircle() throws {
        let image = try XCTUnwrap(StatusMenuBuilder.coloredSymbol("lock.circle.fill", color: .systemGray, description: "Kept"))
        let side = 64
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var white = 0, colored = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                if color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95 { white += 1 } else { colored += 1 }
            }
        }
        XCTAssertGreaterThan(white, 150, "The lock glyph is drawn in white")
        XCTAssertGreaterThan(colored, white, "on an opaque grey circle")
    }

    func testStandardActionsArePresentWithKeyEquivalents() throws {
        let menu = build(snapshot())
        XCTAssertNil(menu.items.first { $0.title == "Check Now" }, "Check Now is a button in the card so the menu stays open")
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
        XCTAssertEqual(worktreeItems.map { $0.title.components(separatedBy: "\t").first }, ["safe", "dirty"])
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

    func testMenuStartsWithTheSummaryCard() throws {
        let menu = build(snapshot())
        let card = try XCTUnwrap(menu.items.first?.view as? MenuSummaryView)
        XCTAssertEqual(card.summary.safe, 1)
        XCTAssertEqual(card.summary.kept, 1)
        XCTAssertEqual(card.summary.overview, "2 worktrees · ≥ 2 MB (1 not measured)", "Unmeasured sizes are never shown as zero")
        XCTAssertEqual(card.summary.freeable, "2 MB freeable")
        XCTAssertGreaterThan(card.frame.height, 40)
        XCTAssertTrue(card.isAccessibilityElement())
        XCTAssertTrue(card.accessibilityLabel()?.contains("1 safe") ?? false)
    }

    func testWorktreeRowsShowColouredStatusAndPullRequest() throws {
        let menu = build(snapshot())
        let rows = menu.items.filter { $0.indentationLevel == 1 && $0.submenu != nil }
        let image = try XCTUnwrap(rows[0].image)
        XCTAssertFalse(image.isTemplate, "Status symbols keep their colour")
        XCTAssertEqual(image.accessibilityDescription, "Safe to remove")
        XCTAssertEqual(rows[0].title, "safe\tNo PR\t2 MB")
        XCTAssertEqual(rows[1].title, "dirty\tPR unavailable\tSize unavailable")
    }

    func testPullRequestLabelsAndColours() {
        let merged = evidence(12, .merged)
        XCTAssertEqual(StatusMenuBuilder.compactPullRequest(.matched(merged)), "#12 Merged")
        XCTAssertEqual(StatusMenuBuilder.compactPullRequest(.headMismatch(merged, localHead: head)), "#12 other HEAD")
        XCTAssertEqual(StatusMenuBuilder.compactPullRequest(.ambiguous([1, 2])), "2 possible PRs")
        XCTAssertEqual(StatusMenuBuilder.compactPullRequest(nil), "Not checked")
        XCTAssertEqual(StatusMenuBuilder.pullRequestColor(.matched(merged)), .systemPurple)
        XCTAssertEqual(StatusMenuBuilder.pullRequestColor(.matched(evidence(3, .open))), .systemGreen)
        XCTAssertEqual(StatusMenuBuilder.pullRequestColor(.matched(evidence(4, .closedUnmerged))), .systemRed)
        XCTAssertEqual(StatusMenuBuilder.pullRequestColor(.unavailable("x")), .systemOrange)
        XCTAssertEqual(StatusMenuBuilder.truncateMiddle("claudeworkspace_transaction_side_effects", 24), "claudeworks…side_effects")
    }

    func testSummaryCountsAndAutomaticCleanupState() {
        var settings = AppSettings()
        var summary = MenuSummary(snapshot: snapshot(), settings: settings, now: Date())
        XCTAssertEqual(summary.automatic, "Auto cleanup off")
        XCTAssertEqual(summary.automaticTone, .neutral)
        XCTAssertEqual([summary.safe, summary.waiting, summary.review, summary.kept], [1, 0, 0, 1])
        XCTAssertEqual(summary.freeableFraction, 1, accuracy: 0.0001, "Only measured sizes count toward the bar")
        XCTAssertTrue(summary.status.hasPrefix("Checked"))

        settings.cleanupConsentAt = Date()
        settings.autoCleanupEnabled = true
        settings.autoCleanupPaused = true
        summary = MenuSummary(snapshot: snapshot(), settings: settings, now: Date())
        XCTAssertEqual(summary.automatic, "Auto cleanup paused")
        XCTAssertEqual(summary.automaticTone, .caution)

        var scanning = snapshot()
        scanning.isScanning = true
        XCTAssertEqual(MenuSummary(snapshot: scanning, settings: settings, now: Date()).status, "Checking…")
        let empty = MenuSummary(snapshot: MonitorSnapshot(), settings: settings, now: Date())
        XCTAssertEqual(empty.overview, "No repositories yet")
        XCTAssertEqual(empty.freeable, "Nothing to free")
        XCTAssertEqual(empty.freeableFraction, 0)
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

@MainActor
private final class TargetSpy: NSObject, StatusMenuTarget {
    var checks = 0
    func checkNow(_ sender: Any?) { checks += 1 }
    func openSettings(_ sender: Any?) {}
    func openHistory(_ sender: Any?) {}
    func togglePause(_ sender: Any?) {}
    func addRepository(_ sender: Any?) {}
    func revealPath(_ sender: NSMenuItem) {}
    func copyPath(_ sender: NSMenuItem) {}
    func openURL(_ sender: NSMenuItem) {}
    func reviewWorktree(_ sender: NSMenuItem) {}
    func removeWorktree(_ sender: NSMenuItem) {}
    func allowDisposableIgnoredFiles(_ sender: NSMenuItem) {}
    func removeWorktreeWithoutMergedPullRequest(_ sender: NSMenuItem) {}
    func stashChangesAndRemoveWorktree(_ sender: NSMenuItem) {}
    func openRepositorySettings(_ sender: Any?) {}
    func quit(_ sender: Any?) {}
}
