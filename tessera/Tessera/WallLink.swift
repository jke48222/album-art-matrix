// The wall link: one protocol, transports behind it. LAN ships first; MQTT and
// BLE arrive later behind the same seam. The UI never speaks a transport, it
// speaks LinkState, and the state chip always tells the truth about which one
// is carrying.

import Foundation
import QuartzCore
import SwiftUI

// MARK: - Models

/// GET /state, decoded tolerantly: unknown keys ignored, missing keys defaulted,
/// so an older or newer brain never blanks the app.
struct WallState: Equatable {
    var mode: String = "art"          // art | cd | ambient | off | frame | ticker | clock | clip
    var brightness: Double = 1.0      // 0.05...1.0
    var rpm: Double = 7.5
    var effect: String = "rainbow"
    var finish: String = "clean"
    var matchArt: Bool = false
    var color: String = "#e8b04b"
    var color2: String = "#e0491f"
    var tickerText: String = "HELLO"
    var tickerLoop: Bool = true
    var tickerStyle: String = "across"
    /// One ink per visible glyph, in order; empty means one ink for all.
    var tickerColors: [String] = []
    var clock24h: Bool = true
    var idle: String = "black"
    var away: String = "stay"
    var wakeEnabled: Bool = false
    var wakeTime: String = "07:00"
    var wakeFade: Double = 20
    var wbR: Double = 1.0
    var wbG: Double = 1.0
    var wbB: Double = 1.0
    var sun: String = "off"
    var sunNight: Double = 0.25
    var lat: Double = 999
    var lon: Double = 999
    var timerRemaining: Int? = nil
    var timerTotal: Int? = nil
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var artColors: [String] = []
    var sleepRemaining: Int? = nil
    /// Bumped by the brain whenever new CONTENT lands (track change, replay,
    /// pushed frame or clip), never on a settings change. The one honest key
    /// for arrival animations; 0 means an older brain that does not send it.
    var shownSeq: Int = 0
    /// Where the song is. Held as "this was true then" rather than as a
    /// number, so the phone can run the same clock the wall runs instead of
    /// showing a position that went stale the moment it arrived.
    var songAt: Double? = nil          // seconds in, at `songStamped`
    var songOf: Double? = nil          // seconds long
    var songPlaying: Bool = false
    var songStamped: Date? = nil

    /// The position now, extrapolated. Nil when nothing has said one.
    var songNow: Double? {
        guard let at = songAt, let stamped = songStamped else { return nil }
        guard songPlaying else { return at }
        let run = at + Date().timeIntervalSince(stamped)
        return min(run, songOf ?? run)
    }

    /// 0 to 1 through the track, when both ends are known.
    var songFraction: Double? {
        guard let of = songOf, of > 1, let now = songNow else { return nil }
        return min(1, max(0, now / of))
    }

    init() {}

    init(json: [String: Any]) {
        mode = json["mode"] as? String ?? "art"
        brightness = json["brightness"] as? Double ?? 1.0
        rpm = json["rpm"] as? Double ?? 7.5
        effect = json["effect"] as? String ?? "rainbow"
        finish = json["finish"] as? String ?? "clean"
        matchArt = json["match_art"] as? Bool ?? false
        color = json["color"] as? String ?? "#e8b04b"
        color2 = json["color2"] as? String ?? "#e0491f"
        tickerText = json["ticker_text"] as? String ?? "HELLO"
        tickerLoop = json["ticker_loop"] as? Bool ?? true
        tickerStyle = json["ticker_style"] as? String ?? "across"
        tickerColors = json["ticker_colors"] as? [String] ?? []
        clock24h = json["clock_24h"] as? Bool ?? true
        idle = json["idle"] as? String ?? "black"
        away = json["away"] as? String ?? "stay"
        wakeEnabled = json["wake_enabled"] as? Bool ?? false
        wakeTime = json["wake_time"] as? String ?? "07:00"
        wakeFade = json["wake_fade_min"] as? Double ?? 20
        wbR = json["wb_r"] as? Double ?? 1.0
        wbG = json["wb_g"] as? Double ?? 1.0
        wbB = json["wb_b"] as? Double ?? 1.0
        sun = json["sun"] as? String ?? "off"
        sunNight = json["sun_night"] as? Double ?? 0.25
        lat = json["lat"] as? Double ?? 999
        lon = json["lon"] as? Double ?? 999
        timerRemaining = json["timer_remaining_s"] as? Int
        timerTotal = json["timer_total_s"] as? Int
        if let now = json["now_showing"] as? [String: Any] {
            title = now["title"] as? String
            artist = now["artist"] as? String
            album = now["album"] as? String
        }
        if let p = json["progress"] as? [String: Any], let at = p["at"] as? Double {
            songAt = at / 1000
            songOf = (p["of"] as? Double).map { $0 / 1000 }
            songPlaying = p["playing"] as? Bool ?? false
            // The wall stamps in its own clock; what matters is elapsed since
            // it spoke, and this is the moment it reached us.
            songStamped = Date()
        }
        artColors = json["art_colors"] as? [String] ?? []
        sleepRemaining = json["sleep_remaining_s"] as? Int
        shownSeq = json["shown_seq"] as? Int ?? 0
    }
}

