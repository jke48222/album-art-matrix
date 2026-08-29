// Now-playing pusher.
//
// Reads the system Music player (public API — this is the one thing an iOS
// app can see that no server can) and POSTs every track/state change to the
// Mac reporter's /push endpoint, plus a 15s heartbeat while playing so the
// reporter's 40s TTL never lapses mid-song.
//
// Background survival: iOS suspends apps within seconds of backgrounding,
// which would kill the observers. With "Background pushing" on, we hold an
// AVAudioSession playing looped silence, flagged .mixWithOthers so Music is
// untouched. Sideload-only trick (App Review dislikes it); costs a little
// battery, which is why it's a toggle.
import AVFoundation
import Combine
import Foundation
import MediaPlayer
import SwiftUI

final class Pusher: ObservableObject {
    @Published var trackTitle: String = "-"
    @Published var artist: String = ""
    @Published var isPlaying = false
    @Published var lastPush: String = "never"
    @Published var authorized = false
    @Published var artwork: UIImage? = nil   // current sleeve, for the preview
    @Published var progressMs: Int = 0       // track position at last push
    @Published var durationMs: Int = 0
    @Published var progressDate = Date()     // when progressMs was captured

    @AppStorage("reporterHost") var reporterHost = "Jalens-MacBook-Pro.local:8787"
    @AppStorage("backgroundPush") var backgroundPush = true {
        didSet { backgroundPush ? startKeepAlive() : stopKeepAlive() }
    }

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var heartbeat: Timer?
    private var silence: AVAudioPlayer?

    init() {
        // Don't prompt at launch — the first-run screen owns that moment.
        if MPMediaLibrary.authorizationStatus() == .authorized {
            authorized = true
            start()
        }
    }

    func requestAccess() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.authorized = status == .authorized
                if status == .authorized { self?.start() }
            }
        }
    }

    private func start() {
        player.beginGeneratingPlaybackNotifications()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                       object: player, queue: .main) { [weak self] _ in self?.push() }
        nc.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                       object: player, queue: .main) { [weak self] _ in self?.push() }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            if self?.player.playbackState == .playing { self?.push() }
        }
        if backgroundPush { startKeepAlive() }
        push()
    }

    func push() {
        let item = player.nowPlayingItem
        let playing = player.playbackState == .playing
        let art = item?.artwork?.image(at: CGSize(width: 256, height: 256))
        let pos = Int(player.currentPlaybackTime * 1000)
        DispatchQueue.main.async {
            self.trackTitle = item?.title ?? "-"
            self.artist = item?.artist ?? ""
            self.isPlaying = playing
            self.artwork = art
            self.progressMs = max(0, pos)
            self.durationMs = Int((item?.playbackDuration ?? 0) * 1000)
            self.progressDate = Date()
            LiveActivityManager.sync(
                title: item?.title ?? "-", artist: item?.artist ?? "",
                playing: playing, mode: LiveActivityManager.lastMode)
            SharedSnapshot.write(title: item?.title, artist: item?.artist,
                                 frame: art?.led64())
        }
        guard let item, let url = URL(string: "http://\(reporterHost)/push")
        else { return }

        var body: [String: Any] = [
            "track": item.title ?? "?",
            "artist": item.artist ?? "?",
            "album": item.albumTitle ?? "?",
            "playing": playing,
            "progress_ms": Int(player.currentPlaybackTime * 1000),
            "duration_ms": Int(item.playbackDuration * 1000),
        ]
        if item.playbackStoreID != "0" { body["id"] = item.playbackStoreID }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                let f = DateFormatter(); f.timeStyle = .medium
                let ok = err == nil && resp != nil
                self?.lastPush = ok ? f.string(from: Date()) : "unreachable"
            }
        }.resume()
    }

    // ---- silent-audio keepalive ----------------------------------------
    private func startKeepAlive() {
        guard silence == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        silence = try? AVAudioPlayer(data: Self.silentWav())
        silence?.numberOfLoops = -1
        silence?.volume = 0
        silence?.play()
    }

    private func stopKeepAlive() {
        silence?.stop()
        silence = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 1s of 8kHz mono 16-bit silence, WAV-wrapped, built in memory.
    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000, samples = 8000
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
