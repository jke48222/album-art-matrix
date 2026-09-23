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

        var local = WallState(json: ["now_showing": ["title":"Song", "artist":"ADÉLA"], "progress":["at":45000.0,"of":240000.0,"playing":true,"stamped":stamp.timeIntervalSince1970]])
        let pause = LocalPlaybackSample(title:"Song", artist:"ADÉLA", position:46, duration:240, playing:false, observed:stamp)
        pause.apply(to:&local, at:stamp)
        check("local pause freezes the playbar immediately", !local.songPlaying && near(local.songPosition(at:stamp.addingTimeInterval(9)),46))
        let resume = LocalPlaybackSample(title:"Song", artist:"ADÉLA", position:46, duration:240, playing:true, observed:stamp.addingTimeInterval(10))
        resume.apply(to:&local, at:stamp.addingTimeInterval(10))
        check("resume advances only from resumed position", local.songPlaying && near(local.songPosition(at:stamp.addingTimeInterval(12)),48))
        var stranger = local; stranger.title = "Other song"
        pause.apply(to:&stranger,at:stamp)
        check("paused local song cannot freeze a different wall song", stranger.songPlaying)
        var stale = local
        pause.apply(to:&stale,at:stamp.addingTimeInterval(20))
        check("expired local sample cannot override fresh wall", stale.songPlaying)
        let archive = WallState(json:["replay_active":true,"now_showing":["title":"Archived","artist":"Archive"],"now_playing":["title":"Current","artist":"Player"]])
        check("archive artwork cannot replace playback identity", archive.replayActive && archive.title == "Current")

        // Reproduce the real /state contract: the brain polls music more
        // slowly than the phone polls /state. Between source polls it repeats
        // both the raw position and the original source observation stamp.
        func sample(position: Double = 120_000, observed: Double? = 0,
                    playing: Bool = true, title: String = "Clock test", duration: Double? = 240_000,
                    received: Double, skew: Double = 0) -> WallState {
            var progress: [String: Any] = ["at": position, "playing": playing]
            if let observed { progress["stamped"] = stamp.timeIntervalSince1970 + observed + skew }
            if let duration { progress["of"] = duration }
            return WallState(json: ["now_showing": ["title": title, "artist": "Tessera"], "progress": progress],
                             receivedAt: stamp.addingTimeInterval(received))
        }
        var clock = PlaybackClock()
        var trace: [[String: Any]] = []
        var lastElapsed = -1.0
        var legacyElapsed = -1.0
        var oldRegressionObserved = false
        let receipts = [0.2, 0.9, 1.7, 2.6, 3.1, 3.8, 4.7, 5.6, 6.2, 7.4]
        for (index, receipt) in receipts.enumerated() {
            let observed = receipt >= 6 ? 6.0 : receipt >= 3 ? 3.0 : 0
            let date = stamp.addingTimeInterval(receipt)
            let packet = sample(position: (120 + observed) * 1000, observed: observed, received: receipt)
            let accepted = clock.receive(packet, from: "wall", at: date)
            let actual = PlaybackIdentity(state: accepted, link: .live, at: date).elapsed!
            check("repeated source observations stay on time at \(receipt)s", near(actual, 120 + receipt))
            check("poll receipt never rewinds elapsed at \(receipt)s", actual >= lastElapsed)
            // This is the old receipt-time decoder, kept only as evidence
            // that this trace actually reproduces the reported regression.
            var old = packet
            old.songStamped = date
            let oldValue = old.songPosition(at: date)!
            if oldValue < legacyElapsed { oldRegressionObserved = true }
            let untilNextPoll = index + 1 < receipts.count ? receipts[index + 1] - receipt : 1
            let displayDelta = min(0.5, untilNextPoll * 0.9)
            let nextDisplay = date.addingTimeInterval(displayDelta)
            legacyElapsed = old.songPosition(at: nextDisplay)!
            trace.append(["received_s": receipt, "source_stamp_s": observed,
                          "old_elapsed_s": oldValue, "correct_elapsed_s": actual])
            trace.append(["display_tick_s": receipt + displayDelta, "source_stamp_s": observed,
                          "old_elapsed_s": legacyElapsed,
                          "correct_elapsed_s": accepted.songPosition(at: nextDisplay)!])
            lastElapsed = actual
        }
        check("regression trace demonstrates old forward-backwards clock", oldRegressionObserved)

        let shortSeek = clock.receive(sample(position: 126_000, observed: 8, received: 8.2), from: "wall", at: stamp.addingTimeInterval(8.2))
        check("one-second backwards seek is preserved", near(shortSeek.songPosition(at: stamp.addingTimeInterval(8.2)), 126.2))
        let longSeek = clock.receive(sample(position: 10_000, observed: 9, received: 9.2), from: "wall", at: stamp.addingTimeInterval(9.2))
        check("long backwards seek is preserved", near(longSeek.songPosition(at: stamp.addingTimeInterval(9.2)), 10.2))
        let forwardSeek = clock.receive(sample(position: 180_000, observed: 10, received: 10.2), from: "wall", at: stamp.addingTimeInterval(10.2))
        check("forward seek is preserved", near(forwardSeek.songPosition(at: stamp.addingTimeInterval(10.2)), 180.2))
        let paused = clock.receive(sample(position: 181_600, observed: 11, playing: false, received: 12), from: "wall", at: stamp.addingTimeInterval(12))
        check("pause freezes at reported player position", near(paused.songPosition(at: stamp.addingTimeInterval(20)), 181.6))
        let resumed = clock.receive(sample(position: 181_600, observed: 20, received: 20.4), from: "wall", at: stamp.addingTimeInterval(20.4))
        check("resume uses source resume time", near(resumed.songPosition(at: stamp.addingTimeInterval(21)), 182.6))
        let nextSong = clock.receive(sample(position: 0, observed: 22, title: "A different song", received: 22.3), from: "wall", at: stamp.addingTimeInterval(22.3))
        check("song change starts its own clock", near(nextSong.songPosition(at: stamp.addingTimeInterval(23)), 1))
        let offline = PlaybackIdentity(state: nextSong, link: .offline(since: stamp.addingTimeInterval(24)), at: stamp.addingTimeInterval(30))
        check("timestamped clock freezes at actual disconnect", near(offline.elapsed, 2))
        let missingDuration = clock.receive(sample(position: 5_000, observed: 25, duration: nil, received: 25.2), from: "wall", at: stamp.addingTimeInterval(25.2))
        check("unknown duration still advances timestamped elapsed", near(missingDuration.songPosition(at: stamp.addingTimeInterval(27)), 7))

        var legacyClock = PlaybackClock()
        let legacyFirst = legacyClock.receive(sample(observed: nil, received: 0.1), from: "old-wall", at: stamp.addingTimeInterval(0.1))
        let legacyRepeat = legacyClock.receive(sample(observed: nil, received: 2.1), from: "old-wall", at: stamp.addingTimeInterval(2.1))
        check("legacy repeated payload retains first observation", legacyRepeat.songStamped == legacyFirst.songStamped)
        check("legacy repeated payload does not restart elapsed", near(legacyRepeat.songPosition(at: stamp.addingTimeInterval(2.1)), 122))
        let legacyPause = legacyClock.receive(sample(observed: nil, playing: false, received: 3.1), from: "old-wall", at: stamp.addingTimeInterval(3.1))
        check("legacy pause is accepted even at unchanged position", near(legacyPause.songPosition(at: stamp.addingTimeInterval(9)), 120))
        let legacyNext = legacyClock.receive(sample(observed: nil, title: "New legacy track", received: 4.1), from: "old-wall", at: stamp.addingTimeInterval(4.1))
        check("legacy next track cannot inherit previous anchor", near(legacyNext.songPosition(at: stamp.addingTimeInterval(5.1)), 121))

        var skewedClock = PlaybackClock()
        let skewedFirst = skewedClock.receive(sample(received: 5, skew: -3600), from: "slow-wall", at: stamp.addingTimeInterval(5), serverDate: stamp.addingTimeInterval(5 - 3600))
        check("HTTP date calibrates large wall clock skew", near(skewedFirst.songPosition(at: stamp.addingTimeInterval(5)), 125))
        let skewedRepeat = skewedClock.receive(sample(received: 7.8, skew: -3600), from: "slow-wall", at: stamp.addingTimeInterval(7.8), serverDate: stamp.addingTimeInterval(7 - 3600))
        check("second-precision HTTP date cannot introduce poll jitter", near(skewedRepeat.songPosition(at: stamp.addingTimeInterval(7.8)), 127.8))
        let newWall = skewedClock.receive(sample(received: 8), from: "synchronized-wall", at: stamp.addingTimeInterval(8), serverDate: stamp.addingTimeInterval(8))
        check("changing wall clears previous clock offset", near(newWall.songPosition(at: stamp.addingTimeInterval(8)), 128))
        let headerResponse = HTTPURLResponse(url: URL(string: "http://wall/state")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Date": "Tue, 22 Sep 2026 22:36:00 GMT"])!
        check("HTTP clock header parses in GMT", PlaybackClock.serverDate(headerResponse) == stamp)
        let badHeader = HTTPURLResponse(url: URL(string: "http://wall/state")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Date": "invalid"])!
        check("malformed clock header safely falls back", PlaybackClock.serverDate(badHeader) == nil)

        let malformed = sample(position: .nan, observed: 1, duration: .infinity, received: 1)
        check("wire nonfinite position is rejected before geometry", malformed.songAt == nil && malformed.songStamped == nil)
        let negative = sample(position: -50, observed: 1, received: 1)
        check("wire negative position is rejected", negative.songAt == nil)

        let failed = checks.filter { ($0["passed"] as? Bool) != true }.count
        let result: [String: Any] = ["suite": "PlaybackIdentity", "passed": checks.count - failed,
                                     "failed": failed, "checks": checks, "poll_regression_trace": trace]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        if failed > 0 { exit(1) }
    }
}
