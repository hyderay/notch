import NotchCore
import SwiftUI

enum Theme {
    static func color(for state: SessionState) -> Color {
        switch state {
        case .thinking: return Color(red: 0.49, green: 0.42, blue: 1.00)
        case .working: return Color(red: 0.18, green: 0.83, blue: 0.65)
        case .waiting: return Color(red: 1.00, green: 0.69, blue: 0.13)
        case .error: return Color(red: 1.00, green: 0.30, blue: 0.31)
        case .done: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .idle: return Color(white: 0.55)
        }
    }

    static func symbol(for state: SessionState) -> String {
        switch state {
        case .thinking: return "brain"
        case .working: return "gearshape.2"
        case .waiting: return "hand.raised"
        case .error: return "exclamationmark.triangle"
        case .done: return "checkmark"
        case .idle: return "pause"
        }
    }

    static let body = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
}
