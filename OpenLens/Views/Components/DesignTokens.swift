import Observation
import SwiftUI
import UIKit

// MARK: - Design System

private extension UIColor {
    static func openLens(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
}

struct OpenLensSemanticColor {
    let light: UIColor
    let dark: UIColor

    init(light: UIColor, dark: UIColor? = nil) {
        self.light = light
        self.dark = dark ?? light
    }

    var color: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? self.dark : self.light
            }
        )
    }
}

struct OpenLensColorTokens {
    let background: OpenLensSemanticColor
    let surface: OpenLensSemanticColor
    let primary: OpenLensSemanticColor
    let secondary: OpenLensSemanticColor
    let tertiary: OpenLensSemanticColor
    let separator: OpenLensSemanticColor
    let accent: OpenLensSemanticColor
    let onAccent: OpenLensSemanticColor
    let success: OpenLensSemanticColor
    let warning: OpenLensSemanticColor
    let danger: OpenLensSemanticColor
    /// User chat bubble and its text. `nil` = the user accent (Settings → Appearance).
    var userBubble: OpenLensSemanticColor? = nil
    var onUserBubble: OpenLensSemanticColor? = nil
    /// Send button and its glyph. `nil` = the user accent.
    var sendAction: OpenLensSemanticColor? = nil
    var onSendAction: OpenLensSemanticColor? = nil
}

struct OpenLensTypographyTokens {
    let sectionLabel: Font
    let rowTitle: Font
    let rowSubtitle: Font
    let body: Font
    /// Code, tool calls, paths and commands. Falls back to the system monospaced font.
    let monoFamily: String?

    init(
        sectionLabel: Font = .system(size: 12, weight: .semibold, design: .rounded),
        rowTitle: Font = .system(size: 15, weight: .medium, design: .rounded),
        rowSubtitle: Font = .system(size: 13),
        body: Font = .system(size: 15),
        monoFamily: String? = nil
    ) {
        self.sectionLabel = sectionLabel
        self.rowTitle = rowTitle
        self.rowSubtitle = rowSubtitle
        self.body = body
        self.monoFamily = monoFamily
    }

