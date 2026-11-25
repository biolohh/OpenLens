import SwiftUI
import UIKit

/// Colours of the syntax kinds. The app theme has no syntax tokens (only accent, success,
/// warning, danger), so this is the minimal set the highlighter needs; each kind has a light and
/// a dark value and resolves through the current trait collection, like the theme's own tokens.
enum OCSyntaxTheme {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        let lightColor = ui(light)
        let darkColor = ui(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }

    private static let keyword = pair(0xCF222E, 0xFF7B72)
    private static let string = pair(0x0A3069, 0xA5D6FF)
    private static let comment = pair(0x6E7781, 0x8B949E)
    private static let number = pair(0x0550AE, 0x79C0FF)
    private static let type = pair(0x953800, 0xFFA657)
    private static let function = pair(0x6639BA, 0xD2A8FF)
    private static let tag = pair(0x116329, 0x7EE787)
    private static let property = pair(0x0550AE, 0x79C0FF)

    /// `nil` = the surrounding text colour.
    static func color(for kind: OCSyntaxKind) -> Color? {
        switch kind {
        case .plain: nil
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type: type
        case .function: function
        case .tag: tag
        case .property: property
        }
    }

    /// One line as coloured text; an empty line is a single space so the row keeps its height.
    static func attributed(_ segments: [OCSyntaxSegment]) -> AttributedString {
        guard !segments.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            if let color = color(for: segment.kind) { piece.foregroundColor = color }
            result.append(piece)
        }
        return result
    }
}
