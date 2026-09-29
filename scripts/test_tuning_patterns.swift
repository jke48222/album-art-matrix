import Foundation

// Compiled with tessera/Tessera/TuningPatterns.swift and PanelDiagnostic.swift
// by scripts/test_tuning_patterns.py. The wall shows exactly what the phone
// previews, so the generator is checked at both of the wall's sizes.
@main struct TuningPatternChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
        func rgb(_ px: [UInt8], side: Int, x: Int, y: Int) -> [UInt8] {
            let i = (y * side + x) * 3
            return [px[i], px[i + 1], px[i + 2]]
        }

        let drawn = TuningPattern.allCases.filter { $0 != .wall }
        for side in [64, 192] {
            for pattern in drawn {
                check("\(pattern.rawValue) is \(side) x \(side) RGB", pattern.pixels(side: side).count == side * side * 3)
            }
        }
        check("Your wall has no pixels of its own", TuningPattern.wall.pixels(side: 64).isEmpty && TuningPattern.wall.pixels(side: 192).isEmpty)
        check("No side is refused silently as a huge frame", TuningPattern.greys.pixels(side: 2048).isEmpty && TuningPattern.greys.pixels(side: 0).isEmpty)

        // Dark steps: eight full-height columns, exactly 8 to 64.
        let steps = TuningPattern.darkSteps.pixels(side: 64)
        let columns = (0..<8).map { rgb(steps, side: 64, x: $0 * 8 + 3, y: 20)[0] }
        check("Dark steps columns are 8, 16, 24, 32, 40, 48, 56, 64", columns == [8, 16, 24, 32, 40, 48, 56, 64])
        check("Dark steps run the full height", (0..<64).allSatisfy { rgb(steps, side: 64, x: 60, y: $0) == [64, 64, 64] })
        check("Dark steps are neutral", stride(from: 0, to: steps.count, by: 3).allSatisfy { steps[$0] == steps[$0 + 1] && steps[$0] == steps[$0 + 2] })

        // Greys: four neutral bands, then black.
        let greys = TuningPattern.greys.pixels(side: 64)
        check("Every grey band is neutral", stride(from: 0, to: greys.count, by: 3).allSatisfy { greys[$0] == greys[$0 + 1] && greys[$0] == greys[$0 + 2] })
        check("Grey bands are 255, 191, 128 and 64", [0, 14, 28, 42].map { rgb(greys, side: 64, x: 10, y: $0)[0] } == [255, 191, 128, 64])
        check("The last eight rows are black", (56..<64).allSatisfy { rgb(greys, side: 64, x: 30, y: $0) == [0, 0, 0] })

        // Dark colours and bars keep their authored values.
        let colours = TuningPattern.darkColours.pixels(side: 64)
        check("Dark colours are brown, skin, navy and green", [0, 16, 32, 48].map { rgb(colours, side: 64, x: 5, y: $0) } == [[60, 40, 28], [96, 68, 56], [24, 32, 72], [28, 56, 36]])
        let bars = TuningPattern.bars.pixels(side: 64)
        check("Colour bars run red to grey", (0..<8).map { rgb(bars, side: 64, x: 40, y: $0 * 8) } ==
              [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [0, 255, 255], [255, 0, 255], [255, 255, 255], [128, 128, 128]])

        // The grid is the panel check's grid, not a second copy of it.
        for side in [64, 192] {
            check("Grid equals PanelDiagnostic.grid at \(side)", TuningPattern.grid.pixels(side: side) == PanelDiagnostic.grid.pixels(side: side))
        }

        // 192 is the 64 composition scaled up 3 x 3, value for value.
        for pattern in drawn {
            let small = pattern.pixels(side: 64), large = pattern.pixels(side: 192)
            var same = true
            outer: for y in 0..<192 {
                for x in 0..<192 where rgb(large, side: 192, x: x, y: y) != rgb(small, side: 64, x: x / 3, y: y / 3) {
                    same = false; break outer
                }
            }
            check("\(pattern.rawValue) at 192 is the 64 composition scaled 3 x 3", same)
        }

        // Every title and detail follows the copy rules.
        let banned: [Character] = [";", "\u{2014}", "\u{2013}", "\u{00B7}", "\u{00D7}"]
        check("Pattern copy has no banned punctuation", TuningPattern.allCases.allSatisfy { p in !(p.title + p.detail).contains { banned.contains($0) } })
        check("Pattern ids round-trip", TuningPattern.allCases.allSatisfy { TuningPattern(rawValue: $0.rawValue) == $0 })

        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