enum LinkState: Equatable {
    case searching
    case live                 // LAN, answering
    case offline(since: Date) // cached truth, stamped
    case standIn              // no wall anywhere; the app is running one

    var isLive: Bool { if case .live = self { true } else { false } }
    /// True when what is on screen is the app's own, not a wall's.
    var isStandIn: Bool { if case .standIn = self { true } else { false } }
}

// MARK: - Session

@MainActor
@Observable
final class WallSession {
    var state = WallState()
    var frame: Data? = nil            // 64*64*3 RGB888, pre-white-balance
    var link: LinkState = .searching
    var lastSync: Date? = nil
    /// What you asked for while the wall was not listening.
    let outbox = Outbox()

    /// A wall of our own, for when there is not one yet. Everything
    /// downstream takes frames and state without knowing the difference.
    /// The phone telling the wall what is playing.
    let push = NowPlayingPush()
    /// The wall on the lock screen, when the owner wants it there.
    let live = LiveWall()
    @ObservationIgnored private let standIn = StandIn()
    @ObservationIgnored private var misses = 0
    /// A cached snapshot means a real wall exists somewhere; the stand-in
    /// must not paint over it just because the wall is out of reach today.
    @ObservationIgnored private var hadSnapshot = false

    // The simulator shares the Mac's network: localhost reaches a brain
    // running beside it. On device the wall's mDNS name is the default.
    #if targetEnvironment(simulator)
    @ObservationIgnored @AppStorage("wall.host") var host = "localhost:8788"
    #else
    @ObservationIgnored @AppStorage("wall.host") var host = "album-matrix.local:8788" {
        didSet {
            // The widget's keys dial the wall themselves; they read the
            // address from the shared group, so it has to live there too.
            UserDefaults(suiteName: WallSnapshot.group)?.set(host, forKey: "wall.host")
        }
    }
    #endif

    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    /// One probe or pull in flight at a time, and NEVER awaited inside the
    /// render loop: an unreachable wall's connection timeout is three whole
    /// seconds, and awaiting it inline froze rendering for exactly that
    /// long on a metronome — the flight recorder caught eleven of them.
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private var lastSendSig = ""
    @ObservationIgnored private var lastSendAt = Date.distantPast
    @ObservationIgnored private var wasLive = false
    /// Keys written locally and not yet echoed back. A /state poll must not
    /// clobber them: the brain persists asynchronously, so between the tap and
    /// the next poll the wall can still be reporting the old value, and the
    /// control would visibly snap back. This is what made the lamp buttons
    /// look like they were fighting the finger.
    @ObservationIgnored private var pending: [String: Date] = [:]

    /// Hold a locally chosen value until the wall reports the same thing.
    private func keep<T: Equatable>(_ key: String, _ incoming: inout T, _ local: T) {
        guard holding(key) else { return }
        if incoming == local { pending.removeValue(forKey: key) } else { incoming = local }
    }

    private func keepNear(_ key: String, _ incoming: inout Double, _ local: Double, _ eps: Double) {
        guard holding(key) else { return }
        if abs(incoming - local) < eps { pending.removeValue(forKey: key) } else { incoming = local }
    }

