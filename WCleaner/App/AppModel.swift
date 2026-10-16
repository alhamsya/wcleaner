import AppKit
import WCleanerCore

/// Launch at Login state as reported by `SMAppService`, never assumed.
enum LaunchAtLoginStatus: Equatable {
    case enabled
    case requiresApproval
    case disabled
    case unavailable(String)

    var title: String {
        switch self {
        case .enabled: "On"
        case .requiresApproval: "Waiting for approval in System Settings › General › Login Items"
        case .disabled: "Off"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }
}

enum NotificationAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case unknown

    var title: String {
        switch self {
        case .notDetermined: "Not requested yet"
        case .authorized: "Allowed by macOS"
        case .denied: "Not allowed — enable WCleaner in System Settings › Notifications"
        case .unknown: "Unknown"
        }
    }
}

/// Configuration and state of the optional third-party Mole CLI.
enum MoleStatus: Equatable {
    case unknown
    case notInstalled
    case installed(path: String, version: String?)
}

/// What the UI needs to act on. Implemented by `AppCoordinator`.
@MainActor
protocol AppActions: AnyObject {
    func checkNow()
    func openSettings(_ tab: SettingsTab?)
    func setAutomaticCleanupPaused(_ paused: Bool)
    func quit()

    func addRepository()
    func removeRepository(_ id: UUID)
    func assignAccount(_ account: AccountID, to repository: UUID)
    func setPullRequestRemote(_ remote: String?, for repository: UUID)
    func refreshDiskUsage()

    func addAccount()
    func reconnectAccount(_ id: AccountID)
    func disconnectAccount(_ id: AccountID)

    func requestCleanupConsent(enableAutomaticCleanup: Bool)
    func revokeCleanupConsent()
    func reviewWorktree(_ worktree: WorktreeSnapshot)
    func removeWorktreeManually(_ worktree: WorktreeSnapshot)

    func setLaunchAtLogin(_ enabled: Bool)
    func openLoginItemsSettings()
    func setNotificationsEnabled(_ enabled: Bool)
    func openNotificationSettings()
    func sendTestNotification()

    func clearHistory()
    func revealDataFolder()

    func refreshMoleStatus()
    func openMole()
    func previewMoleClean()
    func runMoleCleanInTerminal()

    func showUninstallInstructions()
    func showOnboarding()
}

/// Observable app state for the AppKit views. Main-actor only; no Combine or SwiftUI.
@MainActor
final class AppModel {
    enum Change: Equatable {
        case snapshot
        case settings
        case accounts
        case repositories
        case history
        case system
    }

    final class Token {
        private let cancel: () -> Void
        init(cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    let settingsStore: SettingsStore
    weak var actions: (any AppActions)?

    private(set) var snapshot: MonitorSnapshot = .empty
    private(set) var accounts: [GitHubAccount] = []
    private(set) var repositories: [RegisteredRepository] = []
    private(set) var history: [CleanupHistoryEntry] = []
    private(set) var gitDescription = "Checking for Git…"
    private(set) var gitAvailable = false
    private(set) var gitHubClientConfigured = false
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    private(set) var notificationAuthorization: NotificationAuthorization = .unknown
    private(set) var moleStatus: MoleStatus = .unknown
    private(set) var molePreviewedThisSession = false
    /// False in development builds unless explicitly enabled: every decision stays a dry run.
    private(set) var removalEnabledInBuild = false
    /// Core services are running (Git was found and local data could be opened).
    private(set) var servicesReady = false

    private var observers: [UUID: (Change) -> Void] = [:]

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        settingsStore.observe { [weak self] _ in
            self?.notify(.settings)
        }
    }

    var settings: AppSettings { settingsStore.settings }

    func observe(_ handler: @escaping (Change) -> Void) -> Token {
        let id = UUID()
        observers[id] = handler
        return Token { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.observers[id] = nil }
            } else {
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    func account(_ id: AccountID) -> GitHubAccount? {
        accounts.first { $0.id == id }
    }

    func repositorySnapshot(_ id: UUID) -> RepositorySnapshot? {
        snapshot.repositories.first { $0.id == id }
    }

    // MARK: Updates (called by the coordinator)

    func update(snapshot: MonitorSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        notify(.snapshot)
    }

    func update(accounts: [GitHubAccount]) {
        guard accounts != self.accounts else { return }
        self.accounts = accounts
        notify(.accounts)
    }

    func update(repositories: [RegisteredRepository]) {
        guard repositories != self.repositories else { return }
        self.repositories = repositories
        notify(.repositories)
    }

    func update(history: [CleanupHistoryEntry]) {
        guard history != self.history else { return }
        self.history = history
        notify(.history)
    }

    func update(gitDescription: String, available: Bool) {
        self.gitDescription = gitDescription
        self.gitAvailable = available
        notify(.system)
    }

    func update(gitHubClientConfigured: Bool) {
        self.gitHubClientConfigured = gitHubClientConfigured
        notify(.system)
    }

    func update(launchAtLoginStatus: LaunchAtLoginStatus) {
        guard launchAtLoginStatus != self.launchAtLoginStatus else { return }
        self.launchAtLoginStatus = launchAtLoginStatus
        notify(.system)
    }

    func update(notificationAuthorization: NotificationAuthorization) {
        guard notificationAuthorization != self.notificationAuthorization else { return }
        self.notificationAuthorization = notificationAuthorization
        notify(.system)
    }

    func update(moleStatus: MoleStatus) {
        self.moleStatus = moleStatus
        notify(.system)
    }

    func update(removalEnabledInBuild: Bool, servicesReady: Bool) {
        self.removalEnabledInBuild = removalEnabledInBuild
        self.servicesReady = servicesReady
        notify(.system)
    }

    func markMolePreviewed() {
        molePreviewedThisSession = true
        notify(.system)
    }

    private func notify(_ change: Change) {
        for observer in observers.values {
            observer(change)
        }
    }
}
