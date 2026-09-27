import SwiftUI
import AVFoundation
import Combine

/// Clip boundaries follow decoded media time, so buffering never consumes a hint.
@MainActor
private final class HeardleClip: ObservableObject {
    enum Phase { case idle, loading, playing, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var position = 0.0
    @Published private(set) var error: String?
    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var timeout: Task<Void, Never>?
    private var report: ((Bool, Double) -> Void)?
    private var reportedPlaying = false
    private var duration = 1.0
    private var generation = UUID()
    private var ownsSession = false

    func play(url: URL, seconds: Double, report: @escaping (Bool, Double) -> Void) {
        stop()
        let id = UUID(); generation = id
        self.report = report; duration = seconds; position = 0; error = nil; phase = .loading
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsSession = true
        } catch {
            fail("Audio could not start. Try again."); return
        }
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, failed else { return }
                    self.fail("This preview could not load. Check your connection and retry.")
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    if status == .playing {
                        self.timeout?.cancel(); self.phase = .playing; self.reportPlayback(true)
                    } else if status == .waitingToPlayAtSpecifiedRate {
                        self.phase = .loading; self.reportPlayback(false); self.startTimeout(id)
                    }
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                let value = CMTimeGetSeconds(time)
                guard value.isFinite else { return }
                self.position = max(0, min(seconds, value))
                if value >= seconds { self.stop(keepPosition: true) }
            }
        }
        notifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.stop(keepPosition: true)
                }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.fail("The preview stopped before the end. Try listening again.")
                }
            },
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.stop(keepPosition: true)
                }
            },
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.stop(keepPosition: true)
                }
            }
        ]
        startTimeout(id)
        player.play()
    }

    func stop(keepPosition: Bool = false) {
        generation = UUID(); timeout?.cancel(); timeout = nil
        reportPlayback(false)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        player?.pause(); player = nil; report = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
        phase = .idle
        if !keepPosition { position = 0 }
    }
    private func reportPlayback(_ playing: Bool) {
        guard reportedPlaying != playing else { return }
        reportedPlaying = playing
        report?(playing, min(duration, max(0, position)))
    }
    private func startTimeout(_ id: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == id, self.phase == .loading else { return }
            self.fail("The preview is taking too long. Check your connection and retry.")
        }
    }
    func fail(_ message: String) {
        stop(keepPosition: true); error = message; phase = .failed
    }
}