    /// Monospaced font for code-like text: the theme's bundled family when it is
    /// registered, otherwise the system monospaced design.
    func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let monoFamily, UIFont(name: monoFamily, size: size) != nil {
            return .custom(monoFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

struct OpenLensSpacingTokens {
    let xSmall: CGFloat
    let small: CGFloat
    let medium: CGFloat
    let large: CGFloat
    let xLarge: CGFloat
    let xxLarge: CGFloat

    init(
        xSmall: CGFloat = 4,
        small: CGFloat = 8,
        medium: CGFloat = 12,
        large: CGFloat = 16,
        xLarge: CGFloat = 20,
        xxLarge: CGFloat = 24
    ) {
        self.xSmall = xSmall
        self.small = small
        self.medium = medium
        self.large = large
        self.xLarge = xLarge
        self.xxLarge = xxLarge
    }
}

struct OpenLensRadiusTokens {
    let control: CGFloat
    let iconTile: CGFloat
    let card: CGFloat
    let largeCard: CGFloat
    let heroCard: CGFloat

    init(
        control: CGFloat = 14,
        iconTile: CGFloat = 10,
        card: CGFloat = 20,
        largeCard: CGFloat = 24,
        heroCard: CGFloat = 36
    ) {
        self.control = control
        self.iconTile = iconTile
        self.card = card
        self.largeCard = largeCard
        self.heroCard = heroCard
    }
}

struct OpenLensShadowStyle {
    let color: OpenLensSemanticColor
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

struct OpenLensShadowTokens {
    let surface: OpenLensShadowStyle
    let subtle: OpenLensShadowStyle
}

struct OpenLensStrokeStyle {
    let color: OpenLensSemanticColor
    let width: CGFloat

    static let none = OpenLensStrokeStyle(
        color: .init(light: .clear),
        width: 0
    )
}

struct OpenLensComponentTokens {
    let cardPadding: CGFloat
    let rowHorizontalPadding: CGFloat
    let rowVerticalPadding: CGFloat
    let iconTileSize: CGFloat
    let surfaceBorder: OpenLensStrokeStyle
    let surfaceInnerBorder: OpenLensStrokeStyle
    let controlBorder: OpenLensStrokeStyle
    let iconTileBorder: OpenLensStrokeStyle
    /// Flat bordered surfaces instead of materials / Liquid Glass.
    let flatSurfaces: Bool

    init(
        cardPadding: CGFloat = 16,
        rowHorizontalPadding: CGFloat = 16,
        rowVerticalPadding: CGFloat = 14,
        iconTileSize: CGFloat = 36,
        surfaceBorder: OpenLensStrokeStyle = .none,
        surfaceInnerBorder: OpenLensStrokeStyle = .none,
        controlBorder: OpenLensStrokeStyle = .none,
        iconTileBorder: OpenLensStrokeStyle = .none,
        flatSurfaces: Bool = false
    ) {
        self.cardPadding = cardPadding
        self.rowHorizontalPadding = rowHorizontalPadding
        self.rowVerticalPadding = rowVerticalPadding
        self.iconTileSize = iconTileSize
        self.surfaceBorder = surfaceBorder
        self.surfaceInnerBorder = surfaceInnerBorder
        self.controlBorder = controlBorder
        self.iconTileBorder = iconTileBorder
        self.flatSurfaces = flatSurfaces
    }
}

struct OpenLensTheme {
    let id: String
    let name: String
    let colors: OpenLensColorTokens
    let typography: OpenLensTypographyTokens
    let spacing: OpenLensSpacingTokens
    let radius: OpenLensRadiusTokens
    let shadow: OpenLensShadowTokens
    let components: OpenLensComponentTokens
}

enum OpenLensAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "openLensAppearance"
    static let fallback: OpenLensAppearance = .opencode

    case opencode
    case classic
    case graphite
    case meadow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opencode: "OpenCode"
        case .classic: "Classic"
        case .graphite: "Graphite"
        case .meadow: "Meadow"
        }
    }

    var subtitle: String {
        switch self {
        case .opencode: "OpenCode grey"
        case .classic: "Warm neutral"
        case .graphite: "Cool graphite"
        case .meadow: "Soft green"
        }
    }

    var theme: OpenLensTheme {
        switch self {
        case .opencode: .opencode
        case .classic: .classic
        case .graphite: .graphite
        case .meadow: .meadow
        }
    }

    static var current: OpenLensAppearance {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
                  let appearance = OpenLensAppearance(rawValue: rawValue)
            else {
                return .fallback
            }
            return appearance
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}

extension OpenLensTheme {
    /// The official OpenCode web/desktop look (`oc-2` theme of anomalyco/opencode):
    /// neutral greys, small corners, 1 pt borders instead of shadows, JetBrains Mono for code.
    static let opencode = OpenLensTheme(
        id: "opencode",
        name: "OpenCode",
        colors: OpenLensColorTokens(
            background: .init(light: .white, dark: .openLens(22, 22, 22)),
            surface: .init(light: .openLens(248, 248, 248), dark: .openLens(28, 28, 28)),
            primary: .init(light: .openLens(23, 23, 23), dark: .openLens(237, 237, 237)),
            secondary: .init(light: .openLens(111, 111, 111), dark: .openLens(160, 160, 160)),
            tertiary: .init(light: .openLens(243, 243, 243), dark: .openLens(35, 35, 35)),
            separator: .init(light: .openLens(232, 232, 232), dark: .openLens(40, 40, 40)),
            accent: .init(light: .openLens(23, 19, 17), dark: .openLens(241, 236, 232)),
            onAccent: .init(light: .white, dark: .openLens(23, 19, 17)),
            success: .init(light: .openLens(10, 160, 0), dark: .openLens(18, 201, 5)),
            warning: .init(light: .openLens(184, 138, 0), dark: .openLens(252, 213, 58)),
            danger: .init(light: .openLens(220, 60, 40), dark: .openLens(252, 83, 58)),
            userBubble: .init(light: .openLens(240, 240, 240), dark: .openLens(42, 42, 42)),
            onUserBubble: .init(light: .openLens(23, 23, 23), dark: .openLens(237, 237, 237)),
            sendAction: .init(light: .openLens(23, 19, 17), dark: .openLens(241, 236, 232)),
            onSendAction: .init(light: .white, dark: .openLens(23, 19, 17))
        ),
        typography: OpenLensTypographyTokens(
            sectionLabel: .system(size: 12, weight: .medium),
            rowTitle: .system(size: 15, weight: .semibold),
            rowSubtitle: .system(size: 13),
            body: .system(size: 15),
            monoFamily: "JetBrainsMono-Regular"
        ),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(control: 8, iconTile: 4, card: 10, largeCard: 10, heroCard: 12),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(color: .init(light: .clear), radius: 0, x: 0, y: 0),
            subtle: OpenLensShadowStyle(color: .init(light: .clear), radius: 0, x: 0, y: 0)
        ),
        components: OpenLensComponentTokens(
            surfaceBorder: OpenLensStrokeStyle(
                color: .init(light: .openLens(232, 232, 232), dark: .openLens(40, 40, 40)),
                width: 1
            ),
            controlBorder: OpenLensStrokeStyle(
                color: .init(light: .openLens(219, 219, 219), dark: .openLens(48, 48, 48)),
                width: 1
            ),
            flatSurfaces: true
        )
    )

    static let classic = OpenLensTheme(
        id: "classic",
        name: "Classic",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(245, 244, 242), dark: .openLens(20, 21, 24)),
            surface: .init(light: .white, dark: .openLens(30, 32, 36)),
            primary: .init(light: .openLens(26, 26, 26), dark: .openLens(245, 244, 242)),
            secondary: .init(light: .openLens(107, 107, 107), dark: .openLens(171, 168, 161)),
            tertiary: .init(light: .openLens(239, 237, 233), dark: .openLens(44, 46, 51)),
            separator: .init(light: .openLens(224, 222, 221), dark: .openLens(64, 66, 71)),
            accent: .init(light: .openLens(26, 26, 26), dark: .openLens(167, 139, 250)),
            onAccent: .init(light: .white, dark: .openLens(26, 26, 26)),
            success: .init(light: .openLens(31, 145, 84), dark: .openLens(77, 199, 130)),
            warning: .init(light: .openLens(194, 117, 35), dark: .openLens(235, 166, 78)),
            danger: .init(light: .openLens(208, 58, 58), dark: .openLens(255, 112, 112))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(0, 0, 0, alpha: 0.06), dark: .openLens(0, 0, 0, alpha: 0.32)),
                radius: 8,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(0, 0, 0, alpha: 0.04), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )

    static let graphite = OpenLensTheme(
        id: "graphite",
        name: "Graphite",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(242, 244, 246), dark: .openLens(16, 18, 20)),
            surface: .init(light: .white, dark: .openLens(25, 28, 31)),
            primary: .init(light: .openLens(20, 26, 34), dark: .openLens(245, 247, 249)),
            secondary: .init(light: .openLens(100, 110, 122), dark: .openLens(160, 170, 181)),
            tertiary: .init(light: .openLens(232, 236, 240), dark: .openLens(38, 43, 48)),
            separator: .init(light: .openLens(216, 221, 226), dark: .openLens(58, 64, 70)),
            accent: .init(light: .openLens(42, 88, 103), dark: .openLens(146, 218, 204)),
            onAccent: .init(light: .white, dark: .openLens(13, 23, 25)),
            success: .init(light: .openLens(28, 134, 86), dark: .openLens(91, 205, 146)),
            warning: .init(light: .openLens(184, 113, 31), dark: .openLens(237, 172, 83)),
            danger: .init(light: .openLens(199, 55, 61), dark: .openLens(255, 119, 126))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(22, 32, 43, alpha: 0.08), dark: .openLens(0, 0, 0, alpha: 0.34)),
                radius: 9,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(22, 32, 43, alpha: 0.05), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )

    static let meadow = OpenLensTheme(
        id: "meadow",
        name: "Meadow",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(246, 247, 241), dark: .openLens(16, 22, 20)),
            surface: .init(light: .openLens(255, 255, 252), dark: .openLens(25, 33, 30)),
            primary: .init(light: .openLens(27, 33, 28), dark: .openLens(242, 247, 241)),
            secondary: .init(light: .openLens(94, 108, 92), dark: .openLens(164, 180, 166)),
            tertiary: .init(light: .openLens(235, 240, 231), dark: .openLens(36, 47, 42)),
            separator: .init(light: .openLens(220, 228, 216), dark: .openLens(55, 68, 61)),
            accent: .init(light: .openLens(28, 110, 80), dark: .openLens(114, 212, 161)),
            onAccent: .init(light: .white, dark: .openLens(11, 22, 16)),
            success: .init(light: .openLens(28, 128, 83), dark: .openLens(112, 216, 156)),
            warning: .init(light: .openLens(172, 112, 38), dark: .openLens(232, 174, 91)),
            danger: .init(light: .openLens(194, 62, 61), dark: .openLens(252, 126, 124))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(30, 58, 42, alpha: 0.07), dark: .openLens(0, 0, 0, alpha: 0.32)),
                radius: 8,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(30, 58, 42, alpha: 0.05), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )
}

