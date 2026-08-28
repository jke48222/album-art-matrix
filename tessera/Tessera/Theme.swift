// Tessera design tokens. The spec is the authority; this file is its Swift twin.
//
// A dark room, one lit tile. The base palette is fixed and warm-dark; the live
// accent is computed per frame from whatever the wall is showing (Ink.artTint).
// Technor speaks for the art, Switzer for the interface, Martian Mono for
// anything measured. Signal red is for warnings and destructive only.

import SwiftUI
import UIKit
import CoreText

// MARK: - Palette

enum Ink {
    static let ground   = Color(hex: 0x0B0A09)
    static let plaster  = Color(hex: 0x141210)
    static let sunk     = Color(hex: 0x0E0D0B)
    static let ink      = Color(hex: 0xEAE4D8)
    static let dim      = Color(hex: 0x96907F)
    static let faint    = Color(hex: 0x5E594E)
    static let hairline = Color(hex: 0xEAE4D8).opacity(0.13)
    static let tile     = Color(hex: 0xE8B04B)   // a lit tessera; pending states
    static let signal   = Color(hex: 0xE0491F)   // warnings and destructive only
    static let moss     = Color(hex: 0x7FA87A)   // confirmed on the wall
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// "#rrggbb" from the brain's art_colors; nil when malformed.
    init?(wallHex: String) {
        var s = wallHex
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

// MARK: - Type

// Faces ship in Fonts/ and are registered at launch. Every size goes through
// the caller's @ScaledMetric so custom faces track Dynamic Type.
enum Face {
    static let display       = "Technor-Bold"
    static let displayMid    = "Technor-Semibold"
    static let displayBook   = "Technor-Medium"
    static let ui            = "Switzer-Regular"
    static let uiMedium      = "Switzer-Medium"
    static let uiSemibold    = "Switzer-Semibold"
    static let mono          = "MartianMono-Regular"
    static let monoMedium    = "MartianMono-Medium"

    /// Register every bundled font once; fall back silently to system faces
    /// (the helpers below never crash on a missing name).
    static func registerAll() {
        for ext in ["otf", "ttf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        #if DEBUG
        for fam in ["Technor", "Switzer", "Martian Mono"] {
            print("[fonts] \(fam):", UIFont.fontNames(forFamilyName: fam))
        }
        #endif
    }
}

extension Font {
    /// Track titles, big states, the wordmark.
    static func display(_ size: CGFloat) -> Font { .custom(Face.display, size: size) }
    static func displayMid(_ size: CGFloat) -> Font { .custom(Face.displayMid, size: size) }
    /// Interface text.
    static func ui(_ size: CGFloat, _ weight: UIWeight = .regular) -> Font {
        .custom(weight.face, size: size)
    }
    /// Machine values. Martian is wide by nature: no added tracking.
    static func machine(_ size: CGFloat, medium: Bool = true) -> Font {
        .custom(medium ? Face.monoMedium : Face.mono, size: size)
    }

    enum UIWeight { case regular, medium, semibold
        var face: String {
            switch self {
            case .regular: Face.ui
            case .medium: Face.uiMedium
            case .semibold: Face.uiSemibold
            }
        }
    }
}

/// Mono microlabel: caps, gentle tracking (Martian needs little).
struct Microlabel: ViewModifier {
    var color: Color = Ink.dim
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        content
            .font(.machine(10))
            .textCase(.uppercase)
            .kerning(typeSize.isAccessibilitySize ? 0 : 0.8)
            .foregroundStyle(color)
    }
}

extension View {
    func microlabel(_ color: Color = Ink.dim) -> some View { modifier(Microlabel(color: color)) }
}

extension Color {
    /// Everything on screen is lit by the wall, type included.
    func lit(by accent: Color, _ amount: Double) -> Color {
        mix(with: accent, by: max(0, min(1, amount)))
    }
}

// MARK: - Motion

// One family of springs; Reduce Motion swaps every move for a dissolve.
enum Motion {
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    static var blink: Animation { reduced ? .easeOut(duration: 0.09) : .easeOut(duration: 0.12) }
    static var settle: Animation { reduced ? .easeInOut(duration: 0.20) : .spring(response: 0.42, dampingFraction: 0.85) }
    static var scene: Animation { reduced ? .easeInOut(duration: 0.24) : .spring(response: 0.48, dampingFraction: 0.86) }
}

// MARK: - Haptics

// Amplify real events only. Nothing here fires during idle animation or polls.
enum Taps {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)

    /// A detent. Intensity scales with the value so the control gets quieter
    /// as the room gets darker; never a uniform tick.
    static func detent(intensity: Double = 0.5) {
        soft.impactOccurred(intensity: max(0.15, min(1.0, intensity)))
    }
    /// Mode committed locally; the wall's confirmation is separate.
    static func commit() { rigid.impactOccurred(intensity: 0.7) }
    /// The wall was found: the thud of a lamp switching on.
    static func found() { heavy.impactOccurred(intensity: 1.0) }
    /// A frame landed on the wall.
    static func landed() {
        soft.impactOccurred(intensity: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            soft.impactOccurred(intensity: 0.6)
        }
    }
    /// One dull buzz, never repeated for the same failure.
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
