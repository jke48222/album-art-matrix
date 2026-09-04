// The one thing this phone can see that no server can.
//
// Apple ships no server-side "what is playing" API, so the account tier the
// Mac can reach lags by about a track. The phone's own system music player
// does not lag, and posting from here is what makes the wall change on the
// beat you press play rather than a minute later. This is the reason a phone
// app exists at all, and it was the largest thing Tessera was missing.
//
// It posts to the wall itself, which runs the now-playing chain and takes
// what arrives here over everything else. A Mac reporter, if one is set,
// gets the same post: optional, for a wall that is not on yet.
//
// Nothing is invented. With no permission or nothing playing, it posts
// nothing at all rather than a guess.

import Foundation
import MediaPlayer
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class NowPlayingPush {
    private(set) var lastSent: Date?
    private(set) var lastTitle: String?
    private(set) var running = false

    /// The wall. Set by WallSession, which owns the address.
    @ObservationIgnored var wallHost = ""
    /// A Mac reporter, optional. Kept for a wall that is not built yet.
    @ObservationIgnored @AppStorage("reporter.host") var host = "" {
        didSet { Self.share(host: host) }
    }

    private var targets: [String] {
        [wallHost, host].filter { !$0.isEmpty }
    }

    /// The broadcast extension (TesseraEars) runs as its own process and
    /// reads the reporter's address from the app group, so it goes there too.
    static func share(host: String) {
        UserDefaults(suiteName: "group.com.jalenedusei.tessera")?.set(host, forKey: "reporter.host")
    }
    /// Holding a silent audio session keeps the observers alive when the app
    /// is backgrounded. It costs a little battery, so it is a choice.
    @ObservationIgnored @AppStorage("reporter.background") var keepAlive = false

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var session: AVAudioSession?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var lastKey = ""
    /// Block-based observers hand back tokens, and removeObserver(self) does
    /// NOT remove them: without keeping these, every restart() stacked
    /// another live pair and each track change posted once per stack.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private var music: MPMusicPlayerController { .systemMusicPlayer }

    func start() {
        guard !targets.isEmpty else { return }
        Self.share(host: host)
        guard !running else { return }
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        running = true
        music.beginGeneratingPlaybackNotificationsIfNeeded()

        observers.append(NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: music, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.post(force: true) } })

        observers.append(NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: music, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.post(force: true) } })

        // The reporter forgets a push after 40 seconds, so a held note has to
        // be repeated or the wall would drop the track mid-song.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.post(force: false) }
                try? await Task.sleep(for: .seconds(15))
            }
        }

        if keepAlive { startKeepAlive() }
        post(force: true)
    }

    func stop() {
        running = false
        timer?.cancel(); timer = nil
        stopKeepAlive()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        music.endGeneratingPlaybackNotifications()
    }

    func restart() { stop(); start() }

    // MARK: - The post

    private func post(force: Bool) {
        guard running, !targets.isEmpty else { return }
        guard let item = music.nowPlayingItem else { return }
        let playing = music.playbackState == .playing
        // Only a playing track is worth sending: the reporter's job is to know
        // what is on, and a paused one is what the last push already said.
        guard playing else { return }

        let key = "\(item.persistentID)"
        guard force || key != lastKey || Date().timeIntervalSince(lastSent ?? .distantPast) > 12 else { return }
        lastKey = key

        var body: [String: Any] = [
            "track": item.title ?? "",
            "artist": item.artist ?? "",
            "album": item.albumTitle ?? "",
            "playing": true,
            "progress_ms": Int(music.currentPlaybackTime * 1000),
        ]
        // The catalog id is what lets the reporter find real artwork rather
        // than guessing from the title.
        let cid = item.playbackStoreID
        if !cid.isEmpty { body["id"] = cid }
        if item.playbackDuration > 0 { body["duration_ms"] = Int(item.playbackDuration * 1000) }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let title = item.title
        for target in targets {
            guard let url = URL(string: "http://\(target)/push") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            req.timeoutInterval = 4
            Task {
                if (try? await URLSession.shared.data(for: req)) != nil {
                    await MainActor.run {
                        self.lastSent = Date()
                        self.lastTitle = title
                    }
                }
            }
        }
    }

    // MARK: - Staying awake

    /// Looped silence, mixed with others, so Music is never interrupted. iOS
    /// suspends a backgrounded app within seconds otherwise and the observers
    /// die with it.
    private func startKeepAlive() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        session = s

        // 0.5s of silence on loop weighs nothing.
        let rate = 44100.0, seconds = 0.5
        let frames = AVAudioFrameCount(rate * seconds)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-silence.caf")
        if let file = try? AVAudioFile(forWriting: url, settings: fmt.settings) {
            try? file.write(from: buf)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.play()
        }
    }

    private func stopKeepAlive() {
        player?.stop(); player = nil
        try? session?.setActive(false)
        session = nil
    }
}

private extension MPMusicPlayerController {
    /// Idempotent: calling begin twice is harmless but this reads better.
    func beginGeneratingPlaybackNotificationsIfNeeded() {
        beginGeneratingPlaybackNotifications()
    }
}

extension NowPlayingPush {
    /// Is the reporter answering at all? nil means there is no address to try.
    /// Setup shows this in words, because "Not answering" is the whole reason
    /// a wall changes late and nobody should have to guess it.
    func probe() async -> Bool? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/nowplaying") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 204
    }
}
