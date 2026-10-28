import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// App windows (main window, popover, panels): forced dark, navy + teal (D-008). Widgets have their
/// own Light/Dark looks (Shared/Widgets), so nothing here is widget-specific.
enum AppTheme {
    static let accent = Color(hex: 0x3CCBB4)
    static let accentText = Color(hex: 0x05201B)
    static let accentSoft = Color(hex: 0x3CCBB4, opacity: 0.16)
    static let bgTop = Color(hex: 0x14232C)
    static let bgBottom = Color(hex: 0x0C161D)
    static let sidebar = Color.white.opacity(0.035)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.09)
    /// The hairline of a card floating over a dimmed window (the composer's approval card).
    static let strokeStrong = Color.white.opacity(0.14)
    static let text = Color(hex: 0xE9F4F1)
    static let text2 = Color(hex: 0xE9F4F1, opacity: 0.64)
    static let text3 = Color(hex: 0xE9F4F1, opacity: 0.40)
    static let good = Color(hex: 0x6BB857)
    static let warn = Color(hex: 0xD99E47)
    static let bad = Color(hex: 0xE36166)
    static let paper = Color(hex: 0xF8F5F0)

    /// Account colours, assigned in order (muted, never the accent).
    static let accountSwatches: [UInt32] = [0x8FB4C4, 0xB8A99A, 0xC9A3E6, 0xE0A35C, 0xE07A80, 0x8DBA74, 0x7F96E8, 0xD2A6C6]

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
