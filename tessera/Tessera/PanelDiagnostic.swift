import Foundation

enum PanelDiagnostic: String, CaseIterable, Identifiable {
    case white, red, green, blue, black, grid, ramp
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The solid fills and grid lines run at three quarters of full output,
    /// the same 191 grey the colour measurement uses. The detail says so, so
    /// a grey "White" and a brighter last ramp step do not read as faults.
    static let level: UInt8 = 191
    var detail: String {
        switch self {
        case .white: "Shown at three quarters brightness. Look for uneven light, tint, or a dark emitter."
        case .red, .green, .blue: "Shown at three quarters brightness. Look for dark or unusually bright points in this colour channel."
        case .black: "Look for emitters that stay lit when their output should be off."
        case .grid: "Follow the lines. They should stay straight and unbroken, including across any tile joins."
        case .ramp: "Eight steps from off to full brightness. Look for even steps without sudden colour shifts."
        }
    }
    func pixels(side: Int) -> [UInt8] {
        guard side > 0, side <= 1024 else { return [] }
        let on = Self.level
        var pixels = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let u = x * 64 / side, v = y * 64 / side
                let rgb: (UInt8, UInt8, UInt8)
                switch self {
                case .white: rgb = (on, on, on)
                case .red: rgb = (on, 0, 0)
                case .green: rgb = (0, on, 0)
                case .blue: rgb = (0, 0, on)
                case .black: rgb = (0, 0, 0)
                case .grid:
                    // Lines every 9 pixels land on 0, 9, ... 63: a closed
                    // border and seven equal cells, so no short last cell
                    // looks like a panel fault.
                    let level: UInt8 = (u % 9 == 0 || v % 9 == 0) ? on : 0
                    rgb = (level, level, level)
                case .ramp:
                    let level = UInt8((u / 8) * 255 / 7)
                    rgb = (level, level, level)
                }
                let index = (y * side + x) * 3
                pixels[index] = rgb.0; pixels[index + 1] = rgb.1; pixels[index + 2] = rgb.2
            }
        }
        return pixels
    }
}
