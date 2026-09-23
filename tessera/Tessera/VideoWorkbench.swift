import PhotosUI
import SwiftUI

/// The single video destination inside the face menu. Crop is a step in import,
/// not a second copy of these playback controls.
struct VideoWorkbench: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    var accent: Color = Ink.tile
    var ink: GlassInk = .dark
    @State private var link = ""
    @State private var sound = true
    @State private var loop = false
    @State private var selected: PhotosPickerItem?
    @State private var framing: VideoFraming?
    @State private var work: (String, Double)?
    @State private var problem: String?
    @State private var accepted = false
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var scrub: Double?
    @State private var controlling = false
    @State private var sourceFile: URL?
    @State private var staged: StagedVideo?
    @FocusState private var linkFocused: Bool

    private var video: WallVideo? { wall.state.video }
    private var busy: Bool { work != nil || controlling }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Picture in motion.").font(.display(typeSize.isAccessibilitySize ? 17 : 25)).foregroundStyle(ink.ink)
                Spacer()
                Image(systemName: "film").font(.system(size: 19, weight: .medium)).foregroundStyle(accent)
            }
            if let video, video.live {
                livePreview(video)
                playback(video)
            } else if let staged {
                stagedPreview(staged)
            } else {
                entry
            }
            if let work { progress(work) }
            if accepted, work == nil, video?.live != true {
                Label("The wall accepted your video. Preparing playback…", systemImage: "checkmark.circle")
                    .font(.ui(13)).foregroundStyle(accent)
            }
            if let issue = problem ?? video?.error ?? VideoSound.shared.error {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.ui(14)).foregroundStyle(Ink.signal).fixedSize(horizontal: false, vertical: true)
            }
            if !wall.link.isLive {
                Label("Connect your wall to play a video. You can still choose and frame one here.", systemImage: "wifi.slash")
                    .font(.ui(13)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selected) { _, item in
            guard let item else { return }
            selected = nil; begin { await load(item) }
        }
        .fullScreenCover(item: $framing) { job in
            Framing(source: job.frames, accent: accent, onCancel: { framing = nil; if staged == nil { removeUnusedSource() } }, onUse: { _ in },
                    onCrop: { crop in
                        let first = job.frames[0]
                        let rect = crop.normalizedRect(in: CGSize(width: first.width, height: first.height))
                        framing = nil
                        staged = StagedVideo(file: job.file, title: job.title, crop: rect, preview: job.frames[0])
                        if wall.link.isLive { begin { await send(file: job.file, title: job.title, crop: rect) } }
                    }, commitTitle: wall.link.isLive ? "Play on wall" : "Keep framing")
        }
        .task { await takeHandoff() }
        .onDisappear {
            // A presented framing step also causes disappearance; its source must survive.
            if framing == nil { operation?.cancel(); removeUnusedSource() }
        }
    }


    private func stagedPreview(_ staged: StagedVideo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let image = staged.preview
            let rect = CGRect(x: staged.crop.minX * CGFloat(image.width), y: staged.crop.minY * CGFloat(image.height),
                              width: staged.crop.width * CGFloat(image.width), height: staged.crop.height * CGFloat(image.height))
            if let pixels = Framing.sample(image, rect: rect), let rendered = MediaRaster.image(pixels) {
                Image(decorative: rendered, scale: 1).resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("Framed video preview, not yet playing on wall")
            }
            Text("Your frame is ready.").font(.ui(19, .semibold)).foregroundStyle(ink.ink)
            Text("Phone preview · the entire video uses this framing.").font(.ui(12)).foregroundStyle(ink.dim)
            Button { begin { await send(file: staged.file, title: staged.title, crop: staged.crop) } } label: {
                Label("Play on wall", systemImage: "play.fill").font(.ui(15, .semibold))
                    .foregroundStyle(Ink.ground).frame(maxWidth: .infinity).frame(minHeight: 50)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(PressStyle()).disabled(busy || !wall.link.isLive)
            Button("Choose another video") { self.staged = nil; removeUnusedSource(); problem = nil }
                .font(.ui(14)).foregroundStyle(ink.dim).frame(minHeight: 44).disabled(busy)
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A film, a memory, a little movement.")
                .font(.ui(15)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
            PhotosPicker(selection: $selected, matching: .videos, preferredItemEncoding: .current) {
                HStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 23, weight: .regular))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose a video").font(.ui(16, .semibold))
                        Text("Frame it once. Play the whole film.").font(.ui(12)).foregroundStyle(ink.dim)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
                }.foregroundStyle(ink.ink).padding(18)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(PressStyle()).disabled(busy)

            VStack(alignment: .leading, spacing: 8) {
                Text("Or use a video link").font(.ui(13, .medium)).foregroundStyle(ink.dim)
                HStack(spacing: 10) {
                    TextField("https://…", text: $link)
                        .font(.ui(15)).foregroundStyle(ink.ink).keyboardType(.URL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($linkFocused).submitLabel(.go).onSubmit(startLink)
                        .accessibilityLabel("Video URL")
                    if !link.isEmpty {
                        Button { link = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }.foregroundStyle(ink.dim).accessibilityLabel("Clear video URL")
                    }
                }.padding(.leading, 14).frame(minHeight: 50)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: 12))
                Text("YouTube or a direct video link. Links use a centered square frame.")
                    .font(.ui(12)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                Toggle(isOn: $sound) {
                    Label("Sound on this iPhone", systemImage: sound ? "speaker.wave.2" : "speaker.slash")
                        .font(.ui(14))
                }.tint(accent).frame(minHeight: 48)
                Toggle(isOn: $loop) {
                    Label("Loop linked video", systemImage: "repeat").font(.ui(14))
                }.tint(accent).frame(minHeight: 48)
            }.foregroundStyle(ink.ink).disabled(busy)
            Button(action: startLink) {
                Label("Play link on wall", systemImage: "play.fill")
                    .font(.ui(15, .semibold)).foregroundStyle(Ink.ground)
                    .frame(maxWidth: .infinity).frame(minHeight: 50)
                    .background(accent.opacity(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1),
                                in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(PressStyle()).disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func livePreview(_ video: WallVideo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if wall.state.mode == "video", let frame = wall.frame, let image = MediaRaster.image([UInt8](frame)) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("Current video frame from your wall")
            }
            HStack {
                Circle().fill(video.status == "paused" ? ink.dim : accent).frame(width: 5, height: 5)
                Text(video.status == "paused" ? "PAUSED ON WALL" : video.status == "fetching" ? "PREPARING ON WALL" : "LIVE WALL")
                    .font(.machine(10)).tracking(1)
                Spacer()
                Text(video.phoneClock ? "IPHONE SOUND" : "SILENT").font(.machine(9)).foregroundStyle(ink.dim)
            }.foregroundStyle(ink.ink)
        }
    }

    private func playback(_ video: WallVideo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(video.title ?? "Your video").font(.ui(21, .semibold)).foregroundStyle(ink.ink).fixedSize(horizontal: false, vertical: true)
            if let author = video.author, !author.isEmpty { Text(author).font(.ui(13)).foregroundStyle(ink.dim) }
            if let duration = video.duration, duration.isFinite, duration > 0 {
                let position = min(duration, max(0, scrub ?? (VideoSound.shared.started ? VideoSound.shared.time : video.position)))
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { position }, set: { scrub = $0 }), in: 0...duration) { editing in
                        if !editing, let at = scrub { seek(at); scrub = nil }
                    }.tint(accent).disabled(busy).accessibilityLabel("Video playhead")
                    HStack {
                        Text(WallVideo.clock(position))
                        Spacer()
                        Text("−" + WallVideo.clock(max(0, duration - position)))
                    }.font(.machine(12)).monospacedDigit().foregroundStyle(ink.dim)
                }
            }
            if ["fetching", "ready"].contains(video.status) {
                HStack(spacing: 10) { ProgressView().tint(accent); Text(video.words).font(.ui(13)).foregroundStyle(ink.dim) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { transportButtons(video) }
                VStack(spacing: 10) { transportButtons(video) }
            }
            if video.sound, !VideoSound.shared.started, video.soundReady {
                Button { VideoSound.shared.join(video, host: wall.host) } label: {
                    Label("Play sound on this iPhone", systemImage: "speaker.wave.2").font(.ui(14, .medium)).frame(minHeight: 44)
                }.foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder private func transportButtons(_ video: WallVideo) -> some View {
        if ["playing", "paused"].contains(video.status) {
            let playing = VideoSound.shared.started ? VideoSound.shared.playing : video.status == "playing"
            Button {
                if VideoSound.shared.started { playing ? VideoSound.shared.pause() : VideoSound.shared.resume() }
                else { control(playing ? "pause" : "play") }
            } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                    .font(.ui(14, .semibold)).foregroundStyle(Ink.ground).frame(maxWidth: .infinity).frame(minHeight: 48)
                    .background(accent, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(PressStyle()).disabled(busy)
        }
        Button {
            begin {
                controlling = true; defer { controlling = false }
                let result = await WallVideoLink.post(host: wall.host, "/video/stop", [:])
                if let result, result["error"] == nil { VideoSound.shared.stop(); accepted = false; Taps.landed() }
                else { problem = result?["error"] as? String ?? "The wall did not answer. Try stopping again." }
            }
        } label: {
            Label("Stop video", systemImage: "stop.fill").font(.ui(14, .medium))
                .foregroundStyle(ink.ink).frame(maxWidth: .infinity).frame(minHeight: 48)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(PressStyle()).disabled(busy)
    }

    private func progress(_ state: (String, Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.0).font(.ui(14, .medium)).foregroundStyle(ink.ink)
                Spacer()
                Text("\(Int(min(1, max(0, state.1)) * 100))%")
                    .font(.machine(12)).foregroundStyle(accent).monospacedDigit()
            }
            ProgressView(value: state.1).tint(accent).accessibilityLabel(state.0)
            Button("Cancel") { operation?.cancel(); work = nil; requestID = UUID(); if staged == nil { removeUnusedSource() } }
                .font(.ui(13, .medium)).foregroundStyle(ink.dim).frame(minHeight: 44)
        }.padding(16).background(ink.fill, in: RoundedRectangle(cornerRadius: 14))
    }

    private func begin(_ action: @escaping @MainActor () async -> Void) {
        operation?.cancel(); problem = nil; requestID = UUID()
        operation = Task { @MainActor in await action() }
    }

    private func startLink() {
        guard !busy else { return }
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            problem = "Enter a complete http or https video link."; return
        }
        guard wall.link.isLive else { problem = "Connect your wall before playing the link."; return }
        linkFocused = false
        let host = wall.host, selectedSound = sound, selectedLoop = loop
        begin {
            let id = requestID
            work = ("Handing the link to your wall", 0)
            let issue = await WallVideoLink.start(host: host, url: raw, sound: selectedSound, loop: selectedLoop)
            guard !Task.isCancelled, requestID == id else { return }
            work = nil
            guard wall.host == host else { problem = "Your wall connection changed. Check the previous wall before sending again."; return }
            problem = issue; accepted = issue == nil
            if issue == nil { VideoSound.shared.stop(); link = ""; Taps.landed() } else { Taps.error() }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        work = ("Opening your video", 0)
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else { throw Clip.Failure.unreadable }
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: movie.url); return }
            await prepare(file: movie.url, title: "From your library")
        } catch { if !Task.isCancelled { work = nil; problem = error.localizedDescription } }
    }

    private func prepare(file: URL, title: String) async {
        let id = requestID
        removeUnusedSource()
        sourceFile = file
        do {
            let frames = try await Clip.decode(from: file) { value in
                guard requestID == id else { return }
                work = ("Preparing a framing preview", value)
            }
            try Task.checkCancellation()
            work = nil; framing = VideoFraming(file: file, title: title, frames: frames)
        } catch {
            removeUnusedSource()
            if !Task.isCancelled { work = nil; problem = error.localizedDescription }
        }
    }

    private func send(file: URL, title: String, crop: CGRect) async {
        guard wall.link.isLive else { problem = "Reconnect your wall, then play this framed video."; return }
        guard !VideoHandoff.inProgress else { problem = "Another video is already being sent."; return }
        VideoHandoff.inProgress = true
        defer { VideoHandoff.inProgress = false }
        let host = wall.host, id = requestID, selectedSound = sound
        do {
            _ = try await VideoHandoff.send(file: file, title: title, host: host, sound: selectedSound, crop: crop) { words, value in
                Task { @MainActor in
                    guard requestID == id, !Task.isCancelled else { return }
                    work = (words, value)
                }
            }
            guard !Task.isCancelled, requestID == id else { return }
            work = nil
            guard wall.host == host else {
                problem = "The video was accepted by your previous wall. Reconnect to that wall to control it."
                return
            }
            accepted = true
            VideoSound.shared.stop()
            staged = nil
            if !selectedSound { removeUnusedSource() }
            Taps.landed()
        } catch {
            if !Task.isCancelled, requestID == id { work = nil; problem = error.localizedDescription; Taps.error() }
            // Keep the staged source and crop available for retry.
        }
    }

    private func seek(_ time: Double) {
        if VideoSound.shared.started { VideoSound.shared.seek(to: time) }
        else { control("seek", time: time) }
    }

    private func control(_ action: String, time: Double? = nil) {
        begin {
            controlling = true; defer { controlling = false }
            var body: [String: Any] = ["action": action]
            if let time { body["t"] = time }
            let response = await WallVideoLink.post(host: wall.host, "/video/control", body)
            problem = response?["error"] as? String ?? (response == nil ? "The wall did not answer. Try again." : nil)
            if problem == nil { Taps.detent() }
        }
    }

    private func removeUnusedSource() {
        guard let sourceFile, VideoHandoff.localSound?.url != sourceFile else { return }
        if VideoHandoff.ownsSource(sourceFile) { try? FileManager.default.removeItem(at: sourceFile) }
        self.sourceFile = nil
    }

    private func takeHandoff() async {
        guard let pending = VideoHandoff.arrived, pending.kind == "file", let path = pending.path else { return }
        VideoHandoff.arrived = nil
        let original = URL(fileURLWithPath: path)
        let granted = original.startAccessingSecurityScopedResource()
        defer { if granted { original.stopAccessingSecurityScopedResource() } }
        do {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: original, to: copy)
            await prepare(file: copy, title: pending.title ?? "Shared video")
        } catch { problem = error.localizedDescription }
    }
}

private struct VideoFraming: Identifiable {
    let id = UUID()
    let file: URL
    let title: String
    let frames: [CGImage]
}

private struct StagedVideo {
    let file: URL
    let title: String
    let crop: CGRect
    let preview: CGImage
}