enum OpenLensDesignSystem {
    static var currentTheme: OpenLensTheme {
        OpenLensAppearance.fallback.theme
    }
}

// MARK: - Accent Color Preference

/// Global, persisted user accent color.
///
/// Stored in `UserDefaults` under `AppPreferenceKeys.accentColor` as a 6-digit hex string
/// (empty = use the theme accent). Because this is `@Observable`, any SwiftUI view that reads
/// `Color.appUserAccent` / `Color.appUserOnAccent` in its `body` is automatically re-rendered when
/// the user picks a new color. Scoped to the Settings screen, the chat bubble background, and the
/// message send button — everywhere else uses the fixed theme accent (`Color.appAccent`).
@Observable
final class AccentColorPreference {
    static let shared = AccentColorPreference()

    @ObservationIgnored private let userDefaults: UserDefaults

    /// Normalized `RRGGBB` hex, or empty when the theme default is used.
    private(set) var hex: String

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.hex = Self.normalizedHex(userDefaults.string(forKey: AppPreferenceKeys.accentColor)) ?? ""
    }

    var hasCustomColor: Bool { !hex.isEmpty }

    /// The accent color used across the app.
    var color: Color {
        guard let custom = Self.uiColor(fromHex: hex) else {
            return OpenLensDesignSystem.currentTheme.colors.accent.color
        }
        return Color(uiColor: custom)
    }

    /// Foreground color that stays readable on top of `color`.
    var onAccentColor: Color {
        guard let custom = Self.uiColor(fromHex: hex) else {
            return OpenLensDesignSystem.currentTheme.colors.onAccent.color
        }
        return Self.isLight(custom) ? Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255) : .white
    }

    /// Two-way binding for `ColorPicker`.
    var binding: Binding<Color> {
        Binding(
            get: { self.color },
            set: { self.setColor($0) }
        )
    }

    func setColor(_ color: Color) {
        guard let newHex = Self.hex(from: UIColor(color)) else { return }
        guard newHex != hex else { return }
        hex = newHex
        userDefaults.set(newHex, forKey: AppPreferenceKeys.accentColor)
    }

    func reset() {
        guard hasCustomColor else { return }
        hex = ""
        userDefaults.removeObject(forKey: AppPreferenceKeys.accentColor)
    }

    // MARK: Helpers

    static func normalizedHex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return value
    }

    static func uiColor(fromHex hex: String) -> UIColor? {
        guard let normalized = normalizedHex(hex), let value = UInt32(normalized, radix: 16) else {
            return nil
        }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hex(from color: UIColor) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", component(red), component(green), component(blue))
    }

    private static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > lightColorLuminanceThreshold
    }

    /// Relative luminance above which the accent counts as light enough for a dark foreground.
    /// Deliberately above the 0.179 black/white contrast crossover so mid-tones such as iOS blue,
    /// orange, and green keep a white arrow/text; only genuinely pale colors switch to dark.
    private static let lightColorLuminanceThreshold: CGFloat = 0.5
}

