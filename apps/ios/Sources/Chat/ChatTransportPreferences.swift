import Foundation

enum ChatTransportMode: String {
    case gateway = "gateway"
    case openAIWebSocket = "openai-websocket"
}

enum ChatTransportPreferences {
    // Legacy global mode key (kept for migration compatibility).
    static let modeDefaultsKey = "chat.transport.mode"
    // New provider-scoped toggle (off by default).
    static let openAIWebSocketEnabledDefaultsKey = "chat.transport.openai.websocket.enabled"
    static let openAIModelDefaultsKey = "chat.openai.model"
    static let defaultOpenAIModel = "gpt-5.2"

    static func isOpenAIWebSocketEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let value = defaults.object(forKey: self.openAIWebSocketEnabledDefaultsKey) as? Bool {
            return value
        }
        let rawMode = defaults.string(forKey: self.modeDefaultsKey) ?? ""
        return rawMode == ChatTransportMode.openAIWebSocket.rawValue
    }

    static func migrateLegacyModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: self.openAIWebSocketEnabledDefaultsKey) == nil else { return }
        defaults.set(self.isOpenAIWebSocketEnabled(defaults: defaults), forKey: self.openAIWebSocketEnabledDefaultsKey)
    }
}
