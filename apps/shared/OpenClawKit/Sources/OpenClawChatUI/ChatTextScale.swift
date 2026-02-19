import SwiftUI

private struct OpenClawChatTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var openClawChatTextScale: CGFloat {
        get { self[OpenClawChatTextScaleKey.self] }
        set { self[OpenClawChatTextScaleKey.self] = max(0.7, min(1.8, newValue)) }
    }
}
