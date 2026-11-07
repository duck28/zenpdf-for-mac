import AppKit
import SwiftUI

// ZenPDF's look: paper and ink, the same tokens as ZenPDF for Windows (src/App.css).
// Light ("washi") and dark ("sumi") follow the appearance; one vermilion accent, used sparingly.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Parses "#rrggbb" or "#rgb" like the Windows app; anything unreadable is black.
    convenience init(cssHex: String, alpha: CGFloat = 1) {
        let rgb = ColorHex.components(cssHex)
        self.init(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: alpha)
    }

    /// A color that switches between a light and a dark value with the appearance.
    static func zen(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    /// "#rrggbb" in sRGB.
    var cssHex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

enum ColorHex {
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let chars = Array(h)
        func channel(_ i: Int) -> Double {
            guard i + 2 <= chars.count, let v = Int(String(chars[i..<(i + 2)]), radix: 16) else { return 0 }
            return Double(v) / 255
        }
        return (channel(0), channel(2), channel(4))
    }

    static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let c = components(hex)
        return CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha))
    }
}

enum Zen {
    static let app = NSColor.zen(light: 0xF5F3EE, dark: 0x141413)
    static let surface = NSColor.zen(light: 0xFBFAF7, dark: 0x1A1A18)
    static let raised = NSColor.zen(light: 0xEEEBE4, dark: 0x262522)
    static let line = NSColor.zen(light: 0xE3DFD6, dark: 0x2D2C29)
    static let ink = NSColor.zen(light: 0x1F1E1C, dark: 0xEBE7DF)
    static let ink2 = NSColor.zen(light: 0x5F5B54, dark: 0xAAA59B)
    static let ink3 = NSColor.zen(light: 0x9B968D, dark: 0x6F6B64)
    static let accent = NSColor.zen(light: 0xB9432F, dark: 0xE0644C)
    static let viewer = NSColor.zen(light: 0xE8E5DE, dark: 0x0F0F0E)
    static let onInk = NSColor.zen(light: 0xFBFAF7, dark: 0x161614)
    /// The selection outline on pages (always the light vermilion, like Windows).
    static let selection = NSColor(hex: 0xB9432F)
}

extension Color {
    static let zenApp = Color(nsColor: Zen.app)
    static let zenSurface = Color(nsColor: Zen.surface)
    static let zenRaised = Color(nsColor: Zen.raised)
    static let zenLine = Color(nsColor: Zen.line)
    static let zenInk = Color(nsColor: Zen.ink)
    static let zenInk2 = Color(nsColor: Zen.ink2)
    static let zenInk3 = Color(nsColor: Zen.ink3)
    static let zenAccent = Color(nsColor: Zen.accent)
    static let zenViewer = Color(nsColor: Zen.viewer)
    static let zenOnInk = Color(nsColor: Zen.onInk)

    init(cssHex: String) {
        self.init(nsColor: NSColor(cssHex: cssHex))
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Logo

/// The ZenPDF mark: a brush-stroke "Z" in an open ensō with a vermilion seal. The artwork is two alpha masks
/// (Resources/Branding/ink.png and dot.png, copied into the app by build.sh), so the ink follows the text color
/// in light and dark mode while the seal keeps the accent.
struct ZenLogo: View {
    var size: CGFloat = 28

    private static let ink = Bundle.main.image(forResource: "ink")
    private static let dot = Bundle.main.image(forResource: "dot")

    var body: some View {
        ZStack {
            if let ink = Self.ink, let dot = Self.dot {
                Image(nsImage: ink).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color.zenInk)
                Image(nsImage: dot).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color.zenAccent)
            } else {
                // Running outside the app bundle (swift run): a simple stand-in.
                Circle().strokeBorder(Color.zenInk, lineWidth: max(1, size / 14))
                Text("Z").font(.system(size: size * 0.5, weight: .light)).foregroundStyle(Color.zenInk)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("ZenPDF")
    }
}

// MARK: - Buttons

/// Quiet icon buttons, as in the Windows tool dock: ink-2, ink on hover, a raised fill when active.
struct ZenIconButtonStyle: ButtonStyle {
    var active = false
    var width: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        ZenIconButton(configuration: configuration, active: active, width: width)
    }

    private struct ZenIconButton: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let width: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(active || (isHovered && isEnabled) ? Color.zenInk : Color.zenInk2)
                .frame(minWidth: width, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active || (isHovered && isEnabled) || configuration.isPressed ? Color.zenRaised : .clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { isHovered = $0 }
        }
    }
}

/// The ink button (primary) or a quiet text button.
struct ZenButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ZenButton(configuration: configuration, prominent: prominent)
    }

    private struct ZenButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13))
                .foregroundStyle(prominent ? Color.zenOnInk : (isHovered ? Color.zenInk : Color.zenInk2))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Color.zenInk : (isHovered ? Color.zenRaised : .clear)))
                .opacity(isEnabled ? (prominent && isHovered ? 0.85 : 1) : 0.35)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// The small accent dot that marks unsaved changes and the current file.
struct AccentDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(Color.zenAccent).frame(width: size, height: size)
    }
}

/// A hairline divider in the theme's line color.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(Color.zenLine).frame(width: vertical ? 1 : nil, height: vertical ? 16 : 1)
    }
}
