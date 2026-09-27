import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String = "Calibration check failed") {
    checks += 1
    precondition(condition, message)
}

func field(_ r: UInt8, _ g: UInt8, _ b: UInt8, side: Int = 64) -> [UInt8] {
    Array(repeating: [r, g, b], count: side * side).flatMap { $0 }
}
func expectFailure(_ expected: CalibrationMeasurement.Failure, _ pixels: [UInt8], prior: CalibrationMeasurement.Gains = .neutral) {
    do { _ = try CalibrationMeasurement.solve(pixels, prior: prior); fatalError("Expected \(expected)") }
    catch let error as CalibrationMeasurement.Failure { check(error == expected, "\(error) != \(expected)") }
    catch { fatalError("Unexpected error \(error)") }
}
let neutral = try CalibrationMeasurement.solve(field(191, 191, 191), prior: .neutral)
check(neutral.gains == .neutral)
let prior = CalibrationMeasurement.Gains(r: 0.9, g: 0.8, b: 0.7)
let repeatNeutral = try CalibrationMeasurement.solve(field(191, 191, 191), prior: prior)
check(repeatNeutral.gains.r == 1 && abs(repeatNeutral.gains.g - 0.8 / 0.9) < 0.0000001 && abs(repeatNeutral.gains.b - 0.7 / 0.9) < 0.0000001,
      "A neutral repeat keeps the prior's ratio with the brightest channel at 1.00")
let tinted = try CalibrationMeasurement.solve(field(160, 190, 180), prior: .neutral)
let expectedGreen = CalibrationMeasurement.linear(160.0 / 255) / CalibrationMeasurement.linear(190.0 / 255)
check(abs(tinted.gains.g - expectedGreen) < 0.0000001)
check(tinted.gains.r == 1 && tinted.gains.g < 160.0 / 190, "Must decode before ratios")
let repeated = try CalibrationMeasurement.solve(field(160, 190, 180), prior: prior)
check(repeated.gains.values.max() == 1, "The brightest channel stays at 1.00")
check(abs(repeated.gains.g / repeated.gains.r - (prior.g * tinted.gains.g) / (prior.r * tinted.gains.r)) < 0.0000001, "A repeat builds on the prior's ratio")
// A slightly over-corrected reading must not ratchet the wall dimmer.
var ratchet = CalibrationMeasurement.Gains(r: 1, g: 0.85, b: 0.8)
for _ in 0..<5 { ratchet = try CalibrationMeasurement.solve(field(180, 185, 170), prior: ratchet).gains }
check(ratchet.values.max() == 1, "Repeated readings keep full output")
// The range is judged after scaling, so a dim prior with a valid ratio passes.
let dimPrior = try CalibrationMeasurement.solve(field(160, 190, 180), prior: .init(r: 0.35, g: 0.35, b: 0.35))
check(zip(dimPrior.gains.values, tinted.gains.values).allSatisfy { abs($0 - $1) < 0.0000001 })
expectFailure(.malformed, [])
expectFailure(.malformed, [UInt8](repeating: 191, count: 100))
expectFailure(.malformed, field(191, 191, 191), prior: .init(r: .nan, g: 1, b: 1))
expectFailure(.dark, field(5, 10, 15))
expectFailure(.clipped, field(249, 190, 180))
var localClipping = field(160, 190, 180)
for y in 16..<26 { for x in 16..<26 { localClipping[(y * 64 + x) * 3] = 255 } }
expectFailure(.clipped, localClipping)
expectFailure(.extreme, field(80, 220, 180))
var uneven = field(180, 180, 180)
for y in 12..<32 { for x in 12..<32 { for c in 0..<3 { uneven[(y * 64 + x) * 3 + c] = 60 } } }
expectFailure(.uneven, uneven)
check(abs(CalibrationMeasurement.linear(0.04045) - 0.00313080495) < 0.000000001)
expectFailure(.malformed, field(191, 191, 191), prior: .init(r: 0, g: 1, b: 1))
expectFailure(.malformed, field(191, 191, 191), prior: .init(r: 1, g: 1.01, b: 1))
expectFailure(.malformed, field(191, 191, 191), prior: .init(r: 1, g: 1, b: .infinity))
for size in [16, 192, 512] {
    check(try CalibrationMeasurement.solve(field(191, 191, 191, side: size), prior: .neutral).gains == .neutral)
}
var bezel = field(255, 255, 255)
for y in 12..<52 { for x in 12..<52 { for c in 0..<3 { bezel[(y * 64 + x) * 3 + c] = 191 } } }
check(try CalibrationMeasurement.solve(bezel, prior: .neutral).gains == .neutral, "Exclude the crop bezel")
check(try CalibrationMeasurement.solve(field(191, 191, 191), prior: .init(r: 0.3, g: 0.3, b: 0.3)).gains == .neutral)
// Saved gains above 1.0 show only their ratio on the wall.
let above = CalibrationMeasurement.Gains.saved(r: 1.44, g: 1.58, b: 1.61)
check(above.valid && above.b == 1 && abs(above.r - 1.44 / 1.61) < 0.0000001 && abs(above.g - 1.58 / 1.61) < 0.0000001)
check(try CalibrationMeasurement.solve(field(191, 191, 191), prior: above).gains == above, "Saved gains above 1.0 can be measured")
check(CalibrationMeasurement.Gains.saved(r: 0.9, g: 0.8, b: 0.7) == prior, "Gains at or below 1.0 stay as they are")
check(CalibrationMeasurement.Gains.saved(r: 3, g: 0.3, b: 0.3) == .init(r: 1, g: 0.3, b: 0.3), "The preview floor holds")
print("Calibration arithmetic: \(checks) checks passed")
