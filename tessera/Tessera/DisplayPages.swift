import SwiftUI

/// Images from the production renderer, owned by the lifetime of the view's task.
@MainActor @Observable
final class WallImages {
    private(set) var shots: [String: UIImage] = [:]
    private(set) var problem: String?
    private(set) var loading = true

    func watch(host: String, path: String, interval: Double = 2) async {
        shots = [:]; problem = nil; loading = true
        while !Task.isCancelled {
            guard let url = URL(string: "http://\(host)\(path)"), !host.isEmpty else {
                loading = false; problem = "Connect to your wall to see these previews."; return
            }
            var request = URLRequest(url: url); request.timeoutInterval = 4
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    throw URLError(.badServerResponse)
                }
                let decoded = object.compactMapValues { value -> UIImage? in
                    guard let bytes = Data(base64Encoded: value), Panel.square(bytes.count) != nil else { return nil }
                    return FinishSwatch.bitmap([UInt8](bytes))
                }
                guard !decoded.isEmpty else { throw URLError(.cannotDecodeContentData) }
                shots = decoded; problem = nil; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                problem = shots.isEmpty ? "Previews unavailable. Reconnecting…" : "Last received previews · reconnecting…"
                loading = false
            }
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
        }
    }
}

enum DisplayDetail: String, Identifiable {
    case lyrics, nine, finishes, lamp
    var id: String { rawValue }
    var title: String { switch self { case .lyrics: "Lyrics"; case .nine: "Nine"; case .finishes: "Finishes"; case .lamp: "Lamp" } }
    var eyebrow: String { switch self { case .lyrics: "EVERY WORD, IN ITS MOMENT"; case .nine: "YOUR RECENT ROTATION"; case .finishes: "THREE WAYS TO WEAR IT"; case .lamp: "COLOUR THAT FILLS THE ROOM" } }
    var mode: String? { switch self { case .lyrics: "lyrics"; case .nine: "nine"; case .lamp: "ambient"; case .finishes: nil } }
}

private struct ReadingLine: Decodable {
    struct Word: Decodable { let at: Double; let text: String }
    let at: Double
    let text: String
    let words: [Word]
}
private struct ReadingSheet: Decodable {
    let state: String
    let lines: [ReadingLine]
}
private struct RotationCover: Identifiable {
    let id: String
    let title: String
    let artist: String
}

