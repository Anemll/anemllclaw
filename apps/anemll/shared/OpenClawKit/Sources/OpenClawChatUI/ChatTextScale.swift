import SwiftUI

extension EnvironmentValues {
    @Entry var openClawChatTextScale: CGFloat = 1.0
}

// MARK: - Credential Save Environment

private struct OpenClawCredentialSaveKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String, String) -> Bool)? = nil
}

extension EnvironmentValues {
    /// Closure injected by the app layer to store a credential.
    /// Parameters: (service, key) → returns true on success.
    public var openClawCredentialSave: (@Sendable (String, String) -> Bool)? {
        get { self[OpenClawCredentialSaveKey.self] }
        set { self[OpenClawCredentialSaveKey.self] = newValue }
    }
}
