import Foundation

@main
struct ColourControlTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            checks.append(["name": name, "passed": passed])
            if !passed { fputs("FAIL: \(name)\n", stderr) }
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.000001 }
        check("six digit hex canonicalizes case", WallColourValue.parse("#E8B04B")?.hex == "#e8b04b")
        check("shorthand expands each channel", WallColourValue.parse("#3bF")?.hex == "#33bbff")
        check("hex accepts surrounding whitespace", WallColourValue.parse(" \n E8b04B ")?.hex == "#e8b04b")
        check("black remains an actual colour", WallColourValue.parse("000000")?.hex == "#000000")
        for invalid in ["", "#", "#1", "#1234", "#12345", "#1234567", "#12345678", "#xyzxyz", "0x1234", "＃ffffff", "##fff", "ff ff ff", "#１２３"] {
            check("invalid hex is rejected: \(invalid)", WallColourValue.parse(invalid) == nil)
        }
        check("finite colour channels are rounded", WallColourValue.byte(0.5) == 128)
        check("negative colour channels clamp", WallColourValue.byte(-1) == 0)
        check("extended colour channels clamp", WallColourValue.byte(3) == 255)
        check("NaN colour channel is safe", WallColourValue.byte(.nan) == 0)
        check("infinite colour channel is safe", WallColourValue.byte(.infinity) == 0)
        check("white swatch receives dark text", WallColourValue.parse("#ffffff")!.usesDarkInk)
        check("black swatch receives light text", !WallColourValue.parse("#000000")!.usesDarkInk)
        check("saturated blue receives readable light text", !WallColourValue.parse("#0000ee")!.usesDarkInk)
        check("amber swatch receives dark text", WallColourValue.parse("#e8b04b")!.usesDarkInk)
        var scale = WallSliderScale(bounds: 0.05...1, step: 0.01)
        check("brightness lower endpoint remains reachable", near(scale.normalized(-10), 0.05))
        check("brightness upper endpoint remains reachable", near(scale.normalized(10), 1))
        check("brightness has one percent detents", near(scale.normalized(0.527), 0.53))
        check("NaN slider value cannot reach native slider", near(scale.normalized(.nan), 0.05))
        check("infinite slider value cannot reach native slider", near(scale.normalized(.infinity), 0.05))
        scale = WallSliderScale(bounds: 0.5...45, step: 0.5)
        check("RPM detents stay anchored to minimum", near(scale.normalized(7.72), 7.5))
        check("RPM upper endpoint clamps", near(scale.normalized(78), 45))
        scale = WallSliderScale(bounds: 0...1, step: 0.3)
        check("non-divisible upper endpoint remains reachable", near(scale.normalized(1), 1))
        scale = WallSliderScale(bounds: 0...1, step: 0)
        check("invalid zero step gets finite fallback", near(scale.step, 0.01))
        scale = WallSliderScale(bounds: 0...1, step: .infinity)
        check("infinite step gets finite fallback", near(scale.step, 0.01))
        scale = WallSliderScale(bounds: 0...1, step: .leastNonzeroMagnitude)
        check("subnormal step cannot overflow tick calculation", scale.step >= 0.000001 && scale.normalized(0.9).isFinite)
        scale = WallSliderScale(bounds: 1...1, step: 1)
        check("zero-width range gets valid fallback", scale.bounds == 0...1)
        scale = WallSliderScale(bounds: 0...Double.infinity, step: 1)
        check("nonfinite range gets valid fallback", scale.bounds == 0...1)
        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let result: [String: Any] = ["suite": "Colour and value controls", "passed": checks.count - failed, "failed": failed, "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        if failed > 0 { exit(1) }
    }
}
