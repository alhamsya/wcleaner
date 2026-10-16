import Foundation

extension Error {
    /// A short English message suitable for the UI and the audit log. Never includes secrets:
    /// WCleaner's own error types are written so that tokens are never part of their messages.
    public var userMessage: String {
        if let localized = self as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: self)
    }
}
