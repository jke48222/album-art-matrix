import Foundation

@main
struct PlaybackIdentityTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            let passed = value()
            checks.append(["name": name, "passed": passed])
            if !passed { fputs("FAIL: \(name)\n", stderr) }
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 0.000_001 } ?? false
        }
        let stamp = Date(timeIntervalSince1970: 1_790_116_560)
        var state = WallState(json: ["mode": "art", "now_showing": ["title": "  Song \n", "artist": " Artist ", "album": " artist "]])
        var identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("identity trims title and artist", identity.title == "Song" && identity.artist == "Artist")
        check("duplicate album identity is removed case-insensitively", identity.album.isEmpty)
        check("art without playback clock is explicitly displayed", identity.status == .displayed)
        check("missing time is not invented", identity.elapsed == nil && identity.duration == nil && identity.fraction == nil)

        state.songAt = 90
        state.songOf = 240
        state.songPlaying = true
        state.songStamped = stamp
        identity = PlaybackIdentity(state: state, link: .live, at: stamp.addingTimeInterval(30))
        check("live position advances from observation", near(identity.elapsed, 120))
        check("live progress fraction is accurate", near(identity.fraction, 0.5))
        check("playing enables clock scheduling", identity.advances && identity.status == .playing)
        identity = PlaybackIdentity(state: state, link: .live, at: stamp.addingTimeInterval(999))
        check("elapsed does not exceed duration", near(identity.elapsed, 240) && near(identity.fraction, 1))
        identity = PlaybackIdentity(state: state, link: .live, at: stamp.addingTimeInterval(-30))
        check("clock skew cannot reverse the song", near(identity.elapsed, 90))

        state.songPlaying = false
        identity = PlaybackIdentity(state: state, link: .live, at: stamp.addingTimeInterval(30))
        check("pause freezes position", near(identity.elapsed, 90))
        check("pause stops scheduled updates", !identity.advances && identity.status == .paused)
        identity = PlaybackIdentity(state: state, link: .standIn, at: stamp)
        check("paused phone preview does not claim playing", identity.context == "On this phone.")

        state.songPlaying = true
        identity = PlaybackIdentity(state: state, link: .offline(since: stamp.addingTimeInterval(7)), at: stamp.addingTimeInterval(99))
        check("offline position freezes at disconnect", near(identity.elapsed, 97))
        check("offline clock is stopped", !identity.advances && identity.status == .offline)
        check("offline identity is labeled last-known", identity.statusLabel == "Last known track")
        identity = PlaybackIdentity(state: state, link: .searching, at: stamp.addingTimeInterval(99))
        check("searching freezes position at observation", near(identity.elapsed, 90) && !identity.advances)

        for mode in ["weather", "frame", "clip", "video", "clock", "timer", "ambient", "game", "imagine", "off", "ticker"] {
            state.mode = mode
            state.songStamped = nil
            state.songAt = nil
            identity = PlaybackIdentity(state: state, link: .live, at: stamp)
            check("\(mode) retained title is not labeled wall artwork", identity.status == .lastPlayed)
            check("\(mode) missing clock never schedules progress updates", !identity.advances)
        }
        state.mode = "weather"
        state.songAt = 90
        state.songStamped = stamp
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("audio accompanying weather is separately named", identity.status == .audioPlaying && identity.statusLabel == "Audio playing")
        state.songPlaying = false
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("paused audio accompanying weather is separately named", identity.status == .audioPaused)

        state.songAt = .nan
        state.songOf = .infinity
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("nonfinite values cannot enter progress geometry", identity.elapsed == nil && identity.duration == nil && identity.fraction == nil)
        check("nonfinite position stops clock scheduling", !identity.advances)
        state.songAt = -1
        state.songOf = -30
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("negative values are unavailable", identity.elapsed == nil && identity.duration == nil)
        state.songAt = 30
        state.songOf = 0
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("unknown duration keeps elapsed but hides fraction", near(identity.elapsed, 30) && identity.duration == nil && identity.fraction == nil)
        state.title = " \n "
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("blank title means empty identity", !identity.hasSong && identity.status == .empty)
        check("empty weather title describes current mode", identity.title == "A window to the weather.")
        check("empty identity has no progress", identity.elapsed == nil && identity.duration == nil && !identity.advances)
        state.mode = "off"
        identity = PlaybackIdentity(state: state, link: .live, at: stamp)
        check("off mode reads asleep", identity.title == "The wall is asleep.")

        check("clock formats elapsed minutes", PlaybackIdentity.clock(125.9) == "2:05")
        check("clock supports long recordings", PlaybackIdentity.clock(3661) == "1:01:01")
        check("clock rejects NaN", PlaybackIdentity.clock(.nan) == "—:—")
        check("clock rejects infinity", PlaybackIdentity.clock(.infinity) == "—:—")
        check("clock rejects negative time", PlaybackIdentity.clock(-1) == "—:—")
        check("clock rejects overflow", PlaybackIdentity.clock(Double.greatestFiniteMagnitude) == "—:—")

        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let result: [String: Any] = ["suite": "PlaybackIdentity", "passed": checks.count - failed,
                                     "failed": failed, "checks": checks]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        if failed > 0 { exit(1) }
    }
}
