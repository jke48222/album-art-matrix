// The spatial half of the design system, beside Theme.swift's colour and type.
//
// In Shared/ rather than in the app, because the widgets and the share sheet
// draw the same kind of surfaces and were carrying their own loose numbers.

import CoreGraphics

// MARK: - Space

// The other half of the system. Colour, type, motion and haptics were all
// tokenised from the start; space was not, and it showed: nineteen different
// stack spacings, thirty-three paddings, every integer from 0 to 16, and
// twelve corner radii with 10, 12, 14, 16 and 18 all in use at once. None of
// those differences is perceptible on their own, and together they are what
// stops a screen feeling built rather than assembled.
//
// A four-point scale, because the tightest real gap in this app (a label over
// its value) is 4 and the widest (a section against the next) is 32.
enum Space {
    static let hair: CGFloat = 2     // touching things that must not quite touch
    static let tight: CGFloat = 4    // a label and its value
    static let snug: CGFloat = 8     // lines inside one thought
    static let step: CGFloat = 12    // rows in a group
    static let gap: CGFloat = 16     // a group's inner padding
    static let wide: CGFloat = 24    // the screen gutter
    static let room: CGFloat = 32    // one section against the next
}

// Five radii, each with a job, instead of twelve with none. Every existing
// value lands on one of these within two points, so nothing moved visibly.
// Radii of 0, 1 and 2 are left alone: those are pixel-art details (an LED, a
// progress bar, the wall's own tiles), not interface corners.
enum Round {
    static let chip: CGFloat = 6     // a swatch, a key, a small tag
    static let control: CGFloat = 10 // a field, a stepper, a segmented control
    static let card: CGFloat = 14    // a row group, a panel
    static let sheet: CGFloat = 18   // a sheet, a large card
    static let hero: CGFloat = 22    // the biggest surfaces
    /// Pills and circles keep using Capsule()/Circle(); they have no radius.
}
