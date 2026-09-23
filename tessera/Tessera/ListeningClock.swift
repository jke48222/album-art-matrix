import Foundation

/// Counts only continuous playback actually observed by this open app.
/// Seeks, clock changes, disconnected gaps and background time earn no time.
struct ListeningClock {
    struct Sample {
        let track: String
        let position: Double
        let uptime: Double
        let playing: Bool
    }
    private var previous: Sample?

    mutating func observe(track: String, position: Double?, playing: Bool, uptime: Double) -> Double {
        guard !track.isEmpty, let position, position.isFinite, position >= 0, uptime.isFinite else {
            previous = nil; return 0
        }
        let sample = Sample(track: track, position: position, uptime: uptime, playing: playing)
        defer { previous = sample }
        guard playing, let previous, previous.playing, previous.track == track else { return 0 }
        let elapsed = uptime - previous.uptime
        let advanced = position - previous.position
        guard elapsed > 0, elapsed <= 5, advanced > 0,
              abs(advanced - elapsed) <= max(0.35, elapsed * 0.35) else { return 0 }
        return min(elapsed, advanced)
    }

    mutating func suspend() { previous = nil }
}