struct HeardleBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let playerName: String
    let send: ([String: Any]) -> Void
    let playback: (GameClipOrigin, Bool, Double) -> Void
    @Environment(\.gameSessionID) private var session
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.gameCanInteract) private var canInteract
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var clip = HeardleClip()
    @State private var draft = ""
    @State private var submitted: String?
    @State private var submittedCount = 0
    @FocusState private var writing: Bool
    private let honey = Color(hex: 0xDCB946)
    private var seconds: Int { min(16, max(1, game.state["seconds"].int ?? 1)) }
    private var step: Int { min(5, max(0, game.state["step"].int ?? 0)) }
    private var tries: [JSONValue] { game.state["tries"].array }
    private var myTurn: Bool { game.state["turn"].string == playerName }
    private var isActive: Bool { clip.phase == .loading || clip.phase == .playing }
    private var canGuess: Bool { !game.over && myTurn && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.over ? (game.won ? "Found it" : "The song") : "Name the song").font(.display(29)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 8)
                    Text("\(min(6, tries.count + (game.over ? 0 : 1)))/6").font(.machine(13)).foregroundStyle(honey)
                }.accessibilityElement(children: .combine)
            }
            GameArtworkCanvas(game: game).frame(maxWidth: typeSize.isAccessibilitySize ? 170 : 230).frame(maxWidth: .infinity)
            if game.over { result }
            else {
                Button(action: listen) {
                    HStack(spacing: 10) {
                        if clip.phase == .loading { ProgressView().tint(Ink.ground) }
                        else { Image(systemName: isActive ? "stop.fill" : clip.phase == .failed ? "arrow.clockwise" : "play.fill") }
                        Text(clip.phase == .loading ? "Loading. Tap to cancel" : clip.phase == .playing ? "Stop listening" : clip.phase == .failed ? "Retry preview" : "Listen for \(seconds) sec")
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 4)
                }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground)
                    .background(honey, in: RoundedRectangle(cornerRadius: 16)).disabled(!myTurn)
                    .accessibilityLabel(isActive ? "Stop listening" : "Play \(seconds) second\(seconds == 1 ? "" : "s")")
                    .accessibilityHint("Plays the first \(seconds) seconds of the song")
                if isActive {
                    ProgressView(value: clip.position, total: Double(seconds)).tint(honey)
                        .accessibilityLabel("Preview played").accessibilityValue("\(clip.position.formatted(.number.precision(.fractionLength(1)))) of \(seconds) seconds")
                }
                if let error = clip.error, clip.phase == .failed {
                    Label(error, systemImage: "exclamationmark.circle").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                composer
                HStack(alignment: .firstTextBaseline) {
                    Button { clip.stop(); send(["skip": true, "step": step]) } label: {
                        Label(step == 5 ? "Reveal song" : typeSize.isAccessibilitySize ? "Skip" : "Skip to \([1, 2, 4, 7, 11, 16][min(5, step + 1)]) sec", systemImage: "forward.end")
                            .font(.ui(14, .semibold)).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(honey).disabled(!myTurn)
                        .accessibilityHint(step == 5 ? "Reveals the song and ends this round" : "Unlocks the first \([1, 2, 4, 7, 11, 16][min(5, step + 1)]) seconds")
                    Spacer(minLength: 8)
                    Text(myTurn ? "Your turn" : "\(game.state["turn"].string ?? "Next player")’s turn")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !tries.isEmpty { history }
        }
        .onChange(of: tries.count) { _, count in
            guard let submitted, count > submittedCount,
                  tries.suffix(count - submittedCount).contains(where: { $0["text"].string == submitted && $0["who"].string == playerName }) else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { draft = "" }
            self.submitted = nil
        }
        .onChange(of: step) { _, _ in clip.stop() }
        .onChange(of: myTurn) { _, _ in clip.stop() }
        .onChange(of: game.over) { _, over in if over { clip.stop(); writing = false } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clip.stop() } }
        .onChange(of: wall.host) { _, _ in clip.stop() }
        .onChange(of: canInteract) { _, allowed in if !allowed { clip.stop() } }
        .onDisappear { clip.stop() }
    }
    private var composer: some View {
        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
            TextField("Song title", text: $draft, axis: .vertical).font(.ui(17)).lineLimit(1...3)
                .autocorrectionDisabled().textInputAutocapitalization(.words).submitLabel(.send).focused($writing)
                .onSubmit(submit).onChange(of: draft) { _, new in if new.count > 120 { draft = String(new.prefix(120)) } }
                .accessibilityLabel("Song title").disabled(!myTurn)
            Button(action: submit) {
                if typeSize.isAccessibilitySize { Label("Send guess", systemImage: "arrow.up").font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                else { Image(systemName: "arrow.up").font(.ui(18, .semibold)).frame(width: 44, height: 44) }
            }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground)
                .background(canGuess ? honey : honey.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!canGuess).accessibilityLabel("Send guess")
        }.padding(12).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tries.enumerated()), id: \.offset) { index, attempt in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: attempt["hit"].bool == true ? "checkmark.circle.fill" : attempt["skipped"].bool == true ? "forward.end" : "xmark.circle")
                        .foregroundStyle(attempt["hit"].bool == true ? Color(hex: 0xA6DFB9) : Ink.dim).accessibilityHidden(true)
                    Text(attempt["skipped"].bool == true ? "Skipped" : attempt["text"].string ?? "").font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("\(index + 1)").font(.machine(12)).foregroundStyle(Ink.dim)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Attempt \(index + 1), \(attempt["skipped"].bool == true ? "skipped" : attempt["text"].string ?? ""), \(attempt["hit"].bool == true ? "correct" : "")")
            }
        }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(game.won ? "FOUND IN \(tries.count)" : "THE ANSWER", systemImage: game.won ? "checkmark.circle" : "music.note")
                .font(.machine(11)).foregroundStyle(honey)
            Text(game.state["answer"]["title"].string ?? "Song revealed").font(typeSize.isAccessibilitySize ? .ui(22, .semibold) : .display(30)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(game.state["answer"]["artist"].string ?? "").font(.ui(17)).foregroundStyle(Ink.dim)
        }
    }
    private func listen() {
        guard myTurn, canInteract else { return }
        if isActive { clip.stop(); return }
        guard let url = URL(string: game.state["preview"].string ?? ""), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { clip.fail("This song has no usable preview. Try another round."); return }
        writing = false
        guard let session else { return }
        let origin = GameClipOrigin(host: wall.host, session: session, player: playerName, step: step)
        clip.play(url: url, seconds: Double(seconds)) { playing, position in
            playback(origin, playing, position)
        }
    }
    private func submit() {
        guard canGuess else { return }
        let answer = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = answer; submittedCount = tries.count
        clip.stop(); send(["guess": answer, "step": step])
    }
}
