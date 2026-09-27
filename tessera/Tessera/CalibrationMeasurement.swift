import Foundation

/// The wall applies correction in linear light. Camera samples arrive as sRGB,
/// so decode each pixel before averaging; a ratio of encoded bytes is not light.
enum CalibrationMeasurement {
    struct Gains: Equatable {
        var r: Double
        var g: Double
        var b: Double
        static let neutral = Gains(r: 1, g: 1, b: 1)
        var values: [Double] { [r, g, b] }
        var patch: [String: Any] { ["wb_r": r, "wb_g": g, "wb_b": b] }
        var valid: Bool { values.allSatisfy { $0.isFinite && (0.3...1).contains($0) } }
        /// The wall stores gains up to 3.0 but, once one passes 1.0, shows
        /// only their ratio. Previews and measurements take 0.3 to 1.0, so
        /// bring saved gains into that range without changing what the LEDs
        /// show, except where a ratio is steeper than the 0.3 floor allows.
        static func saved(r: Double, g: Double, b: Double) -> Gains {
            let peak = max(1, r, g, b)
            return Gains(r: max(0.3, r / peak), g: max(0.3, g / peak), b: max(0.3, b / peak))
        }
    }
    struct Reading {
        let gains: Gains
        let linearRGB: [Double]
        let clippedFraction: Double
        let sampleCount: Int
        var maximumReduction: Double { 1 - (gains.values.min() ?? 1) }
    }
    enum Failure: Error, LocalizedError, Equatable {
        case malformed, dark, clipped, extreme, uneven
        var errorDescription: String? {
            switch self {
            case .malformed: "This photograph could not be measured. Take a new photo of the whole panel."
            case .dark: "The sample is too dark. Fill the frame with the lit panel and keep room lights off its surface."
            case .clipped: "The photograph is overexposed, and clipped light cannot be measured. Lower the camera exposure and take another shot."
            case .extreme: "This reading would need too much correction. Check the crop and room reflections, or reset the correction before starting again."
            case .uneven: "The sample is uneven. Aim squarely at the panel and keep its edges, reflections and the room outside the measuring area."
            }
        }
    }
    static func linear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
    /// RGB buffer, square and at least 16px wide. Sample the middle five eighths
    /// to exclude the panel's physical bezel and the crop's antialiased edges.
    static func solve(_ pixels: [UInt8], prior: Gains) throws -> Reading {
        guard pixels.count % 3 == 0, prior.valid else { throw Failure.malformed }
        let side = Int(Double(pixels.count / 3).squareRoot())
        guard (16...1024).contains(side), side * side * 3 == pixels.count else { throw Failure.malformed }
        let edge = side * 3 / 16, far = side - edge
        var sums = [Double](repeating: 0, count: 3)
        var clipped = 0, count = 0
        var quadrants = [Double](repeating: 0, count: 4)
        var quadrantCounts = [Int](repeating: 0, count: 4)
        for y in edge..<far {
            for x in edge..<far {
                let offset = (y * side + x) * 3
                let values = (0..<3).map { Double(pixels[offset + $0]) / 255 }
                let decoded = values.map(linear)
                for channel in 0..<3 { sums[channel] += decoded[channel] }
                if values.contains(where: { $0 >= 248.0 / 255 }) { clipped += 1 }
                let quadrant = (y >= side / 2 ? 2 : 0) + (x >= side / 2 ? 1 : 0)
                quadrants[quadrant] += decoded.reduce(0, +) / 3
                quadrantCounts[quadrant] += 1
                count += 1
            }
        }
        guard count > 0 else { throw Failure.malformed }
        let fraction = Double(clipped) / Double(count)
        guard fraction < 0.02 else { throw Failure.clipped }
        let means = sums.map { $0 / Double(count) }
        guard let weakest = means.min(), weakest > 0.008 else { throw Failure.dark }
        let regions = zip(quadrants, quadrantCounts).map { $0.0 / Double(max(1, $0.1)) }
        guard let bright = regions.max(), let dim = regions.min(), dim / bright > 0.45 else { throw Failure.uneven }
        // Brightness is its own setting, so the brightest channel stays at
        // full output. Keeping the weakest reading's gain instead let every
        // repeat dim the whole wall a little more. Judge the range afterwards.
        let corrected = zip(prior.values, means).map { $0.0 * weakest / $0.1 }
        guard let peak = corrected.max(), peak > 0 else { throw Failure.malformed }
        let result = Gains(r: corrected[0] / peak, g: corrected[1] / peak, b: corrected[2] / peak)
        guard result.valid else { throw Failure.extreme }
        return Reading(gains: result, linearRGB: means, clippedFraction: fraction, sampleCount: count)
    }
}
