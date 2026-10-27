import SwiftUI

/// Colors from Figma "Kinrox — Design", collection `Kinrox / Color`.
/// Values reside in `Resources/Branding.xcassets` under the same names.
public enum Palette {
    public static let base = Color("bg/base")
    public static let canvas = Color("bg/canvas")
    public static let elevated = Color("bg/elevated")
    public static let glass = Color("surface/glass")
    public static let glassStrong = Color("surface/glass-strong")
    public static let hairline = Color("stroke/hairline")
    public static let strokeGlass = Color("stroke/glass")
    public static let textPrimary = Color("text/primary")
    public static let textSecondary = Color("text/secondary")
    public static let textTertiary = Color("text/tertiary")
    public static let textMuted = Color("text/muted")
    public static let ember = Color("accent/ember")
    public static let flame = Color("accent/flame")
    public static let crimson = Color("accent/crimson")
    public static let online = Color("state/online")

    public static let bgDeep = Color("bg/deep")
    public static let bgPanel = Color("bg/panel")
    public static let bgElevated = Color("bg/elevated")
    public static let bgPill = Color("bg/pill")
    public static let accentFlame = flame
    public static let accentEmber = ember
    public static let accentCrimson = crimson

    /// Fiery progress gradient and primary buttons: crimson → ember → flame.
    public static let emberGradient = LinearGradient(
        colors: [crimson, ember, flame], startPoint: .leading, endPoint: .trailing)
    public static let emberDiagonal = LinearGradient(
        colors: [flame, ember, crimson], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let fireGradient = emberGradient
}

/// Typography styles `Kinrox/*` from Figma. System font: SF Pro and SF Pro Rounded.
public enum KinroxFont {
    public static func display(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .bold).width(.expanded)
    }
    public static func displayHero() -> Font {
        .system(size: 48, weight: .bold, design: .rounded)
    }
    public static func titleLarge(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold).width(.expanded)
    }
    public static func titleLarge() -> Font {
        .system(size: 24, weight: .semibold, design: .default)
    }
    public static func titleMedium() -> Font {
        .system(size: 18, weight: .medium, design: .default)
    }
    public static let title = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 14)
    public static let bodyStrong = Font.system(size: 14, weight: .medium)
    public static let caption = Font.system(size: 12, weight: .medium)
    public static let overline = Font.system(size: 11, weight: .semibold)
    public static let time = Font.system(size: 13, weight: .medium, design: .rounded)
        .monospacedDigit()
    public static func timeLarge(_ size: CGFloat = 48) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    public static func monoDigits(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

extension Text {
    /// Section divider label: tracking uppercase, matching style `Kinrox/Overline`.
    public func overlineStyle(_ color: Color = Palette.textTertiary) -> some View {
        font(KinroxFont.overline).tracking(1.2).textCase(.uppercase).foregroundStyle(color)
    }
}

extension View {
    /// Liquid Glass on macOS/iOS 26; fallback material with thin stroke on earlier OS versions.
    @ViewBuilder
    public func kinroxGlass<S: InsettableShape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Palette.strokeGlass, lineWidth: 1))
        }
    }

    /// Soft amber glow, effect `Kinrox/Ember Glow`.
    public func emberGlow(radius: CGFloat = 14, opacity: Double = 0.55, y: CGFloat = 6) -> some View
    {
        shadow(color: Palette.ember.opacity(opacity), radius: radius, y: y)
    }
}