struct DisplayPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let detail: DisplayDetail
    let accent: Color
    var embedded = false
    @State private var images = WallImages()
    @State private var sheet: ReadingSheet?
    @State private var covers: [RotationCover] = []
    @State private var problem: String?
    @State private var loaded = false
    @State private var offset = 0.2
    @State private var speed = 1.0
    @State private var retry = 0
    @State private var editing = false
    @AppStorage("lyrics.nudge") private var lyricsNudge = 0.0
    private let finishes = [("clean", "Clean", "Every colour, left intact."), ("dither", "Dither", "Fine grain. Softer transitions."), ("poster", "Poster", "Bold blocks. A graphic silhouette.")]
    private let effects = [("solid", "Solid"), ("breathe", "Breathe"), ("pulse", "Pulse"), ("rainbow", "Spectrum"), ("gradient", "Gradient"), ("plaid", "Plaid"), ("weave", "Weave"), ("deco", "Deco"), ("snake", "Snake")]
    private var ready: Bool { wall.link.isLive || wall.link.isStandIn }
    private var imagePath: String { detail == .lamp ? "/ambient/previews" : "/finishes" }
    private var feedKey: String { "\(wall.host)|\(detail.rawValue)|\(retry)" }

    var body: some View {
        Group {
            if embedded { content }
            else {
                NavigationStack {
                    ScrollView { content.padding(24) }.background(Ink.ground)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
             .task(id: "\(feedKey)|\(wall.state.title ?? "")|\(wall.state.artist ?? "")|\(scenePhase)") {
                if scenePhase == .active && (detail == .lyrics || detail == .nine) { await watchContent() }
            }
            .task(id: "\(feedKey)|\(wall.state.mode)|\(wall.state.color)|\(wall.state.color2)|\(wall.state.matchArt)|\(scenePhase)") {
                if scenePhase == .active && (detail == .finishes || detail == .lamp) { await images.watch(host: wall.host, path: imagePath, interval: detail == .lamp ? 5 : 0.6) }
            }
            .onAppear { offset = wall.state.lyricOffset; speed = wall.state.speed }
            .onChange(of: wall.state.lyricOffset) { _, value in if !editing { offset = value } }
            .onChange(of: wall.state.speed) { _, value in if !editing { speed = value } }
    }

    private var content: some View {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(detail.eyebrow).font(.machine(8)).tracking(1.2).foregroundStyle(accent.toned(forDark: true))
                        Text(detail.title).font(.display(embedded ? 28 : typeSize.isAccessibilitySize ? 20 : 48)).foregroundStyle(Ink.ink)
                    }
                    if !embedded { if detail == .finishes { finishHero } else { liveHero } }
                    switch detail {
                    case .lyrics: reading; timing
                    case .nine: rotation
                    case .finishes: finishChoices
                    case .lamp: lampChoices; lampControls
                    }
                    if let mode = detail.mode, wall.state.mode != mode {
                        Button { wall.send(["mode": mode]); Taps.commit() } label: {
                            Label("Put \(detail.title) on the wall", systemImage: "arrow.up.right")
                                .font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundStyle(Ink.ground).background(accent.toned(forDark: true), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(PressStyle()).disabled(!ready)
                    }
                }
    }

    private var liveHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color(hex: 0x101513)
                if let data = wall.frame, let bitmap = FinishSwatch.bitmap([UInt8](data)), wall.state.mode != "off" {
                    Image(uiImage: bitmap).resizable().interpolation(.none).scaledToFit()
                } else {
                    ContentUnavailableView(wall.state.mode == "off" ? "Wall at rest" : "Waiting for your wall", systemImage: "square.grid.3x3", description: Text("Your live artwork appears here when the wall is connected."))
                }
            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                Label(wall.link.isLive ? "Live wall" : wall.link.isStandIn ? "Preview on this phone" : "Last received frame", systemImage: wall.link.isLive ? "dot.radiowaves.left.and.right" : "wifi.slash")
                Spacer()
                if wall.state.mode != detail.mode { Text("\(wall.state.mode.capitalized) face") }
                else { Text("\(Panel.side) × \(Panel.side)") }
            }.font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }

    private var finishHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview(images.shots[wall.state.finish], label: "Finish preview")
            HStack {
                Text("\(wall.state.finish.capitalized) · rendered by your wall")
                Spacer()
                Image(systemName: "viewfinder")
            }.font(.ui(12)).foregroundStyle(Ink.dim)
            imageStatus
        }
    }

    private func preview(_ image: UIImage?, label: String) -> some View {
        ZStack {
            Color(hex: 0x151b19)
            if let image { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() }
            else if images.loading { ProgressView().tint(accent) }
            else { Image(systemName: "photo.badge.exclamationmark").font(.system(size: 28)).foregroundStyle(Ink.dim) }
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(label)
    }

    @ViewBuilder private var imageStatus: some View {
        if let problem = images.problem { Text(problem).font(.ui(13)).foregroundStyle(Ink.dim) }
    }

    private var finishChoices: some View {
        VStack(spacing: 14) {
            ForEach(finishes, id: \.0) { value in
                Button { wall.send(["finish": value.0]); Taps.detent() } label: {
                    HStack(spacing: 16) {
                        preview(images.shots[value.0], label: value.1).frame(width: 76)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.1).font(.ui(typeSize.isAccessibilitySize ? 13 : 19, .semibold)).foregroundStyle(Ink.ink)
                            Text(value.2).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: wall.state.finish == value.0 ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(wall.state.finish == value.0 ? accent : Ink.dim)
                    }.padding(12).background(wall.state.finish == value.0 ? accent.opacity(0.1) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(PressStyle()).disabled(!ready)
                    .accessibilityAddTraits(wall.state.finish == value.0 ? .isSelected : [])
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(wall.state.title ?? "Waiting for a song").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
            if let artist = wall.state.artist { Text(artist).font(.ui(13)).foregroundStyle(Ink.dim) }
            if let sheet, !sheet.lines.isEmpty {
                TimelineView(.animation(minimumInterval: 0.15, paused: !wall.state.songPlaying || !wall.link.isLive)) { context in
                    let time = (PlaybackIdentity(state: wall.state, link: wall.link, at: context.date).elapsed ?? 0) + offset
                    let index = sheet.lines.lastIndex { $0.at <= time }
                    VStack(alignment: .leading, spacing: 18) {
                        if let index {
                            activeLine(sheet.lines[index], time: time)
                                .font(.system(size: typeSize.isAccessibilitySize ? 28 : 34, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                            if index + 1 < sheet.lines.count {
                                Text(sheet.lines[index + 1].text).font(.ui(22, .semibold)).foregroundStyle(Ink.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Before the first word").font(.displayMid(28)).foregroundStyle(Ink.ink)
                            Text(sheet.lines[0].text).font(.ui(22, .semibold)).foregroundStyle(Ink.dim)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                PlaybackProgress(state: wall.state, link: wall.link, accent: accent)
            } else {
                Label(problem != nil || sheet?.state == "error" ? "Lyrics are out of reach" : !loaded || sheet?.state == "loading" ? "Finding the words…" : "No synced lyrics for this song", systemImage: "text.quote")
                    .font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
                Text(problem ?? (sheet?.state == "error" ? "The lyrics service isn’t answering. Try again in a moment." : "The sleeve stays on the wall until synced words are available.")).font(.ui(14)).foregroundStyle(Ink.dim)
            }
            if problem != nil || sheet?.state == "error" || sheet?.state == "none" { Button("Try again") { retry += 1 }.frame(minHeight: 44) }
        }.padding(22).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
    }

    private func activeLine(_ line: ReadingLine, time: Double) -> Text {
        guard !line.words.isEmpty else { return Text(line.text.isEmpty ? "Instrumental" : line.text).foregroundColor(Ink.ink) }
        return line.words.enumerated().reduce(Text("")) { text, word in
            text + Text((word.offset == 0 ? "" : " ") + word.element.text)
                .foregroundColor(word.element.at <= time ? Ink.ink : Ink.dim)
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Fine-tune the timing").font(.ui(17, .semibold)); Spacer(); Text(String(format: "%+.2f s", offset)).font(.machine(12)) }
            Slider(value: $offset, in: -2...2, step: 0.05) { editing = $0; if !$0 { wall.send(["lyric_offset": offset]); lyricsNudge = offset } }
                .accessibilityLabel("Lyrics timing offset").accessibilityValue(String(format: "%+.2f seconds", offset))
            HStack { Text("Later"); Spacer(); Button("Reset") { offset = 0.2; wall.send(["lyric_offset": offset]); lyricsNudge = offset }; Spacer(); Text("Earlier") }.font(.ui(13)).foregroundStyle(Ink.dim)
            Text("Positive values bring the words forward. The phone and wall use the same timing.").font(.ui(12)).foregroundStyle(Ink.dim)
        }.foregroundStyle(Ink.ink).disabled(!ready)
    }

    private var rotation: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("In this rotation").font(.ui(21, .semibold)); Spacer(); Text("\(covers.count) / 9").font(.machine(11)).foregroundStyle(Ink.dim) }
            Text("Newest first. Each cover gets one place, even when you play it again.").font(.ui(14)).foregroundStyle(Ink.dim)
            if covers.isEmpty {
                ContentUnavailableView(loaded ? "Room for nine records" : "Loading your rotation", systemImage: "square.grid.3x3", description: Text(problem ?? "Play music and your latest sleeves will fill the wall."))
            }
            ForEach(Array(covers.enumerated()), id: \.element.id) { index, cover in
                HStack(spacing: 14) {
                    Text(String(format: "%02d", index + 1)).font(.machine(11)).foregroundStyle(accent).frame(width: 24)
                    AsyncImage(url: URL(string: cover.id)) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.05) }
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cover.title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text(cover.artist).font(.ui(13)).foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 3)
            }
            if let problem, !covers.isEmpty { Text(problem).font(.ui(13)).foregroundStyle(Ink.dim) }
            if problem != nil { Button("Try again") { retry += 1 }.frame(minHeight: 44) }
        }.foregroundStyle(Ink.ink)
    }

    private var lampChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Choose an atmosphere").font(.ui(20, .semibold)); Spacer() }.foregroundStyle(Ink.ink)
            Text("Preview studies · one moment from each moving scene").font(.ui(12)).foregroundStyle(Ink.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 16) {
                ForEach(effects, id: \.0) { effect in
                    Button { wall.send(["mode": "ambient", "effect": effect.0]); Taps.detent() } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            preview(images.shots[effect.0], label: effect.1)
                                .overlay(alignment: .bottomTrailing) {
                                    if wall.state.effect == effect.0 { Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.ground, accent).padding(8) }
                                }
                            Text(effect.1).font(.ui(14, .semibold)).foregroundStyle(wall.state.effect == effect.0 ? accent : Ink.ink)
                        }
                    }.buttonStyle(PressStyle()).disabled(!ready)
                        .accessibilityAddTraits(wall.state.effect == effect.0 ? .isSelected : [])
                }
            }
            imageStatus
        }
    }

    private var lampControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Borrow the album’s colours", isOn: Binding(get: { wall.state.matchArt }, set: { wall.send(["match_art": $0]) }))
                .font(.ui(16, .semibold)).tint(accent)
            if !wall.state.matchArt {
                ColorPicker("First colour", selection: Binding(get: { Color.wall(hex: wall.state.color) }, set: { wall.send(["color": $0.wallHex]) }), supportsOpacity: false)
                ColorPicker("Second colour", selection: Binding(get: { Color.wall(hex: wall.state.color2) }, set: { wall.send(["color2": $0.wallHex]) }), supportsOpacity: false)
            }
            Divider().overlay(Ink.dim.opacity(0.2))
            HStack { Text("Pace").font(.ui(16, .semibold)); Spacer(); Text(String(format: "%.1f×", speed)).font(.machine(12)) }
            Slider(value: $speed, in: 0.1...3, step: 0.1) { editing = $0; if !$0 { wall.send(["speed": speed]) } }.accessibilityLabel("Scene speed")
            HStack { Text("Unhurried"); Spacer(); Text("Energetic") }.font(.ui(12)).foregroundStyle(Ink.dim)
        }.foregroundStyle(Ink.ink).padding(22).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22)).disabled(!ready)
    }

    private func watchContent() async {
        loaded = false; problem = nil; sheet = nil; covers = []
        if detail == .lyrics, retry > 0, let url = URL(string: "http://\(wall.host)/lyrics/retry") {
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 4
            _ = try? await URLSession.shared.data(for: request)
        }
        while !Task.isCancelled {
            do {
                guard let url = URL(string: "http://\(wall.host)\(detail == .lyrics ? "/lyrics" : "/journal?limit=60")") else { throw URLError(.badURL) }
                var request = URLRequest(url: url); request.timeoutInterval = 5; request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                if detail == .lyrics { sheet = try JSONDecoder().decode(ReadingSheet.self, from: data) }
                else {
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["entries"] as? [[String: Any]] else { throw URLError(.cannotDecodeContentData) }
                    var seen = Set<String>()
                    covers = rows.compactMap { row -> RotationCover? in
                        guard let url = row["art_url"] as? String, !url.isEmpty, seen.insert(url).inserted else { return nil }
                        return RotationCover(id: url, title: row["album"] as? String ?? row["title"] as? String ?? "Untitled", artist: row["artist"] as? String ?? "Unknown artist")
                    }.prefix(9).map { $0 }
                }
                problem = nil; loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                problem = "The wall isn’t answering. Your last view is kept here."; loaded = true
            }
            do { try await Task.sleep(for: .seconds(detail == .lyrics ? 1 : 5)) } catch { return }
        }
    }
}
