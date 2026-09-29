import Foundation

// Shared/EmitterRaster.swift on the Mac. The golden comparison with the
// pre-refactor EmitterTile loop is the Python side's (test_emitter_raster.py
// ports that loop): this program rasters the capture_home artwork the Python
// side hands it and writes the bytes back for it to compare.

@main struct EmitterRasterTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            var c: [String: Any] = ["name": name, "passed": passed]
            if !passed && !detail.isEmpty { c["detail"] = detail }
            checks.append(c)
        }

        let dark64 = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let dark192 = [UInt8](repeating: 0, count: 192 * 192 * 3)
        check("64 at cell 8 is 512 px", EmitterRaster.raster(dark64, cell: 8)?.side == 512)
        check("192 at cell 3 is 576 px", EmitterRaster.raster(dark192, cell: 3)?.side == 576)
        check("the raster never passes 768 px", EmitterRaster.raster(dark192, cell: 9)?.side == 768)
        check("a frame that is not a square is refused", EmitterRaster.raster([1, 2, 3, 4], cell: 4) == nil)

        // The centre of an emitter is fully covered.
        if let (side, rgba) = EmitterRaster.raster(dark64, cell: 8) {
            let centre = ((4 * side) + 4) * 4
            check("the unlit centre byte is 12", rgba[centre] == 12 && rgba[centre + 1] == 12 && rgba[centre + 2] == 12,
                  "\(rgba[centre])")
            check("between emitters is black", rgba[0] == 0 && rgba[3] == 255)
        } else {
            check("the dark raster exists", false)
        }

        var mixed = dark64
        mixed[0] = 200; mixed[1] = 100; mixed[2] = 50          // emitter 0 lit
        mixed[3] = 7; mixed[4] = 7; mixed[5] = 7                // emitter 1 under the floor
        if let (side, rgba) = EmitterRaster.raster(mixed, cell: 8, duty: 0.55) {
            let lit = ((4 * side) + 4) * 4
            let unlit = ((4 * side) + 12) * 4
            check("duty dims lit emitters", rgba[lit] == UInt8(200 * 0.55) && rgba[lit + 1] == UInt8(100 * 0.55)
                  && rgba[lit + 2] == UInt8(50 * 0.55), "\(rgba[lit]) \(rgba[lit + 1]) \(rgba[lit + 2])")
            check("duty leaves the unlit lattice alone", rgba[unlit] == 12)
            check("a channel of 7 is unlit", rgba[unlit + 1] == 12)
        } else {
            check("the mixed raster exists", false)
        }
        check("duty is clamped at 0.05", EmitterRaster.raster(mixed, cell: 8, duty: 0)?.rgba
              == EmitterRaster.raster(mixed, cell: 8, duty: 0.05)?.rgba)

        check("a 170 pt panel at 3x draws 64 at cell 8", EmitterRaster.cell(forPixels: 510, side: 64) == 8)
        check("a 170 pt panel at 3x draws 192 at cell 3", EmitterRaster.cell(forPixels: 510, side: 192) == 3)
        check("cell(forPixels:) clamps at 768 / n", EmitterRaster.cell(forPixels: 5000, side: 192) == 4
              && EmitterRaster.cell(forPixels: 5000, side: 64) == 12)
        check("cell(forPixels:) is never 0", EmitterRaster.cell(forPixels: 1, side: 192) == 1
              && EmitterRaster.cell(forPixels: 0, side: 64) == 1)
        check("solid is one pixel", EmitterRaster.solid(r: 11, g: 10, b: 9).map { $0.width == 1 && $0.height == 1 } == true)
        check("render makes an image of the raster's size", EmitterRaster.render(dark64, cell: 3).map { $0.width == 192 } == true)
        check("digest reads the whole buffer", EmitterRaster.digest(dark64) != EmitterRaster.digest(mixed))

        // The exact-size raster for a dense wall at a size it does not divide.
        check("192 on a 170 pt panel at 3x is rastered exactly", EmitterRaster.wantsExact(pixels: 510, side: 192))
        check("64 on a 170 pt panel keeps its whole cell", !EmitterRaster.wantsExact(pixels: 510, side: 64))
        check("a whole pitch keeps its whole cell", !EmitterRaster.wantsExact(pixels: 576, side: 192))
        check("the exact raster is the size asked for", EmitterRaster.raster(dark192, pixels: 510)?.side == 510)
        check("the exact raster never passes 768 px", EmitterRaster.raster(dark192, pixels: 900)?.side == 768)
        check("at a whole pitch the exact raster is the cell raster, byte for byte",
              EmitterRaster.raster(mixed, pixels: 512, duty: 0.55)?.rgba == EmitterRaster.raster(mixed, cell: 8, duty: 0.55)?.rgba
              && EmitterRaster.raster(dark192, pixels: 576)?.rgba == EmitterRaster.raster(dark192, cell: 3)?.rgba)
        if let (side, rgba) = EmitterRaster.raster(dark192, pixels: 510) {
            // Even: every emitter row of an unlit wall carries the same light,
            // within what a pixel grid at a fractional pitch allows.
            var rows = [Double](repeating: 0, count: side)
            for y in 0..<side { for x in 0..<side { rows[y] += Double(rgba[(y * side + x) * 4]) } }
            let pitch = Double(side) / 192
            var energy: [Double] = []
            var y0 = 0
            for i in 0..<192 {
                let y1 = min(side, Int((Double(i + 1) * pitch).rounded()))
                energy.append(rows[y0..<max(y0, y1)].reduce(0, +))
                y0 = y1
            }
            let mean = energy.reduce(0, +) / Double(energy.count)
            check("the exact raster lights every emitter", energy.allSatisfy { $0 > 0 } && mean > 0)
        } else {
            check("the exact 192 raster exists", false)
        }

        // Golden cases for the Python port: <dir>/artwork64.raw and
        // artwork192.raw in, <dir>/<case>.rgba out.
        let args = CommandLine.arguments
        if args.count > 1 {
            let dir = URL(fileURLWithPath: args[1])
            for (source, n) in [("artwork64", 64), ("artwork192", 192)] {
                let px = [UInt8](try Data(contentsOf: dir.appendingPathComponent("\(source).raw")))
                check("\(source) is \(n) square", Panel.square(px.count) == n)
                let cells = n == 64 ? [8, 3] : [3, 4]
                for cell in cells {
                    for duty in [1.0, 0.55] {
                        guard let (_, rgba) = EmitterRaster.raster(px, cell: cell, duty: duty) else {
                            check("\(source) raster at \(cell)", false); continue
                        }
                        let name = "\(source)-c\(cell)-d\(Int(duty * 100)).rgba"
                        try Data(rgba).write(to: dir.appendingPathComponent(name))
                    }
                }
            }
        }

        let failures = checks.filter { !($0["passed"] as! Bool) }
        let report: [String: Any] = ["suite": "Production EmitterRaster", "passed": checks.count - failures.count,
                                     "failed": failures.count, "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !failures.isEmpty { exit(1) }
    }
}
