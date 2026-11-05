import SwiftUI
import CoreText

enum Design {
    private static let navyValue:UInt32 = 0x193A4A, accentValue:UInt32 = 0x007F92, destructiveValue:UInt32 = 0xA1303E
    static let ink = Color(hex: 0x142A36), secondary = Color(hex: 0x5B707A), navy = Color(hex: navyValue)
    static let accent = Color(hex: accentValue), surface = Color(hex: 0xF7F9F9), tint = Color(hex: 0xEDF3F4)
    static let canvas = Color(hex: 0xDBE3E5), line = Color(hex: 0xC9D4D8), warning = Color(hex: 0xA35F15)
    static let warningSurface = Color(hex: 0xFFF3E4)
    static let destructive = Color(hex: destructiveValue)
    static let accentPressed = Color(hex: 0x006C7D), divider = Color(hex: 0x9FB1B8), success = Color(hex: 0x18745F)
    static let chromeRadius: CGFloat = 26
    static let proposalStroke = stroke(accentValue), rejectedStroke = stroke(destructiveValue), draftStroke = stroke(navyValue)
    private static func stroke(_ hex:UInt32)->CGColor {CGColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)}
    static func font(_ size: CGFloat = 14, bold: Bool = false) -> Font { .custom(bold ? "IBMPlexSans-SemiBold" : "IBMPlexSans", size: size, relativeTo: .body) }
    static func registerFonts() {
        for name in ["IBMPlexSans-Regular", "IBMPlexSans-SemiBold", "IBMPlexSans-Bold", "IBMPlexMono-SemiBold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}
private extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

/// Secondary actions share their surrounding chrome instead of drawing a box each.
/// Primary actions use Apple's glass only where its optical treatment is readable.
struct InstrumentButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        styledLabel(configuration)
            .opacity(enabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
    @ViewBuilder private func styledLabel(_ configuration: Configuration) -> some View {
        if primary {
            if #available(iOS 26, macOS 26, *), !reduceTransparency, contrast != .increased {
                label(configuration)
                    .glassEffect(.regular.tint(Design.accent).interactive(), in: .capsule)
            } else {
                label(configuration)
                    .background(configuration.isPressed ? Design.accentPressed : Design.accent, in: Capsule())
                    .overlay(Capsule().stroke(Design.navy, lineWidth: contrast == .increased ? 2 : 0))
            }
        } else {
            label(configuration)
                .background(configuration.isPressed ? Design.line : .clear, in: Capsule())
        }
    }
    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(Design.font(14, bold: true))
            .foregroundStyle(primary ? .white : configuration.role == .destructive ? Design.destructive : Design.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A single material behind related controls. Never use this on photo/marker content.
private struct InstrumentChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(Design.tint, in: Capsule())
                .overlay(Capsule().stroke(contrast == .increased ? Design.navy : Design.divider, lineWidth: contrast == .increased ? 2 : 1))
        }
    }
}

/// Related glass surfaces share a compositor within one chrome region.
/// Keep each container inside its own viewport boundary, never across the canvas.
struct InstrumentGlassContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12, content: content)
        } else { content() }
    }
}

extension View {
    /// iOS sheets inherit the actual safe window height; desktop panels keep
    /// their established minimums where the window manager supports them.
    @ViewBuilder func instrumentSheet(width: CGFloat, minimumHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: 300, idealWidth: width, minHeight: minimumHeight)
        #else
        self.frame(idealWidth: width)
        #endif
    }
    func instrumentChrome() -> some View { modifier(InstrumentChrome()) }
}
