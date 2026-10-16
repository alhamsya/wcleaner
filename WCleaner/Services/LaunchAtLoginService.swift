import ServiceManagement

/// Launch at Login through `SMAppService.mainApp`. The status shown in the UI is always what macOS reports.
@MainActor
enum LaunchAtLoginService {
    static var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable("macOS could not find this copy of WCleaner. Move it to the Applications folder and try again.")
        @unknown default: .unavailable("Unknown status.")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
