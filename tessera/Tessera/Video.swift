// A video on the wall, from a link on this phone.
//
// Paste a YouTube link, or a link to any video file, and the wall fetches
// it: the picture decoded on the wall at 64 px, the sound kept on the wall
// as a small file for this phone to play. The wall has no speaker, so the
// phone is the speaker, through whatever it is connected to, and the
// phone's player is the clock: every second it tells the wall where it is,
// and the wall shows that moment. Pause here and the wall pauses; scrub here
// and the wall follows. With the sound off, the wall keeps its own time.

import AVFoundation
import Foundation
import SwiftUI

// MARK: - What the wall says

/// GET /state carries this under "video" while a video is on or on its way.
struct WallVideo: Equatable {
    var status = "idle"          // fetching ready playing paused ended error
    var error: String?
    var url = ""
    var title: String?
    var author: String?
    var duration: Double?
    var position: Double = 0
    var buffered: Double = 0
    var note: String?
    var sound = false            // the wall has (or is fetching) sound for the phone
    var soundReady = false
    var soundGot = 0
    var soundTotal: Int?
    var loop = false
    var phoneClock = false

    init(json: [String: Any]) {
        status = json["status"] as? String ?? "idle"
        error = json["error"] as? String
        url = json["url"] as? String ?? ""
        title = json["title"] as? String
        author = json["author"] as? String
        duration = json["duration_s"] as? Double
        position = json["position_s"] as? Double ?? 0
        buffered = json["buffered_s"] as? Double ?? 0
        note = json["note"] as? String
        sound = json["sound"] as? Bool ?? false
        soundReady = json["sound_ready"] as? Bool ?? false
        soundGot = json["sound_got"] as? Int ?? 0
        soundTotal = json["sound_total"] as? Int
        loop = json["loop"] as? Bool ?? false
        phoneClock = (json["clock"] as? String) == "phone"
    }

    var live: Bool { ["fetching", "ready", "playing", "paused"].contains(status) }

    /// One line on where things stand, for the board.
    var words: String {
        switch status {
        case "fetching":
            if sound, let total = soundTotal, total > 0 {
                return "Fetching. Sound \(Int(Double(soundGot) / Double(total) * 100))%."
            }
            return "Fetching."
        case "ready": return sound ? "Ready. Starting the sound." : "Ready."
        case "playing": return "\(Self.clock(position))\(duration.map { " of " + Self.clock($0) } ?? "")"
        case "paused": return "Paused at \(Self.clock(position))"
        case "ended": return "Over."
        case "error": return error ?? "Something went wrong."
        default: return error ?? "Nothing on."
        }
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Talking to the wall

enum WallVideoLink {
    /// POST a body, get the wall's JSON back; an error the wall stated comes
    /// back under "error", and a wall that did not answer comes back nil.
    @discardableResult
    static func post(host: String, _ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            return ["error": json?["error"] as? String ?? "The wall said \(code)."]
        }
        return json ?? [:]
    }

    /// Hand the wall a link. Comes back with what went wrong, or nil.
    static func start(host: String, url: String, sound: Bool) async -> String? {
        guard let r = await post(host: host, "/video", ["url": url, "sound": sound]) else {
            return "The wall is not answering right now."
        }
        return r["error"] as? String
    }

    static func clock(host: String, t: Double, playing: Bool) async {
        await post(host: host, "/video/clock", ["t": t, "playing": playing])
    }

    static func control(host: String, _ action: String, t: Double? = nil) async {
        var body: [String: Any] = ["action": action]
        if let t { body["t"] = t }
        await post(host: host, "/video/control", body)
    }

    static func stop(host: String) async {
        await post(host: host, "/video/stop", [:])
    }
}

// MARK: - The sound, on this phone

/// Plays the sound the wall made, and tells the wall where it is. One for
/// the whole app: the page and the board both look at the same player.
@MainActor
@Observable
final class VideoSound {
    static let shared = VideoSound()

    private(set) var started = false
    private(set) var playing = false
    private(set) var time: Double = 0
    /// Which video the player was started for, so "ready" seen twice starts
    /// it once, and a new link starts it again.
    private(set) var key = ""

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endWatch: NSObjectProtocol?
    @ObservationIgnored private var host = ""
    @ObservationIgnored private var localFile: URL?

    enum Source {
        case wall              // the m4a the wall made
        case file(URL)         // a video of this phone's own; its sound
    }

    /// The wall's word, on every poll: the sound starts when the wall is
    /// waiting for this phone's clock, and stops when the video is gone.
    ///
    /// A video shared from the share sheet starts on the wall with no app
    /// open, so the wall plays it itself. This does NOT jump in and start
    /// blaring when the app is opened later; that is a button (`join`), so
    /// sound only ever begins because someone asked for it.
    func follow(_ v: WallVideo?, mode: String, host: String) {
        guard let v, v.live, mode == "video" else {
            if started { stop() }
            return
        }
        guard v.status == "ready", v.phoneClock else { return }
        if v.sound {
            begin(host: host, key: v.url, source: .wall)
        } else if let local = VideoHandoff.localSound, local.key == v.url {
            begin(host: host, key: v.url, source: .file(local.url))
        } else if key != v.url, !VideoHandoff.inProgress {
            // nothing here to play sound from: the wall keeps its own time
            key = v.url
            Task { await WallVideoLink.control(host: host, "play") }
        }
    }

    /// The wall is playing something on its own clock and there is sound
    /// sitting on it. Pick it up from where the wall has got to.
    func join(_ v: WallVideo, host: String) {
        begin(host: host, key: v.url, source: .wall, at: v.position)
    }

    /// The wall says ready: play the sound, unless this is the same video
    /// this player is already on.
    func begin(host: String, key: String, source: Source = .wall, at start: Double = 0) {
        guard key != self.key || !started else { return }
        stop()
        self.key = key
        self.host = host
        let url: URL
        switch source {
        case .wall:
            guard let u = URL(string: "http://\(host)/video/audio") else { return }
            url = u
        case .file(let u):
            url = u
            localFile = u
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        started = true
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                             queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t.seconds) }
        }
        endWatch = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                          object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        if start > 1 {
            p.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
            time = start
        }
        p.play()
        playing = true
        tell()
    }

    func pause() {
        player?.pause()
        playing = false
        tell()
    }

    func resume() {
        player?.play()
        playing = true
        tell()
    }

    func seek(to t: Double) {
        time = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.tell() }
        }
    }

    func stop() {
        if let o = observer, let p = player { p.removeTimeObserver(o) }
        if let e = endWatch { NotificationCenter.default.removeObserver(e) }
        observer = nil
        endWatch = nil
        player?.pause()
        player = nil
        started = false
        playing = false
        time = 0
        key = ""
        if let f = localFile {
            // the original was kept only for its sound
            try? FileManager.default.removeItem(at: f)
            localFile = nil
            if VideoHandoff.localSound?.url == f { VideoHandoff.localSound = nil }
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        time = t
        if playing { tell() }
    }

    private func ended() {
        playing = false
        tell()
    }

    /// Where this phone is, to the wall. Once a second while playing, and
    /// at once on any change, so the wall never waits on the next tick.
    private func tell() {
        guard started, let p = player else { return }
        let t = p.currentTime().seconds
        let h = host, on = playing
        Task { await WallVideoLink.clock(host: h, t: t.isFinite ? t : 0, playing: on) }
    }
}
