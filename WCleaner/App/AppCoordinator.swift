import AppKit
import WCleanerCore

/// Owns the app's services and UI controllers and implements every user action.
@MainActor
final class AppCoordinator: AppActions {
    /// Core services, created once Git has been found and the data folder is usable.
    struct Services {
        let data: AppDataDirectory
        let git: GitClient
        let api: GitHubAPIClient
        let auth: GitHubAuthService
        let accounts: GitHubAccountStore
        let mappings: RepositoryAccountMappingStore
        let resolver: RepositoryAccountResolver
        let registry: RepositoryRegistry
        let history: CleanupHistoryStore
        let engine: MonitorEngine
        let scheduler: PollingScheduler
    }

    let settingsStore: SettingsStore
    let model: AppModel
    private let configuration: GitHubConfiguration
    private let deletionPolicy: DeletionPolicy
    private let notifications = NotificationService()
    private var services: Services?
    private var lastSettings: AppSettings

    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var deviceFlowController: DeviceFlowWindowController?
    private var signInTask: Task<Void, Never>?
    private var settingsObservation: UUID?
    private var workspaceObservers: [any NSObjectProtocol] = []

    private var mole: MoleInstallation?
    private var moleGate = MoleCleanGate()

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.model = AppModel(settingsStore: settingsStore)
        self.lastSettings = settingsStore.settings
        self.configuration = Self.makeConfiguration()
        self.deletionPolicy = Self.makeDeletionPolicy()
        model.actions = self
    }

    static func makeConfiguration(bundle: Bundle = .main) -> GitHubConfiguration {
        let clientID = bundle.object(forInfoDictionaryKey: "WCGitHubClientID") as? String
        return GitHubConfiguration(clientID: clientID, userAgent: "WCleaner/\(AppEnvironment.appVersion)")
    }

    /// Development builds never remove anything unless WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1 is set explicitly.
    static func makeDeletionPolicy(environment: [String: String] = ProcessInfo.processInfo.environment) -> DeletionPolicy {
        if AppEnvironment.isDebugBuild {
            return DeletionPolicy(allowsRealRemoval: environment["WCLEANER_ALLOW_REMOVAL_IN_DEBUG"] == "1")
        }
        return DeletionPolicy(allowsRealRemoval: true)
    }

    // MARK: Lifecycle

    func start() {
        startInterface()
        startBackgroundServices()
        if !settingsStore.settings.onboardingCompleted {
            showOnboarding()
        }
    }

    /// Menu bar item, main menu, appearance and settings observation. Touches no repositories or data files.
    func startInterface() {
        MainMenu.install()
        AppearanceController.apply(settingsStore.settings.appearance)
        settingsObservation = settingsStore.observe { [weak self] settings in
            self?.settingsDidChange(settings)
        }
        statusItemController = StatusItemController(model: model)
        model.update(gitHubClientConfigured: configuration.isConfigured)
        model.update(removalEnabledInBuild: deletionPolicy.allowsRealRemoval, servicesReady: false)
        model.update(launchAtLoginStatus: LaunchAtLoginService.status)
    }

    /// Git, the data folder, GitHub, the scheduler and the monitor. Never started inside a test host, so tests
    /// can't read or scan the user's real repositories or WCleaner data.
    private func startBackgroundServices() {
        guard !AppEnvironment.isRunningUnitTests else { return }
        Task {
            await refreshNotificationAuthorization()
            await setUpServices()
            await refreshMoleStatusNow()
        }
    }

    func stop() {
        onboardingController?.dismissWithoutRecording()
        onboardingController = nil
        signInTask?.cancel()
        if let settingsObservation {
            settingsStore.removeObserver(settingsObservation)
            self.settingsObservation = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let scheduler = services?.scheduler {
            Task { await scheduler.stop() }
        }
        statusItemController?.invalidate()
        statusItemController = nil
    }

    private func setUpServices() async {
        let located: (client: GitClient, version: GitVersion)
        do {
            located = try await GitClient.locate()
        } catch {
            model.update(
                gitDescription: "Git \(GitClient.minimumVersion) or later was not found (\(error.userMessage)). "
                    + "Install the Xcode Command Line Tools with “xcode-select --install” or Git from Homebrew, then relaunch WCleaner.",
                available: false
            )
            return
        }
        let git = located.client
        model.update(gitDescription: "Using Git \(located.version) at \(git.executableURL.path).", available: true)

        let data = AppDataDirectory.standard()
        do {
            try data.ensureExists()
        } catch {
            Dialogs.showError("WCleaner Can't Store Its Settings", "The folder \(data.url.path) could not be created: \(error.userMessage)")
            return
        }

        let transport = URLSessionTransport()
        let api = GitHubAPIClient(transport: transport, configuration: configuration)
        let accounts = GitHubAccountStore(store: JSONFileStore(directory: data, fileName: "accounts.json"))
        let auth = GitHubAuthService(
            configuration: configuration,
            deviceFlow: GitHubDeviceFlow(transport: transport, configuration: configuration),
            api: api,
            accounts: accounts,
            credentials: KeychainCredentialStore(serviceBase: AppEnvironment.bundleIdentifier + ".github"),
            gitHubCLI: GitHubCLI(host: configuration.host)
        )
        let mappings = RepositoryAccountMappingStore(store: JSONFileStore(directory: data, fileName: "account-mappings.json"))
        let resolver = RepositoryAccountResolver(configuration: configuration, api: api, tokens: auth, accounts: accounts, mappings: mappings)
        let matcher = PullRequestMatcher(api: api, tokens: auth)
        let registry = RepositoryRegistry(store: JSONFileStore(directory: data, fileName: "repositories.json"), git: git)
        let tracking = WorktreeTrackingStore(directory: data)
        let history = CleanupHistoryStore(directory: data)
        // The executor and the automatic batch read the settings at the moment they act, so Pause, Off
        // or withdrawn consent stop a removal that was already queued.
        let settingsStore = self.settingsStore
        let liveSettings: @Sendable () async -> AppSettings = { await MainActor.run { settingsStore.settings } }
        let executor = CleanupExecutor(
            git: git,
            evidence: LiveCleanupEvidence(git: git, resolver: resolver, matcher: matcher, accounts: accounts),
            tracking: tracking,
            history: history,
            registry: registry,
            policy: deletionPolicy,
            settings: liveSettings
        )
        let engine = MonitorEngine(
            registry: registry,
            git: git,
            resolver: resolver,
            matcher: matcher,
            api: api,
            accounts: accounts,
            tracking: tracking,
            diskUsage: DiskUsageService(),
            history: history,
            executor: executor,
            liveSettings: liveSettings
        )
        let scheduler = PollingScheduler(interval: settingsStore.settings.monitoringInterval)
        let services = Services(
            data: data, git: git, api: api, auth: auth, accounts: accounts, mappings: mappings,
            resolver: resolver, registry: registry, history: history, engine: engine, scheduler: scheduler
        )
        self.services = services

        let model = self.model
        await engine.setSnapshotObserver { snapshot in
            DispatchQueue.main.async { MainActor.assumeIsolated { model.update(snapshot: snapshot) } }
        }
        await engine.setEventObserver { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        await scheduler.setHandler { [weak self] trigger in
            let settings = await liveSettings()
            let outcome = await engine.scan(trigger: trigger, settings: settings)
            await self?.reloadAfterScan()
            return outcome
        }
        await scheduler.setNextScanObserver { date in
            Task { await engine.setNextScan(date) }
        }

        await reloadAccounts()
        await reloadRepositories()
        await reloadHistory()
        model.update(removalEnabledInBuild: deletionPolicy.allowsRealRemoval, servicesReady: true)
        observeSleepAndWake(scheduler)
        await scheduler.start()
    }

    private func observeSleepAndWake(_ scheduler: PollingScheduler) {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await scheduler.systemWillSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await scheduler.systemDidWake() }
        })
    }

    private func settingsDidChange(_ settings: AppSettings) {
        let previous = lastSettings
        lastSettings = settings
        AppearanceController.apply(settings.appearance)
        guard let services else { return }
        if previous.monitoringInterval != settings.monitoringInterval {
            Task { await services.scheduler.updateInterval(settings.monitoringInterval) }
        }
        if previous.cleanupConsentAt != settings.cleanupConsentAt
            || previous.autoCleanupEnabled != settings.autoCleanupEnabled
            || previous.autoCleanupPaused != settings.autoCleanupPaused
            || previous.cleanupDelay != settings.cleanupDelay {
            Task { await services.engine.settingsChanged(settings) }
        }
    }

    // MARK: Model refresh

    private func reloadAfterScan() async {
        await reloadAccounts()
        await reloadHistory()
    }

    private func reloadAccounts() async {
        guard let services else { return }
        model.update(accounts: await services.accounts.all())
    }

    private func reloadRepositories() async {
        guard let services else { return }
        model.update(repositories: await services.registry.all())
    }

    private func reloadHistory() async {
        guard let services else { return }
        model.update(history: await services.history.entries())
    }

    private func refreshNotificationAuthorization() async {
        model.update(notificationAuthorization: await notifications.authorization())
    }

    private func handle(_ event: MonitorEvent) {
        if case .cleanupCompleted(let outcome) = event {
            if outcome.didRemove { statusItemController?.celebrateCleanup() }
            Task { await reloadHistory() }
        }
        let enabled = settingsStore.settings.notificationsEnabled
        Task { await notifications.handle(event, enabled: enabled) }
    }

    /// Services are missing only when Git was not found or the data folder is unusable.
    private func requireServices() -> Services? {
        if let services { return services }
        Dialogs.showError("WCleaner Can't Check Repositories Yet", model.gitAvailable ? "WCleaner is still starting. Try again in a moment." : model.gitDescription)
        return nil
    }

    // MARK: AppActions — window and app

    func openSettings(_ tab: SettingsTab?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model) { [unowned self] tab in
                self.makePane(tab)
            }
        }
        model.update(launchAtLoginStatus: LaunchAtLoginService.status)
        Task { await refreshNotificationAuthorization() }
        settingsWindowController?.show(tab: tab)
    }

    func makePane(_ tab: SettingsTab) -> SettingsPaneViewController {
        switch tab {
        case .general: GeneralPaneController(model: model)
        case .accounts: AccountsPaneController(model: model)
        case .repositories: RepositoriesPaneController(model: model)
        case .autoCleanup: AutoCleanupPaneController(model: model)
        case .notifications: NotificationsPaneController(model: model)
        case .appearance: AppearancePaneController(model: model)
        case .history: HistoryPaneController(model: model)
        case .about: AboutPaneController(model: model)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func checkNow() {
        guard let services = requireServices() else { return }
        Task { await services.scheduler.checkNow() }
    }

    func setAutomaticCleanupPaused(_ paused: Bool) {
        settingsStore.update { $0.autoCleanupPaused = paused }
    }

    // MARK: Repositories

    func addRepository() {
        guard let services = requireServices() else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Repository"
        panel.message = "Choose the folder of a Git repository (or any of its worktrees). WCleaner only checks repositories you add."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)

        Task {
            var added: Set<UUID> = []
            for path in paths {
                do {
                    added.insert(try await services.registry.add(path: path).id)
                } catch {
                    Dialogs.showError("Could Not Add Repository", "\(path)\n\n\(error.userMessage)")
                }
            }
            await reloadRepositories()
            guard !added.isEmpty else { return }
            await services.engine.scan(trigger: .manual, settings: settingsStore.settings, repositoryIDs: added)
            await reloadAfterScan()
        }
    }

    func removeRepository(_ id: UUID) {
        guard let services = requireServices(), let repository = model.repositories.first(where: { $0.id == id }) else { return }
        guard Dialogs.confirmRemoveRepository(repository.displayName) else { return }
        Task {
            do {
                try await services.registry.remove(id: id)
                try await services.mappings.remove(repository: id)
            } catch {
                Dialogs.showError("Could Not Remove Repository", error.userMessage)
            }
            await services.engine.repositoryRemoved(id)
            await reloadRepositories()
        }
    }

    func assignAccount(_ account: AccountID, to repositoryID: UUID) {
        guard let services = requireServices() else { return }
        Task {
            guard let repository = await services.registry.repository(repositoryID) else { return }
            do {
                let remotes = try await services.git.remotes(repositoryPath: repository.path)
                try await services.resolver.assign(account, to: repository, remotes: remotes)
            } catch {
                Dialogs.showError("Could Not Use This Account", error.userMessage)
            }
            await services.engine.accountMappingChanged(repositoryID: repositoryID, settings: settingsStore.settings)
        }
    }

    func setPullRequestRemote(_ remote: String?, for repositoryID: UUID) {
        guard let services = requireServices() else { return }
        Task {
            do {
                try await services.registry.update(id: repositoryID) { $0.pullRequestRemote = remote }
                // A different remote can mean a different GitHub repository: verify the account again.
                try await services.mappings.remove(repository: repositoryID)
            } catch {
                Dialogs.showError("Could Not Change the Remote", error.userMessage)
            }
            await reloadRepositories()
            await services.engine.accountMappingChanged(repositoryID: repositoryID, settings: settingsStore.settings)
        }
    }

    func editDisposableIgnoredPaths(for repositoryID: UUID) {
        guard let repository = model.repositories.first(where: { $0.id == repositoryID }),
              let paths = Dialogs.editDisposableIgnoredPaths(repository.disposableIgnoredPaths, repositoryName: repository.displayName),
              paths != repository.disposableIgnoredPaths else { return }
        saveDisposableIgnoredPaths(paths, for: repositoryID)
    }

    /// Adds exactly the ignored paths WCleaner reported for this worktree, after the user confirms them.
    func allowDisposableIgnoredFiles(_ worktree: WorktreeSnapshot) {
        guard let repository = model.repositories.first(where: { $0.id == worktree.repositoryID }) else { return }
        let reported = worktree.decision.reasons.compactMap { reason -> [String]? in
            if case .ignoredFiles(let count, let paths) = reason, paths.count == count { paths } else { nil }
        }.first ?? []
        let additions = DisposablePaths.normalizedList(reported)
        guard !additions.isEmpty, additions.count == reported.count else {
            Dialogs.showError(
                "Ignored Files Not Listed",
                "WCleaner could not list every ignored file in this worktree. Add the paths you want to allow in Settings › Repositories."
            )
            return
        }
        guard Dialogs.confirmDisposableIgnoredFiles(additions, repositoryName: repository.displayName) else { return }
        saveDisposableIgnoredPaths(DisposablePaths.normalizedList(repository.disposableIgnoredPaths + additions), for: repository.id)
    }

    private func saveDisposableIgnoredPaths(_ paths: [String], for repositoryID: UUID) {
        guard let services = requireServices() else { return }
        Task {
            do {
                try await services.registry.update(id: repositoryID) { $0.disposableIgnoredPaths = paths }
            } catch {
                Dialogs.showError("Could Not Save the List", error.userMessage)
            }
            await reloadRepositories()
            await services.scheduler.checkNow()
        }
    }

    func refreshDiskUsage() {
        guard let services = requireServices() else { return }
        Task { await services.engine.refreshDiskUsage(force: true) }
    }

    // MARK: Accounts

    func addAccount() {
        startSignIn(expecting: nil)
    }

    func reconnectAccount(_ id: AccountID) {
        if let account = model.account(id), account.source == .gitHubCLI {
            connectGitHubCLI(expecting: account)
        } else {
            startSignIn(expecting: id)
        }
    }

    func addGitHubCLIAccount() {
        connectGitHubCLI(expecting: nil)
    }

    /// Borrows a token from GitHub CLI instead of signing in with the device flow. Works without the
    /// GitHub App being installed in an organization, because GitHub CLI is already authorized there.
    private func connectGitHubCLI(expecting: GitHubAccount?) {
        guard let services = requireServices() else { return }
        Task {
            let available: [GitHubCLIAccount]
            do {
                available = try await services.auth.gitHubCLIAccounts()
            } catch {
                Dialogs.showError("GitHub CLI Is Not Available", error.userMessage)
                return
            }
            guard let login = Dialogs.chooseGitHubCLIAccount(available, preselect: expecting?.login) else { return }
            do {
                let result = try await services.auth.connectGitHubCLI(login: login, expecting: expecting?.id)
                await reloadAccounts()
                for mapping in await services.mappings.all() where mapping.accountID == result.account.id {
                    await services.engine.accountMappingChanged(repositoryID: mapping.repositoryID, settings: settingsStore.settings)
                }
                await services.scheduler.checkNow()
            } catch {
                Dialogs.showError("Could Not Use the GitHub CLI Login", error.userMessage)
            }
        }
    }

    private func startSignIn(expecting: AccountID?) {
        guard configuration.isConfigured else {
            Dialogs.showError(
                "GitHub Sign-In Is Not Configured",
                "This build of WCleaner has no GitHub App client ID, so it cannot sign in with GitHub's device flow. "
                    + "Register a GitHub App with device flow enabled and set WCLEANER_GITHUB_CLIENT_ID as described in GITHUB_APP_SETUP.md, then rebuild. "
                    + "Meanwhile you can use “Use GitHub CLI Login…”."
            )
            return
        }
        guard let services = requireServices() else { return }
        if let deviceFlowController {
            deviceFlowController.show()
            return
        }
        let host = configuration.webBaseURL.host ?? configuration.host
        signInTask = Task {
            let authorization: DeviceAuthorization
            do {
                authorization = try await services.auth.beginSignIn()
            } catch {
                Dialogs.showError("Could Not Start GitHub Sign-In", error.userMessage)
                signInTask = nil
                return
            }
            let controller = DeviceFlowWindowController(authorization: authorization, allowedHost: host, isReconnect: expecting != nil) { [weak self] in
                self?.signInTask?.cancel()
            }
            deviceFlowController = controller
            controller.show()
            do {
                let result = try await services.auth.completeSignIn(authorization, expecting: expecting)
                controller.finish()
                deviceFlowController = nil
                signInTask = nil
                await reloadAccounts()
                for mapping in await services.mappings.all() where mapping.accountID == result.account.id {
                    await services.engine.accountMappingChanged(repositoryID: mapping.repositoryID, settings: settingsStore.settings)
                }
                await services.scheduler.checkNow()
            } catch {
                let cancelled = Task.isCancelled
                controller.finish()
                deviceFlowController = nil
                signInTask = nil
                if !cancelled {
                    Dialogs.showError("GitHub Sign-In Did Not Complete", error.userMessage)
                }
            }
        }
    }

    func disconnectAccount(_ id: AccountID) {
        guard let services = requireServices(), let account = model.account(id) else { return }
        let assigned = model.snapshot.repositories
            .filter { $0.accountResolution.assignedAccount == id }
            .map(\.repository.displayName)
        guard Dialogs.confirmDisconnect(account, assignedRepositories: assigned) else { return }
        Task {
            do {
                try await services.auth.disconnect(id)
            } catch {
                Dialogs.showError("Could Not Disconnect \(account.displayName)", error.userMessage)
            }
            await reloadAccounts()
            // Repositories keep their mapping and show "Account Unavailable" instead of silently using another account.
            for mapping in await services.mappings.all() where mapping.accountID == id {
                await services.engine.accountMappingChanged(repositoryID: mapping.repositoryID, settings: settingsStore.settings)
            }
        }
    }

    // MARK: Cleanup

    func requestCleanupConsent(enableAutomaticCleanup: Bool) {
        if settingsStore.settings.hasCleanupConsent {
            if enableAutomaticCleanup { settingsStore.update { $0.autoCleanupEnabled = true } }
            return
        }
        guard Dialogs.requestCleanupConsent(enableAutomaticCleanup: enableAutomaticCleanup, removalEnabledInBuild: deletionPolicy.allowsRealRemoval) else { return }
        settingsStore.update { settings in
            settings.cleanupConsentAt = Date()
            if enableAutomaticCleanup { settings.autoCleanupEnabled = true }
        }
    }

    func revokeCleanupConsent() {
        guard Dialogs.confirmWithdrawConsent() else { return }
        settingsStore.update { settings in
            settings.cleanupConsentAt = nil
            settings.autoCleanupEnabled = false
            settings.autoCleanupPaused = false
        }
    }

    func reviewWorktree(_ worktree: WorktreeSnapshot) {
        guard let services = requireServices() else { return }
        // The approval is bound to the pull request and commit shown in the dialog.
        guard let shownPullRequest = worktree.decision.evidence?.number, let shownHead = worktree.head else {
            Dialogs.showError("Nothing to Review", MonitorActionError.notAwaitingReview.userMessage)
            return
        }
        switch Dialogs.review(worktree, repository: model.repositorySnapshot(worktree.repositoryID)) {
        case .allow:
            Task {
                do {
                    try await services.engine.approveReview(
                        repositoryID: worktree.repositoryID,
                        worktreePath: worktree.path,
                        expectedPullRequest: shownPullRequest,
                        expectedHead: shownHead,
                        settings: settingsStore.settings
                    )
                } catch {
                    Dialogs.showError("Review Not Saved", error.userMessage)
                }
                await reloadHistory()
            }
        case .openPullRequest:
            openPullRequest(worktree)
        case .cancel:
            break
        }
    }

    /// Opens the worktree's pull request in the browser; only https links on the GitHub web host.
    func openPullRequest(_ worktree: WorktreeSnapshot) {
        guard let string = (worktree.pullRequest?.evidence ?? worktree.decision.evidence)?.url,
              let url = URL(string: string), url.scheme == "https",
              url.host?.lowercased() == configuration.webBaseURL.host?.lowercased() else { return }
        NSWorkspace.shared.open(url)
    }

    func removeWorktreeManually(_ worktree: WorktreeSnapshot) {
        guard let services = requireServices() else { return }
        if !settingsStore.settings.hasCleanupConsent {
            requestCleanupConsent(enableAutomaticCleanup: false)
            guard settingsStore.settings.hasCleanupConsent else { return }
        }
        // The removal is bound to the pull request and commit shown in the confirmation.
        guard let shownPullRequest = worktree.decision.evidence?.number, let shownHead = worktree.head else {
            Dialogs.showError("Worktree Not Removed", MonitorActionError.notSafeToRemove(worktree.decision.blockingReasons).userMessage)
            return
        }
        guard Dialogs.confirmRemoval(worktree, removalEnabledInBuild: deletionPolicy.allowsRealRemoval) else { return }
        Task {
            do {
                let outcome = try await services.engine.removeWorktree(
                    repositoryID: worktree.repositoryID,
                    worktreePath: worktree.path,
                    expectedPullRequest: shownPullRequest,
                    expectedHead: shownHead,
                    settings: settingsStore.settings
                )
                await reloadHistory()
                if !outcome.didRemove { Dialogs.showOutcome(outcome) }
            } catch {
                Dialogs.showError("Worktree Not Removed", error.userMessage)
            }
        }
    }

    /// Removal the user asks for although the pull request is not merged. Every local check still runs.
    func removeWorktreeWithoutMergedPullRequest(_ worktree: WorktreeSnapshot) {
        guard let services = requireServices() else { return }
        if !settingsStore.settings.hasCleanupConsent {
            requestCleanupConsent(enableAutomaticCleanup: false)
            guard settingsStore.settings.hasCleanupConsent else { return }
        }
        // The removal is bound to the commit shown in the confirmation.
        guard worktree.decision.localChecksPassed, let shownHead = worktree.head else {
            Dialogs.showError(
                "Worktree Not Removed",
                MonitorActionError.notSafeToRemove(worktree.decision.localBlockingReasons ?? worktree.decision.blockingReasons).userMessage
            )
            return
        }
        guard Dialogs.confirmRemovalWithoutMergedPullRequest(worktree, removalEnabledInBuild: deletionPolicy.allowsRealRemoval) else { return }
        Task {
            do {
                let outcome = try await services.engine.removeWorktreeWithoutMergedPullRequest(
                    repositoryID: worktree.repositoryID,
                    worktreePath: worktree.path,
                    expectedHead: shownHead,
                    settings: settingsStore.settings
                )
                await reloadHistory()
                if !outcome.didRemove { Dialogs.showOutcome(outcome) }
            } catch {
                Dialogs.showError("Worktree Not Removed", error.userMessage)
            }
        }
    }

    /// Saves the worktree's uncommitted changes in a Git stash, then removes it. Every check still runs.
    func stashChangesAndRemoveWorktree(_ worktree: WorktreeSnapshot) {
        guard let services = requireServices() else { return }
        if !settingsStore.settings.hasCleanupConsent {
            requestCleanupConsent(enableAutomaticCleanup: false)
            guard settingsStore.settings.hasCleanupConsent else { return }
        }
        guard worktree.decision.changesCanBeStashed, let shownHead = worktree.head else {
            Dialogs.showError(
                "Worktree Not Removed",
                MonitorActionError.notSafeToRemove(worktree.decision.localBlockingReasons ?? worktree.decision.blockingReasons).userMessage
            )
            return
        }
        guard Dialogs.confirmStashAndRemoval(worktree, removalEnabledInBuild: deletionPolicy.allowsRealRemoval) else { return }
        Task {
            do {
                let outcome = try await services.engine.stashChangesAndRemoveWorktree(
                    repositoryID: worktree.repositoryID,
                    worktreePath: worktree.path,
                    expectedHead: shownHead,
                    settings: settingsStore.settings
                )
                await reloadHistory()
                // Always say where the changes went, also after a successful removal.
                Dialogs.showOutcome(outcome)
            } catch {
                Dialogs.showError("Worktree Not Removed", error.userMessage)
            }
        }
    }

    // MARK: System integration

    func setLaunchAtLogin(_ enabled: Bool) {
        settingsStore.update { $0.launchAtLoginDesired = enabled }
        do {
            try LaunchAtLoginService.setEnabled(enabled)
        } catch {
            Dialogs.showError("Launch at Login Could Not Be Changed", error.localizedDescription)
        }
        model.update(launchAtLoginStatus: LaunchAtLoginService.status)
    }

    func openLoginItemsSettings() {
        LaunchAtLoginService.openSystemSettings()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settingsStore.update { $0.notificationsEnabled = enabled }
        guard enabled else { return }
        Task { model.update(notificationAuthorization: await notifications.requestAuthorization()) }
    }

    func openNotificationSettings() {
        notifications.openSystemSettings()
    }

    func sendTestNotification() {
        Task {
            let state = await notifications.sendTest()
            model.update(notificationAuthorization: state)
            if state == .denied {
                Dialogs.showError("Notifications Are Turned Off", "Allow notifications for WCleaner in System Settings › Notifications.")
            }
        }
    }

    // MARK: History

    func clearHistory() {
        guard let services = requireServices(), Dialogs.confirmClearHistory() else { return }
        Task {
            do { try await services.history.clear() } catch { Dialogs.showError("Could Not Clear History", error.userMessage) }
            await reloadHistory()
        }
    }

    func revealDataFolder() {
        let data = services?.data ?? AppDataDirectory.standard()
        guard FileManager.default.fileExists(atPath: data.url.path) else {
            Dialogs.showError("No Data Folder Yet", "WCleaner has not stored anything at \(data.url.path).")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([data.url])
    }

    // MARK: Mole (optional, third-party)

    func refreshMoleStatus() {
        Task { await refreshMoleStatusNow() }
    }

    private func refreshMoleStatusNow() async {
        let found = await MoleLocator.locate()
        mole = found
        model.update(moleStatus: found.map { .installed(path: $0.path, version: $0.version) } ?? .notInstalled)
    }

    func openMole() {
        Task { _ = await launchMole(.open) }
    }

    func previewMoleClean() {
        Task {
            guard await launchMole(.previewClean) else { return }
            moleGate.recordPreview(at: Date())
            model.markMolePreviewed()
        }
    }

    func runMoleCleanInTerminal() {
        guard let mole else { return }
        guard moleGate.canOfferClean else {
            Dialogs.showError("Preview First", "Run “Preview Clean (Dry Run)” and check its output before running the real cleanup.")
            return
        }
        guard Dialogs.confirmMoleClean(mole) else { return }
        Task { _ = await launchMole(.clean) }
    }

    private func launchMole(_ action: MoleAction) async -> Bool {
        guard let mole else {
            Dialogs.showError("Mole Is Not Installed", "Install Mole yourself with “brew install mole” to use this optional feature.")
            return false
        }
        do {
            try await TerminalLauncher.run(script: MoleTerminalScript.make(installation: mole, action: action))
            return true
        } catch {
            Dialogs.showError("Could Not Open Terminal", error.userMessage)
            return false
        }
    }

    // MARK: Guides

    func showUninstallInstructions() {
        switch Dialogs.uninstallGuide() {
        case .revealData:
            revealDataFolder()
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Dialogs.uninstallSteps, forType: .string)
        case .done:
            break
        }
    }

    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(model: model) { [weak self] confirmed, launchAtLogin, notificationsOn in
                self?.finishOnboarding(confirmed: confirmed, launchAtLogin: launchAtLogin, notifications: notificationsOn)
            }
        }
        onboardingController?.show()
    }

    private func finishOnboarding(confirmed: Bool, launchAtLogin: Bool, notifications notificationsOn: Bool) {
        onboardingController = nil
        settingsStore.update { $0.onboardingCompleted = true }
        guard confirmed else { return }
        settingsStore.update { $0.notificationsEnabled = notificationsOn }
        let status = LaunchAtLoginService.status
        if launchAtLogin != (status == .enabled || status == .requiresApproval) {
            setLaunchAtLogin(launchAtLogin)
        }
        if notificationsOn {
            Task { model.update(notificationAuthorization: await notifications.requestAuthorization()) }
        }
    }
}
