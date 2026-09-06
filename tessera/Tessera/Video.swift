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
import UIKit

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

    /// The wall says ready: play its sound, unless this is the same video
    /// this player is already on.
    func begin(host: String, key: String) {
        guard key != self.key || !started else { return }
        stop()
        self.key = key
        self.host = host
        guard let url = URL(string: "http://\(host)/video/audio") else { return }
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

// MARK: - The page: a link in

struct VideoPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    let accent: Color

    @State private var link = ""
    @AppStorage("video.sound") private var sound = true
    @State private var busy = false
    @State private var problem: String?
    @State private var clipboardHasLink = false

    private var typed: String {
        // a shared text can wrap the link in words; the link is what counts
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("http") { return raw }
        return raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init).first { $0.lowercased().hasPrefix("http") } ?? raw
    }
    private var canPlay: Bool { typed.lowercased().hasPrefix("http") && !busy && !wall.link.isStandIn }

    var body: some View {
        NavigationStack {
            SetupPage("Video", blurb: "A YouTube link, or a link to a video file. The wall fetches it and plays the picture at its own size; the sound plays on this phone, so the two stay in step.") {
                SetupGroup("The link", note: wall.link.isStandIn
                           ? "The wall is not answering, so nothing can be played right now."
                           : "The wall does the fetching. Sound comes to this phone and plays through whatever it is connected to.") {
                    KeyField(placeholder: "https://youtu.be/...", text: $link)
                    Rule()
                    if clipboardHasLink {
                        SetupRow(title: "There is a link on the clipboard", subtitle: nil) {
                            ActionPill(title: "Paste", filled: false) { paste() }
                        }
                        Rule()
                    }
                    Toggle(isOn: $sound) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sound on this phone").font(.ui(16)).foregroundStyle(Ink.ink)
                            Text(sound ? "The wall follows this phone's player."
                                       : "Picture only; the wall keeps its own time.")
                                .font(.ui(13)).foregroundStyle(Ink.dim)
                        }
                    }
                    .tint(accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Rule()
                    SaveLine(title: "Play on the wall", enabled: canPlay, busy: busy, done: nil,
                             accent: accent) { play() }
                }
                .padding(.top, -12)
                Problem(text: problem)

                if wall.state.video != nil || wall.state.mode == "video" {
                    SetupGroup("On the wall", note: nil) {
                        VideoBoard(accent: accent) {}
                            .padding(16)
                    }
                }

                SetupGroup("How it works", note: nil) {
                    fact("Picture", "Decoded on the wall from the smallest stream there is. 144p is already twice the panel.")
                    Rule()
                    fact("Sound", "A small file on the wall, played by this phone. Nothing is kept once the video is over.")
                    Rule()
                    fact("Time", "This phone's player is the clock. The wall shows the frame for the moment it names, once a second.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.ui(15, .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .onAppear { clipboardHasLink = UIPasteboard.general.hasURLs }
    }

    private func fact(_ name: String, _ words: String) -> some View {
        SetupRow(title: name, subtitle: words) { EmptyView() }
    }

    private func paste() {
        if let u = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string {
            link = u
            clipboardHasLink = false
            Taps.detent(intensity: 0.4)
        }
    }

    private func play() {
        let url = typed
        guard canPlay else { return }
        busy = true
        problem = nil
        VideoSound.shared.stop()
        Task {
            // The page stays up while the wall fetches: what it says about
            // the fetch, and anything that goes wrong with it, shows below.
            let why = await WallVideoLink.start(host: wall.host, url: url, sound: sound)
            problem = why
            if why == nil { Taps.landed() } else { Taps.error() }
            busy = false
        }
    }
}

// MARK: - The board: what is on, and the transport

/// Where the video is, a rail to scrub it, and the buttons. Sits in the
/// control centre while the wall's face is "video", and on the page.
struct VideoBoard: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    var another: () -> Void

    @State private var scrub: Double? = nil
    @State private var stopping = false

    private var video: WallVideo? { wall.state.video }
    private var sound: VideoSound { VideoSound.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(video?.title ?? "Nothing on")
                    .font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                    .lineLimit(2)
                Text(line)
                    .font(.ui(13)).foregroundStyle(video?.error != nil ? Ink.signal : Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let v = video, let of = v.duration, of > 1, v.live {
                rail(v, of)
            }
            HStack(spacing: 10) {
                if let v = video, ["playing", "paused"].contains(v.status) {
                    ActionPill(title: v.status == "playing" ? "Pause" : "Play") { toggle(v) }
                }
                if video?.live == true {
                    ActionPill(title: stopping ? "Stopping" : "Stop", filled: false) { stop() }
                        .disabled(stopping)
                }
                Spacer()
                ActionPill(title: video?.live == true ? "Another link" : "Play a link", filled: false) { another() }
            }
        }
        .onChange(of: video?.status) { _, s in readiness(s) }
        .onChange(of: video == nil) { _, gone in if gone { sound.stop() } }
        .onChange(of: wall.state.mode) { _, m in if m != "video" { sound.stop() } }
        .onAppear { readiness(video?.status) }
    }

    private var line: String {
        guard let v = video else { return "Paste a link and the wall plays it." }
        if v.status == "playing", sound.started, !v.phoneClock { return v.words + ". Sound starting." }
        return v.words
    }

    /// The wall says it is ready and it made sound for us: start playing.
    private func readiness(_ status: String?) {
        guard status == "ready", let v = video, v.sound else { return }
        sound.begin(host: wall.host, key: v.url)
    }

    private func toggle(_ v: WallVideo) {
        if sound.started {
            v.status == "playing" ? sound.pause() : sound.resume()
        } else {
            let h = wall.host
            Task { await WallVideoLink.control(host: h, v.status == "playing" ? "pause" : "play") }
        }
        Taps.detent(intensity: 0.4)
    }

    private func stop() {
        stopping = true
        sound.stop()
        let h = wall.host
        Task {
            await WallVideoLink.stop(host: h)
            Taps.commit()
            stopping = false
        }
    }

    private func seek(_ t: Double) {
        if sound.started {
            sound.seek(to: t)
        } else {
            let h = wall.host
            Task { await WallVideoLink.control(host: h, "seek", t: t) }
        }
        Taps.commit()
    }

    private func rail(_ v: WallVideo, _ of: Double) -> some View {
        let at = scrub ?? v.position
        let f = min(1, max(0, at / of))
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.ink.opacity(0.12)).frame(height: 6)
                    Capsule().fill(Ink.ink.opacity(0.18))
                        .frame(width: max(6, geo.size.width * CGFloat(min(1, (v.position + v.buffered) / of))), height: 6)
                    Capsule().fill(accent).frame(width: max(6, geo.size.width * CGFloat(f)), height: 6)
                    Circle().fill(Color.white).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
                        .offset(x: (geo.size.width - 18) * CGFloat(f))
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let t = Double((g.location.x - 9) / max(1, geo.size.width - 18))
                            scrub = of * min(1, max(0, t))
                        }
                        .onEnded { _ in
                            if let t = scrub { seek(t) }
                            scrub = nil
                        }
                )
            }
            .frame(height: 18)
            HStack {
                Text(WallVideo.clock(at)).font(.machine(11)).foregroundStyle(Ink.dim)
                Spacer()
                Text(WallVideo.clock(of)).font(.machine(11)).foregroundStyle(Ink.dim)
            }
        }
    }
}
