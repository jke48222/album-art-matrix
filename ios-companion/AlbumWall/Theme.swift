// The Paper design language, as tokens.
//
// Two voices: Archivo (the music speaks — titles, labels, buttons) and
// IBM Plex Mono (the machine answers — hosts, timestamps, statuses).
// One ground (warm paper, or warm ink at night), one accent ("signal",
// primary actions and alerts only). Every other color on screen belongs
// to whatever the wall is showing. No shadows, no gradients in the chrome.
import CoreText
import SwiftUI
import UIKit

enum Appearance: String, CaseIterable {
    case paper, night, auto

    var label: String {
        switch self {
        case .paper: "Paper"
        case .night: "Night"
        case .auto: "Auto"
        }
    }
}

struct Theme {
    let ground: Color        // page background
    let ink: Color           // type + controls
    let isNight: Bool

    static let signal = Color(hex: 0xE03E1A)     // primary buttons, alerts
    static let panel = Color(hex: 0x0A0A0A)      // the wall itself — always black

    static let paper = Theme(ground: Color(hex: 0xF4F1EA),
                             ink: Color(hex: 0x16130F), isNight: false)
    static let night = Theme(ground: Color(hex: 0x141118),
                             ink: Color(hex: 0xEFECE4), isNight: true)

    static func resolve(_ appearance: Appearance, system: ColorScheme) -> Theme {
        switch appearance {
        case .paper: .paper
        case .night: .night
        case .auto: system == .dark ? .night : .paper
        }
    }

    // muted ink steps — the whole grayscale vocabulary of the app
    var ink70: Color { ink.opacity(0.70) }
    var ink55: Color { ink.opacity(0.55) }
    var ink45: Color { ink.opacity(0.45) }
    var ink35: Color { ink.opacity(0.35) }
    var hairline: Color { ink.opacity(0.18) }
    var hairlineSoft: Color { ink.opacity(0.10) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// ---- type ---------------------------------------------------------------
// Archivo/Plex are registered at launch (see AlbumWallApp). If registration
// ever fails, Font.custom silently falls back to the system face — the
// layout survives, only the voice softens.
extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Archivo", size: size).weight(weight)
    }

    /// Archivo's width axis, cranked: expanded + heavy. Page titles only.
    static func displayWide(_ size: CGFloat) -> Font {
        let variations: [Int: Any] = [0x77647468: 125, 0x77676874: 800]
        let desc = UIFontDescriptor(fontAttributes: [
            .name: "Archivo",
            UIFontDescriptor.AttributeName(rawValue:
                kCTFontVariationAttribute as String): variations,
        ])
        return Font(UIFont(descriptor: desc, size: size))
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Mono", size: size).weight(weight)
    }
}

// ---- small shared styles ------------------------------------------------
struct MicroLabel: View {
    @Environment(\.theme) private var t
    let text: String
    var body: some View {
        Text(text)
            .font(.display(11, .bold))
            .kerning(1.5)
            .foregroundStyle(t.ink55)
    }
}

struct MonoTag: View {
    @Environment(\.theme) private var t
    let text: String
    var color: Color?
    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.mono(10))
            .kerning(1)
            .foregroundStyle(color ?? t.ink45)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.paper
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
