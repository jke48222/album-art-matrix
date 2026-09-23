#if DEBUG
import Foundation

/// Layout in native panel coordinates. Every preview and saved/sent frame uses
/// this same buffer, including the selected alignment and individual inks.
struct QALetteringLayout {
    let side: Int
    let lines: [String]
    let scale: Int
    let horizontal: Double
    let vertical: Double
    let fits: Bool
    let requestedScale: Int
    var height: Int { Self.blockHeight(lines, scale: scale) }
    private static func bounds(_ line: String) -> (top: Int, bottom: Int) {
        var top = 0, bottom = PixelFont.height
        for character in line {
            if let glyph = PixelFont.cell(character) {
                top = min(top, glyph.dy); bottom = max(bottom, glyph.dy + glyph.rows.count)
            }
        }
        return (top, bottom)
    }
    private static func blockHeight(_ lines: [String], scale: Int) -> Int {
        lines.reduce(0) { total, line in
            let extent = bounds(line)
            return total + (extent.bottom - extent.top) * scale
        } + max(0, lines.count - 1) * scale
    }
    var width: Int { lines.map { PixelFont.textWidth($0, scale: scale) }.max() ?? 0 }
    var margin: Int { max(1, side / 32) }
    var originY: Int { margin + Int(Double(max(0, side - margin * 2 - height)) * vertical) }

    init(text: String, side: Int, size: Int, horizontal: Double = 0.5, vertical: Double = 0.5) {
        self.side = max(16, min(512, side))
        self.horizontal = horizontal.isFinite ? min(1, max(0, horizontal)) : 0.5
        self.vertical = vertical.isFinite ? min(1, max(0, vertical)) : 0.5
        let inset = max(1, self.side / 32)
        let available = self.side - inset * 2
        let wanted = max(1, min(4, size)) * max(1, self.side / 64)
        requestedScale = wanted
        // Limit pathological pasted input; the editor displays this same limit.
        let normalized = PixelFont.normalize(String(text.prefix(96)))
            .replacingOccurrences(of: "\t", with: " ")
        let paragraphs = normalized.components(separatedBy: .newlines)
        var chosen: [String] = []
        var chosenScale = 1
        var fit = false
        // Respect authored line breaks first. Only wrap when even the smallest
        // scale cannot hold a line; a fitting word never splits needlessly.
        for wraps in [false, true] {
            for candidate in stride(from: wanted, through: 1, by: -1) {
                let rows = paragraphs.flatMap { paragraph -> [String] in
                    !wraps || paragraph.isEmpty ? [paragraph] : PixelFont.wrap(paragraph, maxWidth: available, scale: candidate)
                }
                if Self.blockHeight(rows, scale: candidate) <= available,
                   rows.allSatisfy({ PixelFont.textWidth($0, scale: candidate) <= available }) {
                    chosen = rows; chosenScale = candidate; fit = true; break
                }
            }
            if fit { break }
        }
        // An overlong composition never silently clips: preserve the artwork
        // underneath and ask the editor to shorten its words before sending.
        lines = normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : chosen
        scale = chosenScale
        fits = fit
    }

    func render(over base: [UInt8], rgb: (UInt8, UInt8, UInt8),
                colors: [(UInt8, UInt8, UInt8)] = []) -> [UInt8] {
        var output = base.count == side * side * 3 ? base : [UInt8](repeating: 0, count: side * side * 3)
        guard fits else { return output }
        var y = originY, glyphIndex = 0
        for line in lines {
            let extent = Self.bounds(line)
            let baseline = y - extent.top * scale
            let lineWidth = PixelFont.textWidth(line, scale: scale)
            var x = margin + Int(Double(max(0, side - margin * 2 - lineWidth)) * horizontal)
            for ch in line {
                let (rows, width, advance, dy) = PixelFont.cell(ch) ?? (PixelFont.box, 5, 6, 0)
                let color = !ch.isWhitespace && glyphIndex < colors.count ? colors[glyphIndex] : rgb
                if !ch.isWhitespace { glyphIndex += 1 }
                for (row, mask) in rows.enumerated() {
                    for column in 0..<width where mask & (1 << (width - 1 - column)) != 0 {
                        for sy in 0..<scale { for sx in 0..<scale {
                            let px = x + column * scale + sx, py = baseline + (row + dy) * scale + sy
                            guard px >= 0, py >= 0, px < side, py < side else { continue }
                            let offset = (py * side + px) * 3
                            output[offset] = color.0; output[offset + 1] = color.1; output[offset + 2] = color.2
                        } }
                    }
                }
                x += advance * scale
            }
            y += (extent.bottom - extent.top + 1) * scale
        }
        return output
    }
}

#endif
