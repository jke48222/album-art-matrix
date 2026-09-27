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
    private(set) var lastWallReceipt: MusicPushReceipt?
    private(set) var lastWallError: String?

    /// The wall. Set by WallSession, which owns the address.
    @ObservationIgnored var wallHost = ""
    /// A Mac reporter, optional. Kept for a wall that is not built yet.
    @ObservationIgnored @AppStorage("reporter.host") var host = "" {
        didSet { Self.share(host: host) }
    }

    @ObservationIgnored var onSample: (() -> Void)?
    @ObservationIgnored private var phoneOnly = false

    /// An explicit stand-in is a local session, even if its saved wall address
    /// still answers. Restarting after a permission change must respect it too.
    func setPhoneOnly(_ enabled: Bool) {
        guard phoneOnly != enabled else { return }
        phoneOnly = enabled
        stop()
        if !enabled { start() }
    }
    @ObservationIgnored private let pushSession = UUID().uuidString
    @ObservationIgnored private var sequence = 0
    private var sample: LocalPlaybackSample?
    @ObservationIgnored private var deliveryGate = MusicPushDeliveryGate()
    @ObservationIgnored private var sends: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSends: [String: PushPayload] = [:]
    private struct PushPayload {
        let data: Data
        let title: String
        let artist: String
        let playing: Bool
        let sequence: Int
    }

    func refine(_ state: inout WallState) { sample?.apply(to: &state) }

    private var targets: [String] {
        guard !phoneOnly else { return [] }
        return Array(Set([wallHost, host].filter { !$0.isEmpty })).sorted()
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
                try? await Task.sleep(for: .seconds(5))
            }
        }

        if keepAlive { startKeepAlive() }
        post(force: true)
    }

    func stop() {
        let wasRunning = running
        running = false
        deliveryGate.reset()
        sends.values.forEach { $0.cancel() }; sends.removeAll(); pendingSends.removeAll()
        sample = nil; lastKey = ""
        lastSent = nil; lastTitle = nil; lastWallReceipt = nil; lastWallError = nil
        timer?.cancel(); timer = nil
        stopKeepAlive()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if wasRunning { music.endGeneratingPlaybackNotifications() }
    }

    func restart() { stop(); start() }

    // MARK: - The post

    private func post(force: Bool) {
        guard running, !targets.isEmpty else { return }
        guard MPMediaLibrary.authorizationStatus() == .authorized else { stop(); return }
        guard let item = music.nowPlayingItem else {
            sample = nil
            if !lastKey.isEmpty {
                lastKey = ""; sequence &+= 1
                if let data = try? JSONSerialization.data(withJSONObject: ["session": pushSession, "sequence": sequence, "track": "", "playing": false]) {
                    enqueue(PushPayload(data: data, title: "", artist: "", playing: false, sequence: sequence))
                }
            }
            return
        }
        let playing = music.playbackState == .playing
        let position = music.currentPlaybackTime
        sample = LocalPlaybackSample(title: item.title ?? "", artist: item.artist ?? "",
                                     position: position, duration: item.playbackDuration,
                                     playing: playing, observed: Date())
        onSample?()
        // A pause is news. It used to be swallowed here, so the wall kept the
        // last "playing" for its whole forty seconds and the room's arm went
        // on tracking a song that had stopped.
        let key = "\(item.persistentID)|\(item.playbackStoreID)|\(item.title ?? "")|\(item.artist ?? "")|\(playing)"
        guard force || key != lastKey || Date().timeIntervalSince(lastSent ?? .distantPast) > 4 else { return }
        lastKey = key

        sequence &+= 1
        var body: [String: Any] = [
            "session": pushSession, "sequence": sequence,
            "track": item.title ?? "",
            "artist": item.artist ?? "",
            "album": item.albumTitle ?? "",
            "playing": playing,
        ]
        // The system player can briefly return an unknown position while its
        // queue changes. Do not convert NaN/infinity to Int or send a made-up
        // zero that would look like a seek on the wall.
        if position.isFinite, position >= 0, position < Double(Int.max / 1000) {
            body["progress_ms"] = Int(position * 1000)
        }
        // The catalog id is what lets the reporter find real artwork rather
        // than guessing from the title.
        let cid = item.playbackStoreID
        if !cid.isEmpty { body["id"] = cid }
        let duration = item.playbackDuration
        if duration.isFinite, duration > 0, duration < Double(Int.max / 1000) {
            body["duration_ms"] = Int(duration * 1000)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        enqueue(PushPayload(data: data, title: item.title ?? "", artist: item.artist ?? "", playing: playing, sequence: sequence))
    }

    private func enqueue(_ payload: PushPayload) {
        let generation = deliveryGate.generation
        for target in targets {
            pendingSends[target] = payload
            guard sends[target] == nil else { continue }
            sends[target] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, self.running, generation == self.deliveryGate.generation,
                      let next = self.pendingSends.removeValue(forKey: target) {
                    guard self.targets.contains(target), let url = URL(string: "http://\(target)/push") else { break }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = next.data
                    request.timeoutInterval = 4
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        guard !Task.isCancelled, self.running,
                              self.deliveryGate.accept(generation: generation, target: target, sequence: next.sequence, currentTargets: self.targets) else { break }
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                            if target == self.wallHost { self.lastWallError = "The wall could not accept this music update." }
                            continue
                        }
                        let now = Date()
                        self.lastSent = now; self.lastTitle = next.title
                        if target == self.wallHost {
                            self.lastWallReceipt = MusicPushReceipt(host: target, title: next.title, artist: next.artist, playing: next.playing, received: now)
                            self.lastWallError = nil
                        }
                    } catch {
                        guard !Task.isCancelled, self.running, generation == self.deliveryGate.generation,
                              self.targets.contains(target) else { break }
                        if target == self.wallHost { self.lastWallError = "The wall hasn’t received this music update. Try again when it’s reachable." }
                    }
                }
                // A stopped sender must never clear a newer sender for the same host.
                if generation == self.deliveryGate.generation { self.sends[target] = nil }
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
