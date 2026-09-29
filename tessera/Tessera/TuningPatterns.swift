import Foundation

/// What Panel tuning can put on the wall to judge a setting against. A sleeve
/// is a poor ruler for a grey or a primary, so each pattern isolates one
/// thing the knobs change.
///
/// Every pattern is drawn as a 64 x 64 composition and scaled up by whole
/// pixels (u = x * 64 / side), the same rule PanelDiagnostic uses, so the
/// phone's swatch, the preview and the wall at 64 or 192 show one picture.
/// Full 255 levels are used on purpose. PanelDiagnostic's 191 exists so a
/// panel check matches the colour measurement, which does not apply here.
enum TuningPattern: String, CaseIterable, Identifiable {
    case wall, greys, darkSteps, darkColours, bars, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wall: "Your wall"
        case .greys: "Greys"
        case .darkSteps: "Dark steps"
        case .darkColours: "Dark colours"
        case .bars: "Colour bars"
        case .grid: "Grid"
        }
    }

    /// What to look for while the pattern is up.
    var detail: String {
        switch self {
        case .wall: "What the wall is showing now. Use it for sharpness, shadow lift, video and the owned record mark."
        case .greys: "Four grey bands and a black strip. Look for even greys with no colour tint."
        case .darkSteps: "Eight grey steps from very dim to dim. Each should be a little brighter than the last, with no colour of its own."
        case .darkColours: "Brown, skin, navy and green, all dim. Each should keep its colour instead of breaking into single red, green or blue lights."
        case .bars: "Red, green, blue, yellow, cyan, magenta, white and grey. Use these to judge the gains."
        // The grid is PanelDiagnostic's, so its lines are at three quarters
        // brightness while every other pattern here uses full levels.
        case .grid: "Straight lines across the panel, at three quarters brightness. Look for broken, doubled or ghosted rows."
        }
    }

    /// The dimmest grey steps the panel has the fewest planes for.
    static let darkLevels: [UInt8] = [8, 16, 24, 32, 40, 48, 56, 64]
    static let greyLevels: [UInt8] = [255, 191, 128, 64]
    /// Brown, skin, navy and green, each dim enough to fall apart into a
    /// single primary when the dark end is wrong.
    static let darkColourBands: [(UInt8, UInt8, UInt8)] = [(60, 40, 28), (96, 68, 56), (24, 32, 72), (28, 56, 36)]
    /// Primaries, secondaries, white and a mid grey.
    static let barColours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
                                                      (0, 255, 255), (255, 0, 255), (255, 255, 255), (128, 128, 128)]

    /// RGB888 at side x side. Empty for Your wall, which is the wall's own
    /// picture, and for a side no wall can be.
    func pixels(side: Int) -> [UInt8] {
        guard self != .wall, side > 0, side <= 1024 else { return [] }
        if self == .grid { return PanelDiagnostic.grid.pixels(side: side) }
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            let v = y * 64 / side
            for x in 0..<side {
                let u = x * 64 / side
                let rgb = colour(u: u, v: v)
                let index = (y * side + x) * 3
                out[index] = rgb.0; out[index + 1] = rgb.1; out[index + 2] = rgb.2
            }
        }
        return out
    }

    /// One cell of the 64 x 64 composition.
    private func colour(u: Int, v: Int) -> (UInt8, UInt8, UInt8) {
        switch self {
        case .greys:
            // The last eight rows stay black, so the dark end has a true
            // off to be compared with.
            guard v < 56 else { return (0, 0, 0) }
            let level = Self.greyLevels[min(3, v / 14)]
            return (level, level, level)
        case .darkSteps:
            let level = Self.darkLevels[min(7, u / 8)]
            return (level, level, level)
        case .darkColours:
            return Self.darkColourBands[min(3, v / 16)]
        case .bars:
            return Self.barColours[min(7, v / 8)]
        case .wall, .grid:
            return (0, 0, 0)
        }
    }
}
