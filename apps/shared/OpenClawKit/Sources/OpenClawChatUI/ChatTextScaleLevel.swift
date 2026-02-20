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

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .extraSmall:
            return "Extra Small"
        case .small:
            return "Small"
        case .default:
            return "Default"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }

    public var textScale: CGFloat {
        switch self {
        case .extraSmall:
            return 0.74
        case .small:
            return 0.88
        case .default:
            return 1.0
        case .large:
            return 1.22
        case .extraLarge:
            return 1.42
        }
    }
}