    private func holding(_ key: String) -> Bool {
        guard let at = pending[key] else { return false }
        if Date().timeIntervalSince(at) > 4 {        // give up; trust the wall
            pending.removeValue(forKey: key)
            return false
        }
        return true
    }
    @ObservationIgnored private let http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    /// The frame is what changes; the settings are not. Poll them at
    /// different rates so the screen can answer the wall rather than a clock,
    /// and follow the frame harder when the wall is actually animating.
    ///
    /// The wall runs its animated modes at ~115 fps. The phone cannot and
    /// should not mirror that: each new frame costs a 4,096-emitter raster.
    /// 8 fps is enough for a spinning disc to read as spinning, and a static
    /// sleeve does not need even that.
    func start() {
        UserDefaults(suiteName: WallSnapshot.group)?.set(host, forKey: "wall.host")
        push.start()
        // Launch is this phone's music, immediately: the stand-in starts at
        // once, and a real wall that answers the background probe takes over
        // by itself within seconds. Nobody waits on a network to see a song.
        if frame == nil {
            hadSnapshot = WallSnapshot.read().px != nil
            enterStandIn()
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            var lastBeat = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let self else { return }
                // the watchdog that caught the probe stall, kept on duty:
                // any freeze of the render loop names itself and its mode
                let beat = CACurrentMediaTime()
                if beat - lastBeat > 0.3 {
                    FlightLog.note("STALL", String(format: "%.0fms in mode %@",
                        (beat - lastBeat) * 1000, self.state.mode))
                }
                lastBeat = beat
                if self.link.isStandIn {
                    self.tickStandIn()
                    // Keep looking for a real wall, but in the background:
                    // the probe shares no fate with the frame clock.
                    if tick % 90 == 0, !self.probing {
                        self.probing = true
                        Task { [weak self] in
                            await self?.pollState()
                            self?.probing = false
                        }
                    }
                    tick &+= 1
                    // words pop on the song's clock; everything else is
                    // happy at ten frames a second
                    let pace = self.state.mode == "lyrics" ? 66 : 100
                    try? await Task.sleep(for: .milliseconds(pace))
                    continue
                }
                let animating = ["cd", "ambient", "ticker", "clip"].contains(self.state.mode)
                if tick % 16 == 0, !self.probing {                    // ~2s
                    self.probing = true
                    Task { [weak self] in
                        await self?.pollState()
                        self?.probing = false
                    }
                }
                if animating || tick % 2 == 0, !self.pulling {
                    self.pulling = true
                    Task { [weak self] in
                        await self?.pullFrame()
                        self?.pulling = false
                    }
                }
                // An away wall keeps its last sleeve on screen, which is
                // honest for art and a lie for everything animated: choose
                // the lamp with no wall answering and a frozen sleeve says
                // the choice did nothing. For modes the phone can render
                // itself, the stand-in becomes the display while the outbox
                // holds the intent for the wall's return.
                if case .offline = self.link,
                   ["ambient", "ticker", "timer", "cd", "nine", "lyrics"].contains(self.state.mode) {
                    self.renderLocally()
                }
                tick &+= 1
                try? await Task.sleep(for: .milliseconds(
                    self.state.mode == "lyrics" ? 66 : 125))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func url(_ path: String) -> URL? { URL(string: "http://\(host)\(path)") }

    func poll() async { await pollState() }

    func pollState() async {
        guard let stateURL = url("/state") else { return }
        do {
            let (data, _) = try await http.data(from: stateURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let reconnected = !wasLive
            var fresh = WallState(json: json)

            // Anything still in flight keeps the value the finger chose, and
            // stops being held the moment the wall agrees.
            let mine = state
            keep("mode", &fresh.mode, mine.mode)
            keep("effect", &fresh.effect, mine.effect)
            keep("finish", &fresh.finish, mine.finish)
            keep("match_art", &fresh.matchArt, mine.matchArt)
            keep("color", &fresh.color, mine.color)
            keep("color2", &fresh.color2, mine.color2)
            keep("ticker_text", &fresh.tickerText, mine.tickerText)
            keep("ticker_loop", &fresh.tickerLoop, mine.tickerLoop)
            keep("ticker_style", &fresh.tickerStyle, mine.tickerStyle)
            keep("ticker_colors", &fresh.tickerColors, mine.tickerColors)
            keep("clock_24h", &fresh.clock24h, mine.clock24h)
            keep("idle", &fresh.idle, mine.idle)
            keep("away", &fresh.away, mine.away)
            keep("wake_enabled", &fresh.wakeEnabled, mine.wakeEnabled)
            keep("wake_time", &fresh.wakeTime, mine.wakeTime)
            keep("wake_fade_min", &fresh.wakeFade, mine.wakeFade)
            keepNear("wb_r", &fresh.wbR, mine.wbR, 0.005)
            keepNear("wb_g", &fresh.wbG, mine.wbG, 0.005)
            keepNear("wb_b", &fresh.wbB, mine.wbB, 0.005)
            keep("sun", &fresh.sun, mine.sun)
            keepNear("sun_night", &fresh.sunNight, mine.sunNight, 0.005)
            keepNear("lat", &fresh.lat, mine.lat, 0.001)
            keepNear("lon", &fresh.lon, mine.lon, 0.001)
            keepNear("rpm", &fresh.rpm, mine.rpm, 0.01)
            keepNear("brightness", &fresh.brightness, mine.brightness, 0.001)

            state = fresh
            lastSync = Date()
            if reconnected {
                Taps.found()                      // the lamp switched on
                FlightLog.note("LINK", "wall answered at \(host)")
            }
            wasLive = true
            link = .live
            if reconnected { flushOutbox() }
            WallSnapshot.write(px: frame.map { [UInt8]($0) }, title: state.title,
                               artist: state.artist, mode: state.mode, host: host)
            live.update(state: state, frame: frame.map { [UInt8]($0) } ?? [], wall: host)
        } catch {
            misses += 1
            // Three misses is about six seconds of asking. After that, stop
            // showing an empty room and run a wall instead. Anything the app
            // has genuinely seen before is still worth showing as offline —
            // and a cached snapshot counts as seen: an owner opening the app
            // away from home keeps their wall's last frame, stamped, rather
            // than having it painted over by a phone-made one.
            if lastSync == nil, misses >= 3, !hadSnapshot, !link.isStandIn {
                enterStandIn()
            } else if wasLive || linkIsSearching {
                link = .offline(since: lastSync ?? Date())
            }
            wasLive = false
        }
    }

    // MARK: - Stand-in

    private func enterStandIn() {
        guard !link.isStandIn else { return }
        FlightLog.note("LINK", "stand-in takes over")
        standIn.refreshNowPlaying()
        state = standIn.state
        link = .standIn
    }

    /// Leave the stand-in and go looking again. The next successful poll
    /// takes over completely.
    func lookForWallAgain() {
        misses = 0
        link = .searching
        Task { await pollState() }
    }

    /// The stand-in as a pure renderer: this session's own state pushed into
    /// it, only the frame taken back. Unlike tickStandIn it never adopts the
    /// stand-in's state, because when the wall is merely away the state is
    /// still this session's business, not the stand-in's.
    private func renderLocally() {
        standIn.refreshNowPlaying()
        standIn.apply([
            "mode": state.mode,
            "effect": state.effect,
            "match_art": state.matchArt,
            "color": state.color,
            "color2": state.color2,
            "ticker_text": state.tickerText,
            "ticker_loop": state.tickerLoop,
            "ticker_style": state.tickerStyle,
            "ticker_colors": state.tickerColors,
            "rpm": state.rpm,
        ])
        let px = standIn.frame()
        // a finished non-looping run hands back to art, wall or no wall
        if standIn.state.mode != state.mode { state.mode = standIn.state.mode }
        if px != frame { frame = px }
    }

    private func tickStandIn() {
        // each stage timed: the recorder saw ~350ms hiccups in spin mode
        // and this names the stage next time instead of leaving a lineup
        var mark = CACurrentMediaTime()
        func lap(_ name: String) {
            let now = CACurrentMediaTime()
            if now - mark > 0.12 {
                FlightLog.note("SLOW", String(format: "%@ %.0fms in %@",
                                              name, (now - mark) * 1000, state.mode))
            }
            mark = now
        }
        standIn.refreshNowPlaying()
        lap("refresh")
        // frame() first: a sleep fade expiring inside it flips mode to off,
        // and the state published here must be the one that drew the frame.
        frame = standIn.frame()
        lap("frame")
        state = standIn.state
        live.update(state: state, frame: frame.map { [UInt8]($0) } ?? [], wall: "stand-in")
        lap("liveActivity")
    }

    private var linkIsSearching: Bool { if case .searching = link { true } else { false } }

    /// Identity of what the wall is SHOWING, for arrival animations. The
    /// brain's shown_seq bumps on every new content and never on a settings
    /// change, so keying on it sweeps for same-title tracks and repeat pushes
    /// and never false-fires on a mode tap. An older brain (seq 0) falls back
    /// to the title; the stand-in mints its own seq.
    var arrivalKey: String {
        state.shownSeq > 0 ? "seq-\(state.shownSeq)" : (state.title ?? "")
    }

    /// The one JSON POST every endpoint shares: request shape, status check,
    /// timeout. Four hand-rolled copies of this had already drifted apart.
    private func postJSON(_ path: String, _ obj: [String: Any]) async -> Bool {
        guard let u = url(path),
              let body = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (_, resp) = try? await http.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    private func pullFrame() async {
        guard let frameURL = url("/frame.raw") else { return }
        if let (data, resp) = try? await http.data(from: frameURL),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           data.count == 64 * 64 * 3 {
            // Only publish when the bytes actually changed. Two identical
            // frames must leave the screen perfectly still.
            if data != frame { frame = data }
        }
    }

    /// Put a moving thing on the wall. The brain loops it until a mode
    /// change; up to 240 frames at up to 24 fps is its whole appetite.
    /// Same rules as every other send: the stand-in plays it, and a wall
    /// that is away gets it queued instead of dropped after a success face.
    func pushClip(_ frames: [[UInt8]], fps: Double) {
        let valid = Array(frames.filter { $0.count == 64 * 64 * 3 }.prefix(240))
        guard !valid.isEmpty else { return }
        if link.isStandIn {
            standIn.push(clip: valid, fps: fps)
            state = standIn.state
            Taps.landed()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if await self.postJSON("/clip", [
                "fps": min(24, max(1, fps)),
                "frames": valid.map { Data($0).base64EncodedString() },
            ]) {
                Taps.landed()
            } else {
                self.outbox.add(clip: valid, fps: fps)
                Taps.error()
            }
        }
    }

    /// Wear a journal entry again. The wall pins it for ten minutes so the
    /// currently playing track does not immediately steamroll it. Entries the
    /// PHONE recorded (stand-in days) carry timestamps the wall's journal has
    /// never heard of, so those replay from the local store as a frame push,
    /// which also makes the panel scrub work with no wall at all.
    func replay(ts: Int) {
        if let px = LocalJournal.frame(ts) {
            pushFrame(px)
            return
        }
        if link.isStandIn { Taps.error(); return }
        Task { [weak self] in
            guard let self else { return }
            if await self.postJSON("/replay", ["ts": ts]) {
                Taps.landed()
            } else {
                Taps.error()
            }
        }
    }

    /// Put a flat field on the wall for a panel check, through the brain's
    /// own /frame endpoint (base64 of 64*64*3 raw RGB, mode becomes "frame").
    func pushFlat(r: UInt8, g: UInt8, b: UInt8) {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in stride(from: 0, to: px.count, by: 3) {
            px[i] = r; px[i + 1] = g; px[i + 2] = b
        }
        pushFrame(px)
    }

    /// Put an exact 64x64 frame on the wall. What you drew is what it lights.
    func pushFrame(_ px: [UInt8]) {
        guard px.count == 64 * 64 * 3 else { return }
        if link.isStandIn {
            // It lands on the stand-in wall the way it lands on the real one:
            // as content, in mode "frame", held until something else is
            // chosen. Writing only `frame` here let the next art tick erase
            // the drawing within 125 ms of its success haptic.
            standIn.push(frame: px)
            state = standIn.state
            frame = standIn.frame()
            Taps.landed()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if await self.postJSON("/frame", ["px": Data(px).base64EncodedString()]) {
                Taps.landed()
            } else {
                self.outbox.add(frame: px)
                Taps.error()
            }
        }
    }

    /// A frame that is one tick of a stream, not a kept thing: no outbox, no
    /// haptic, no retry. A game pushes eight of these a second, and treating
    /// a missed one like a lost drawing would queue garbage and buzz the
    /// whole time the wall was slow.
    func beam(_ px: [UInt8]) {
        guard px.count == 64 * 64 * 3 else { return }
        if link.isStandIn {
            standIn.push(frame: px)
            state = standIn.state
            frame = standIn.frame()
            return
        }
        Task { [weak self] in
            _ = await self?.postJSON("/frame", ["px": Data(px).base64EncodedString()])
        }
    }

    /// POST a partial state patch. Optimistic locally, honest on failure:
    /// the next poll re-syncs whatever the wall actually accepted.
    func send(_ patch: [String: Any]) {
        // The colour well fired identical patches four times in 30ms; the
        // wall needs to hear each intent once.
        let sig = patch.keys.sorted().map { "\($0)=\(patch[$0] ?? "")" }
            .joined(separator: "&")
        if sig == lastSendSig, Date().timeIntervalSince(lastSendAt) < 0.15 {
            return
        }
        lastSendSig = sig
        lastSendAt = Date()
        FlightLog.note("SEND", patch.keys.sorted().joined(separator: ","))
        // optimistic merge so controls answer instantly
        var merged = patch
        if let m = merged["mode"] as? String { state.mode = m }
        if let b = merged["brightness"] as? Double { state.brightness = b }
        if let r = merged["rpm"] as? Double { state.rpm = r }
        if let e = merged["effect"] as? String { state.effect = e }
        if let f = merged["finish"] as? String { state.finish = f }
        if let ma = merged["match_art"] as? Bool { state.matchArt = ma }
        if let c = merged["color"] as? String { state.color = c }
        if let c = merged["color2"] as? String { state.color2 = c }
        if let v = merged["ticker_text"] as? String { state.tickerText = v }
        if let v = merged["ticker_loop"] as? Bool { state.tickerLoop = v }
        if let v = merged["ticker_style"] as? String { state.tickerStyle = v }
        if let v = merged["ticker_colors"] as? [String] { state.tickerColors = v }
        // Commands read optimistically too: a timer starts counting on the
        // screen the moment it is asked for, not a round-trip later.
        if let v = merged["timer_min"] as? Double {
            if v > 0 {
                state.mode = "timer"
                state.timerTotal = Int(v * 60)
                state.timerRemaining = Int(v * 60)
            } else if state.mode == "timer" {
                state.mode = "clock"
                state.timerRemaining = nil
                state.timerTotal = nil
            }
        }
        if let v = merged["clock_24h"] as? Bool { state.clock24h = v }
        if let v = merged["idle"] as? String { state.idle = v }
        if let v = merged["away"] as? String { state.away = v }
        if let v = merged["wake_enabled"] as? Bool { state.wakeEnabled = v }
        if let v = merged["wake_time"] as? String { state.wakeTime = v }
        if let v = merged["wake_fade_min"] as? Double { state.wakeFade = v }
        if let v = merged["wb_r"] as? Double { state.wbR = v }
        if let v = merged["wb_g"] as? Double { state.wbG = v }
        if let v = merged["wb_b"] as? Double { state.wbB = v }
        if let v = merged["sun"] as? String { state.sun = v }
        if let v = merged["sun_night"] as? Double { state.sunNight = v }
        if let v = merged["lat"] as? Double { state.lat = v }
        if let v = merged["lon"] as? Double { state.lon = v }
        merged.removeValue(forKey: "_local")
        for key in merged.keys { pending[key] = Date() }

        if link.isStandIn {
            standIn.apply(merged)
            state = standIn.state
            return
        }
        // An away wall still answers locally: the stand-in mirrors commands
        // like timers so what renders matches what was asked, and the outbox
        // still carries the intent to the wall when it returns.
        if !link.isLive { standIn.apply(merged) }

        Task { [weak self] in
            guard let self else { return }
            if !(await self.postJSON("/state", merged)) {
                // Intent survives the network. It goes out when the wall
                // answers again, and the UI says so in the meantime.
                FlightLog.note("SEND", "wall away; queued \(merged.keys.sorted().joined(separator: ","))")
                self.outbox.add(patch: merged)
                Taps.error()
            }
        }
    }

    /// Everything queued while the wall was away, in one ORDERED pass. The
    /// brain force-sets mode "frame" on a frame push, so the kinds are sent
    /// oldest first and the newest intent lands last and wins; firing them as
    /// parallel tasks let the network decide which one the user meant.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        var jobs: [(Date, () async -> Bool)] = []
        if let f = outbox.frame {
            jobs.append((outbox.frameAt ?? .distantPast,
                         { await self.postJSON("/frame", ["px": Data(f).base64EncodedString()]) }))
        }
        if let c = outbox.clip {
            jobs.append((outbox.clipAt ?? .distantPast,
                         { await self.postJSON("/clip", [
                             "fps": min(24, max(1, c.fps)),
                             "frames": c.frames.map { Data($0).base64EncodedString() },
                         ]) }))
        }
        if !outbox.patch.isEmpty {
            let p = outbox.patch
            jobs.append((outbox.patchAt ?? .distantPast,
                         { await self.postJSON("/state", p) }))
        }
        outbox.clear()
        jobs.sort { $0.0 < $1.0 }
        Task { [weak self] in
            var allLanded = true
            for job in jobs {
                if !(await job.1()) { allLanded = false }
            }
            guard self != nil else { return }
            if allLanded { Taps.landed() } else { Taps.error() }
        }
    }
}
