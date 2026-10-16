import AppKit
import UserNotifications
import WCleanerCore

/// Local notifications only; nothing is sent anywhere. Text names a repository and worktree folder,
/// never tokens, account IDs or file contents. Respects the macOS permission and the app setting.
@MainActor
final class NotificationService {
    /// Refusals are reported once per worktree per app session, so a recurring problem does not nag.
    private var reportedRefusals: Set<String> = []

    func authorization() async -> NotificationAuthorization {
        switch await Self.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    /// Shows the macOS permission prompt if it was never shown. Returns the resulting state.
    func requestAuthorization() async -> NotificationAuthorization {
        _ = await Self.requestSystemAuthorization()
        return await authorization()
    }

    /// Reads only the (Sendable) status, off the main actor.
    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func openSystemSettings() {
        let identifier = AppEnvironment.bundleIdentifier
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    func sendTest() async -> NotificationAuthorization {
        var state = await authorization()
        if state == .notDetermined {
            state = await requestAuthorization()
        }
        guard state == .authorized else { return state }
        await post(id: "test-\(UUID().uuidString)", title: "WCleaner notifications are on", body: "You will be told when a worktree is removed or needs your attention.")
        return state
    }

    func handle(_ event: MonitorEvent, enabled: Bool) async {
        guard enabled, await authorization() == .authorized else { return }
        switch event {
        case .cleanupCompleted(let outcome):
            let entry = outcome.entry
            let name = (entry.worktreePath as NSString).lastPathComponent
            switch outcome {
            case .removed:
                // Manual removals are confirmed in the app itself.
                guard entry.mode == .automatic else { return }
                var body = "\(name) in \(entry.repositoryName)"
                if let number = entry.pullRequestNumber { body += " (pull request #\(number) merged)" }
                body += " was removed."
                if let bytes = entry.estimatedSizeBytes { body += " About \(ByteFormatter.string(bytes)) freed (estimate)." }
                await post(id: "removed-\(entry.id)", title: "Worktree removed", body: body)
            case .refused(_, let reasons):
                guard entry.mode == .automatic, reportedRefusals.insert(entry.worktreePath).inserted else { return }
                await post(id: "refused-\(entry.id)", title: "Cleanup skipped for \(name)", body: reasons.first?.message ?? "A safety check did not pass.")
            case .failed:
                guard entry.mode == .automatic, reportedRefusals.insert(entry.worktreePath).inserted else { return }
                await post(id: "failed-\(entry.id)", title: "Git did not remove \(name)", body: "Nothing was forced. See WCleaner › History for details.")
            }
        case .reviewRequired(let repositoryName, let worktreePath, let pullRequest):
            let name = (worktreePath as NSString).lastPathComponent
            await post(
                id: "review-\(worktreePath)",
                title: "Review needed in \(repositoryName)",
                body: "\(name) belongs to pull request #\(pullRequest), merged before WCleaner started monitoring. Review it from the WCleaner menu."
            )
        case .accountNeedsReconnect(let login):
            await post(id: "reconnect-\(login)", title: "Reconnect @\(login)", body: "GitHub no longer accepts this account's sign-in. Reconnect it in WCleaner Settings › Accounts.")
        }
    }

    private func post(id: String, title: String, body: String) async {
        await Self.deliver(id: id, title: title, body: body)
    }

    // The notification center is used only from these nonisolated helpers, so no
    // non-Sendable UserNotifications object crosses the main actor.
    nonisolated private static func requestSystemAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    nonisolated private static func deliver(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
