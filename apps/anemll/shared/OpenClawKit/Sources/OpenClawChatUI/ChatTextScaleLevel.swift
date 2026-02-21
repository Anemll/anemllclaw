import CoreGraphics
import Foundation

public enum OpenClawChatTextScaleLevel: String, CaseIterable, Identifiable, Sendable {
    case extraSmall
    case small
    case `default`
    case large
    case extraLarge

    public static let defaultsKey = "chat.main.zoomLevel"
    public static let defaultLevel: OpenClawChatTextScaleLevel = .default

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .extraSmall:
            "Extra Small"
        case .small:
            "Small"
        case .default:
            "Default"
        case .large:
            "Large"
        case .extraLarge:
            "Extra Large"
        }
    }

    public var textScale: CGFloat {
        switch self {
        case .extraSmall:
            0.74
        case .small:
            0.88
        case .default:
            1.0
        case .large:
            1.22
        case .extraLarge:
            1.42
        }
    }
}
