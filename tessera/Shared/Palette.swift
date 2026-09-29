// The base palette, shared by the app, the widget and the share extension.
//
// Moved out of Theme.swift so the widget draws in the app's warm dark rather
// than in .black and .white: a widget of the wall should sit in the same room
// the app does. Type, motion and haptics stay in Theme.swift, which only the
// app compiles.

import SwiftUI

enum Ink {
    static let ground   = Color(hex: 0x0B0A09)
    static let plaster  = Color(hex: 0x141210)
    static let sunk     = Color(hex: 0x0E0D0B)
    static let ink      = Color(hex: 0xEAE4D8)
    static let dim      = Color(hex: 0x96907F)
    // Was 0x5E594E, which measured 2.84:1 on ground: under the 3:1 floor for
    // large text, let alone the 4.5:1 body text needs, and it carries words at
    // forty-odd places, most of them 9 to 12pt. Lifted along its own hue until
    // it clears 4.5:1 on all three grounds (4.77 / 4.51 / 4.68). Still the
    // quietest voice: well below dim, which is 6.2:1.
    static let faint    = Color(hex: 0x837C6C)
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