private struct OpenLensThemeKey: EnvironmentKey {
    static let defaultValue: OpenLensTheme = OpenLensDesignSystem.currentTheme
}

extension EnvironmentValues {
    var openLensTheme: OpenLensTheme {
        get { self[OpenLensThemeKey.self] }
        set { self[OpenLensThemeKey.self] = newValue }
    }
}

private struct OpenLensThemeModifier: ViewModifier {
    let theme: OpenLensTheme
    private let accent = AccentColorPreference.shared

    func body(content: Content) -> some View {
        content
            .environment(\.openLensTheme, theme)
            .environment(accent)
            .tint(theme.colors.accent.color)
    }
}

extension View {
    func openLensTheme(_ theme: OpenLensTheme) -> some View {
        modifier(OpenLensThemeModifier(theme: theme))
    }
}

extension Color {
    static var appBackground: Color { OpenLensDesignSystem.currentTheme.colors.background.color }
    static var appSurface: Color { OpenLensDesignSystem.currentTheme.colors.surface.color }
    static var appPrimary: Color { OpenLensDesignSystem.currentTheme.colors.primary.color }
    static var appSecondary: Color { OpenLensDesignSystem.currentTheme.colors.secondary.color }
    static var appTertiary: Color { OpenLensDesignSystem.currentTheme.colors.tertiary.color }
    static var appSeparator: Color { OpenLensDesignSystem.currentTheme.colors.separator.color }
    static var appAccent: Color { OpenLensDesignSystem.currentTheme.colors.accent.color }
    static var appOnAccent: Color { OpenLensDesignSystem.currentTheme.colors.onAccent.color }
    /// User-selected accent (Settings → Appearance) or the theme accent, scoped to the Settings
    /// screen, the chat bubble background, and the message send button. Observable: views reading
    /// this in `body` refresh automatically when the preference changes.
    static var appUserAccent: Color { AccentColorPreference.shared.color }
    static var appUserOnAccent: Color { AccentColorPreference.shared.onAccentColor }
    /// User chat bubble: the theme's own bubble color when it defines one, else the user accent.
    static var appUserBubble: Color {
        OpenLensDesignSystem.currentTheme.colors.userBubble?.color ?? appUserAccent
    }
    static var appOnUserBubble: Color {
        OpenLensDesignSystem.currentTheme.colors.onUserBubble?.color ?? appUserOnAccent
    }
    /// Send button: the theme's action color when it defines one, else the user accent.
    static var appSendAction: Color {
        OpenLensDesignSystem.currentTheme.colors.sendAction?.color ?? appUserAccent
    }
    static var appOnSendAction: Color {
        OpenLensDesignSystem.currentTheme.colors.onSendAction?.color ?? appUserOnAccent
    }
    /// Hairline border used by flat themes (clear when the theme has none).
    static var appBorder: Color { OpenLensDesignSystem.currentTheme.components.controlBorder.color.color }
    /// Fixed primary-button colors for the connection flow (onboarding, setup, connect) and the
    /// new-session FAB. Ignore both the theme accent and the user accent: near-black with white
    /// text in light mode, white with black text in dark mode.
    static let appNeutralAction = OpenLensSemanticColor(light: .openLens(26, 26, 26), dark: .white).color
    static let appOnNeutralAction = OpenLensSemanticColor(light: .white, dark: .black).color
    static var appSuccess: Color { OpenLensDesignSystem.currentTheme.colors.success.color }
    static var appWarning: Color { OpenLensDesignSystem.currentTheme.colors.warning.color }
    static var appDanger: Color { OpenLensDesignSystem.currentTheme.colors.danger.color }
}

extension Font {
    /// The active theme's code font (JetBrains Mono in the OpenCode look, SF Mono otherwise).
    static func openLensMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        OpenLensDesignSystem.currentTheme.typography.mono(size: size, weight: weight)
    }
}

// MARK: - Primary Call To Action

extension View {
    /// Filled call-to-action that follows the text color rather than the user's
    /// accent: light with dark text in dark mode, dark with light text in light mode.
    func primaryCTAStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.appPrimary)
            .foregroundStyle(Color.appBackground)
    }
}

// MARK: - Surface Shadow

private struct OpenLensShadowModifier: ViewModifier {
    @Environment(\.openLensTheme) private var theme

    let style: KeyPath<OpenLensShadowTokens, OpenLensShadowStyle>

    func body(content: Content) -> some View {
        let shadow = theme.shadow[keyPath: style]
        content.shadow(
            color: shadow.color.color,
            radius: shadow.radius,
            x: shadow.x,
            y: shadow.y
        )
    }
}

extension View {
    func surfaceShadow() -> some View {
        modifier(OpenLensShadowModifier(style: \.surface))
    }

    func subtleShadow() -> some View {
        modifier(OpenLensShadowModifier(style: \.subtle))
    }
}
