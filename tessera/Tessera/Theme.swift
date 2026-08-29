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
//
// Timing. An impact generator that has not been prepared warms the Taptic
// Engine on first use, which lands the tap a beat after the thing it is
// describing; that was most of the lateness. Every generator is prepared at
// launch, re-prepared immediately after firing so the next one is instant,
// and warmed again when a gesture begins. Detents are also rate limited: a
// drag can cross steps faster than the engine can answer, and a backlog of
// queued taps arrives after the finger has stopped, which reads as drift.
enum Taps {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notice = UINotificationFeedbackGenerator()
    private static var stamps: [String: CFAbsoluteTime] = [:]

    /// One gate per channel. Haptics the engine cannot resolve do not vanish,
    /// they QUEUE, and a queued tap plays late, which is worse than none:
    /// late is what "off time" feels like.
    private static func clear(_ ch: String, _ minGap: CFAbsoluteTime) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = stamps[ch], now - last < minGap { return false }
        stamps[ch] = now
        return true
    }

    /// Call when a gesture begins, so the first detent of it lands on time.
    static func warm() {
        soft.prepare()
        rigid.prepare()
    }

    static func prepareAll() {
        soft.prepare(); rigid.prepare(); heavy.prepare(); notice.prepare()
    }

    /// The press itself. Fired by PressStyle on finger-DOWN, which is where a
    /// physical control clicks; an action-time haptic arrives on finger-UP,
    /// a whole press-length late, and that lateness was most of what felt
    /// wrong. Buttons get this for free and must not also buzz their action.
    static func press() {
        guard clear("press", 0.05) else { return }
        rigid.impactOccurred(intensity: 0.5)
        rigid.prepare()
    }

    /// A detent. Intensity scales with the value so the control gets quieter
    /// as the room gets darker; never a uniform tick.
    static func detent(intensity: Double = 0.5) {
        guard clear("detent", 0.04) else { return }
        soft.impactOccurred(intensity: max(0.15, min(1.0, intensity)))
        soft.prepare()
    }

    /// Something was committed: an address, a send, a gesture's final value.
    static func commit() {
        guard clear("commit", 0.09) else { return }
        rigid.impactOccurred(intensity: 0.7)
        rigid.prepare()
    }

    /// The wall was found: the thud of a lamp switching on.
    static func found() {
        guard clear("found", 0.4) else { return }
        heavy.impactOccurred(intensity: 1.0)
        heavy.prepare()
    }

    /// A frame landed on the wall.
    static func landed() {
        guard clear("landed", 0.25) else { return }
        soft.impactOccurred(intensity: 0.8)
        soft.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            soft.impactOccurred(intensity: 0.6)
            soft.prepare()
        }
    }

    /// One dull buzz, never repeated for the same failure.
    static func error() {
        guard clear("error", 0.8) else { return }
        notice.notificationOccurred(.warning)
        notice.prepare()
    }
}

