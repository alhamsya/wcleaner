import Foundation

enum AppEnvironment {
    /// True when the app is only hosting the unit-test bundle; no UI or background work should start.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "io.github.alhamsya.WCleaner"
    }

    static let repositoryURL = URL(string: "https://github.com/alhamsya/wcleaner")!

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
