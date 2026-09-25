import SwiftUI

struct ShowPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @State private var scope: DiscoveryScope = .picture
    @State private var drafts: [DiscoveryScope: String] = [:]
    @State private var status: DiscoveryStatus?
    @State private var result: ShowResult?
    @State private var busy = false
    @State private var loaded = false
    @State private var readFailed = false
    @State private var problem: String?
    @State private var requestID = UUID()
    @State private var version = 0
    @FocusState private var typing: Bool
    private let tint = Color(hex: 0xA9D2D4)
    private var pending: Bool { busy || status?.pending == true }
    private var query: String { (drafts[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var queryBinding: Binding<String> {
        Binding(get: { drafts[scope] ?? "" }, set: { drafts[scope] = String($0.prefix(500)); problem = nil })
    }

    var body: some View {
        DiscoveryPage(title: "Show me", eyebrow: "A WINDOW TO ANYWHERE", tint: tint) {
            if result == nil {
                DiscoveryIntroduction(title: "Find a little\nwonder.", detail: "A place. A record. A moving picture.\nGive your wall something new.", symbol: "viewfinder", tint: tint)
            }
            if !wall.link.isLive {
                DiscoveryNotice(title: "Your wall is offline", detail: "Your searches stay here until it reconnects.", symbol: "wifi.slash", tint: tint)
            } else if readFailed {
                DiscoveryNotice(title: "Couldn't read recent discoveries", detail: "Pull to refresh. Your search is safe.", symbol: "arrow.clockwise", tint: tint)
            }
            if let result { resultCard(result) }
            composer
            if pending {
                DiscoveryWaiting(title: scope == .video ? "Finding a moving picture" : "Looking beyond the room", detail: "The result will appear here when the wall confirms it.", tint: tint)
            }
            if let problem { DiscoveryProblem(text: problem) }
            if !pending { sourceNote }
        }
        .refreshable { await refresh(host: wall.host) }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                await refresh(host: host)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: wall.host) { _, _ in
            requestID = UUID(); version += 1; busy = false; result = nil
            status = nil; loaded = false; readFailed = false; problem = nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scopeButtons }
                VStack(alignment: .leading, spacing: 8) { scopeButtons }
            }
            TextField(scope.placeholder, text: queryBinding,
                      prompt: Text(scope.placeholder).foregroundStyle(Ink.dim), axis: .vertical)
                .font(.ui(22, .medium)).foregroundStyle(Ink.ink).lineLimit(2...5)
                .focused($typing).disabled(pending).accessibilityLabel("\(scope.title) search")
            HStack {
                Text(scope == .video ? "PLAYS ON YOUR WALL" : "TEN MINUTES ON YOUR WALL")
                    .font(.machine(9)).tracking(0.3).foregroundStyle(Ink.dim)
                Spacer(minLength: 4)
                Text("\(query.count)/500").font(.machine(9)).foregroundStyle(Ink.dim)
            }.accessibilityHidden(true)
            DiscoveryAction(title: pending ? "Finding…" : (scope == .video ? "Find & play" : "Find & show"), symbol: scope == .video ? "play.fill" : "arrow.up.right", tint: tint,
                            enabled: wall.link.isLive && !query.isEmpty && !pending && !(scope == .video && status?.video_available == false), busy: pending) { send() }
            if query.isEmpty && !pending {
                Button {
                    drafts[scope] = scope.example; typing = true; Taps.detent()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Try").foregroundStyle(Ink.dim)
                        Text(scope.example).foregroundStyle(tint)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").foregroundStyle(tint)
                    }.font(.ui(13)).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityHint("Places this example in the search field")
            }
            if scope == .video && status?.video_available == false {
                Text("Video playback isn't available on this wall.").font(.ui(13)).foregroundStyle(Ink.dim)
            }
        }.padding(20).discoverySurface()
    }

    private var scopeButtons: some View {
        ForEach(DiscoveryScope.allCases) { item in
            Button {
                scope = item; problem = nil; Taps.detent()
            } label: {
                Label(item.title, systemImage: item.symbol).font(.ui(13, .semibold))
                    .foregroundStyle(scope == item ? Ink.ground : Ink.dim)
                    .padding(.horizontal, 13).frame(minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .background(scope == item ? tint : Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(pending)
                .accessibilityAddTraits(scope == item ? [.isSelected] : [])
        }
    }

    private func resultCard(_ result: ShowResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(result.receipt, systemImage: result.active == true ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    .font(.ui(12, .medium)).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            if result.isVideo && result.active == true {
                DiscoveryLiveWall(frame: wall.frame)
            } else {
                DiscoveryArtwork(png: result.preview_png, artURL: result.art_url, title: result.heading, tint: tint)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(result.heading).font(.displayMid(28)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                if !result.byline.isEmpty { Text(result.byline).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            }
            if result.preview_png != nil {
                Label("The composition sent to your wall", systemImage: "square.grid.3x3")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
            } else if result.isVideo {
                Text(result.active == true ? "Live wall frame · sound plays through this iPhone." : "This video has finished or another face is now showing.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            if let url = result.url.flatMap(URL.init(string:)), ["https", "http"].contains(url.scheme ?? "") {
                Link(destination: url) { Label("Open original video", systemImage: "arrow.up.right").font(.ui(14, .medium)).frame(minHeight: 44) }.foregroundStyle(tint)
            }
        }.padding(18).discoverySurface()
    }

    private var sourceNote: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(scope == .picture ? (status?.picture_provider ?? "Web search") : scope == .cover ? "The record, by name" : "A little cinema")
                .font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
            Text(scope == .picture ? "Finds a picture through your configured Google Images service, the web, or an image archive. The source stays with the result."
                 : scope == .cover ? "Searches iTunes for a sleeve. Add the artist when two records share a name. Your music keeps playing."
                 : "Finds a video by name. For your own clips and framing, go to Video.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if scope != .video {
                NavigationLink(value: SettingsDestination.services) {
                    Label("Search services", systemImage: "arrow.up.right").font(.ui(13, .medium)).frame(minHeight: 44)
                }.foregroundStyle(tint)
            }
        }.padding(.horizontal, 4)
    }

    private func refresh(host: String) async {
        let observedVersion = version
        let value: DiscoveryStatus? = await DiscoveryAPI.read("/show", host: host)
        guard !Task.isCancelled, host == wall.host, observedVersion == version, !busy else { return }
        loaded = true; readFailed = value == nil
        if let value { status = value; result = value.last; if problem == nil { problem = value.problem } }
    }

    private func send() {
        guard !pending, wall.link.isLive, !query.isEmpty else { return }
        typing = false; busy = true; problem = nil; version += 1
        let id = UUID(), host = wall.host, selected = scope, text = query
        requestID = id
        Task {
            let (value, error): (ShowResult?, String?) = await DiscoveryAPI.send(selected == .video ? "/play" : "/show", host: host, body: ["query": text, "kind": selected.rawValue])
            guard requestID == id, wall.host == host else { return }
            version += 1; busy = false; status?.pending = false
            if let value { result = value; Taps.commit() }
            problem = error
        }
    }
}

struct EarwormPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @State private var words = ""
    @State private var status: EarwormStatus?
    @State private var found: Earworm?
    @State private var busy = false
    @State private var loaded = false
    @State private var readFailed = false
    @State private var problem: String?
    @State private var requestID = UUID()
    @State private var version = 0
    @FocusState private var typing: Bool
    private let tint = Color(hex: 0xDEB8A4)
    private var pending: Bool { busy || status?.pending == true }
    private var typed: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        DiscoveryPage(title: "Earworm", eyebrow: "FOR THE SONG THAT STAYED", tint: tint) {
            if found == nil {
                DiscoveryIntroduction(title: "On the tip of\nyour tongue.", detail: "A half-remembered chorus.\nLet's put a name to it.", symbol: "waveform", tint: tint)
            }
            connection
            if let found { foundCard(found) }
            composer
            if pending {
                DiscoveryWaiting(title: "Following the melody in your words", detail: "Looking for a song and its sleeve. You can leave this page; the discovery stays here.", tint: tint)
            }
            if let problem { DiscoveryProblem(text: problem) }
            if let alternatives = found?.alternatives, !alternatives.isEmpty { alternativesList(alternatives) }
        }
        .refreshable { await refresh(host: wall.host) }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                await refresh(host: host)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: wall.host) { _, _ in
            requestID = UUID(); version += 1; busy = false; found = nil
            status = nil; loaded = false; readFailed = false; problem = nil
        }
    }

    @ViewBuilder private var connection: some View {
        if !wall.link.isLive {
            DiscoveryNotice(title: "Connect your wall", detail: "Your remembered words stay here while the wall is offline.", symbol: "wifi.slash", tint: tint)
        } else if !loaded {
            HStack(spacing: 10) { ProgressView().tint(tint); Text("Checking the song finder…").font(.ui(13)).foregroundStyle(Ink.dim) }
        } else if readFailed {
            DiscoveryNotice(title: "Couldn't read the song finder", detail: "Pull to refresh. Your words are safe.", symbol: "arrow.clockwise", tint: tint)
        } else if status?.ready != true {
            VStack(alignment: .leading, spacing: 10) {
                DiscoveryNotice(title: "Connect Claude to begin", detail: "Identification uses your Claude service. Add the key once in Services.", symbol: "key.horizontal", tint: tint)
                NavigationLink(value: SettingsDestination.services) {
                    Label("Open Services", systemImage: "arrow.up.right").font(.ui(14, .semibold)).frame(minHeight: 44)
                }.foregroundStyle(tint)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(found == nil ? "The part you remember" : "Find another song").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
                Image(systemName: "quote.opening").font(.system(size: 19, weight: .medium)).foregroundStyle(tint).accessibilityHidden(true)
            }
            TextField("Remembered words", text: $words, prompt: Text("A line of lyrics, the singer's voice, a scene from the video…").foregroundStyle(Ink.dim), axis: .vertical)
                .font(.ui(22)).foregroundStyle(Ink.ink).lineLimit(3...6).focused($typing).disabled(pending)
                .onChange(of: words) { _, value in if value.count > 2000 { words = String(value.prefix(2000)) }; problem = nil }
            DiscoveryAction(title: pending ? "Finding the song…" : "Find that song", symbol: "waveform", tint: tint,
                            enabled: wall.link.isLive && status?.ready == true && !readFailed && !pending && !typed.isEmpty, busy: pending) { identify() }
            Text("Describe it in words. This page doesn't listen to or record audio. Matches are suggestions, not certainty.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(20).discoverySurface()
    }

    private func foundCard(_ song: Earworm) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Label(song.confidenceLabel, systemImage: "sparkle").font(.ui(12, .medium)).foregroundStyle(tint)
                Spacer(minLength: 0)
                ShareLink(item: song.shareText) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .foregroundStyle(tint).accessibilityLabel("Share this song")
            }
            DiscoveryArtwork(png: song.preview_png, artURL: song.art_url, title: song.title ?? "Discovered song", tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(song.title ?? "A possible match").font(.displayMid(32)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Text(song.artist ?? "Unknown artist").font(.ui(17)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                if let album = song.album, album != song.title { Text(album).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            }
            if let words = song.words, !words.isEmpty {
                Text("From your clue: “\(words)”").font(.ui(13)).foregroundStyle(Ink.dim).lineLimit(3)
            }
            if song.active == true {
                Label("Sleeve showing on the wall", systemImage: "checkmark.circle.fill").font(.ui(13, .medium)).foregroundStyle(tint)
            } else if song.art_url != nil {
                DiscoveryAction(title: song.shown == true ? "Show the sleeve again" : "Show this sleeve", symbol: "arrow.up.right", tint: tint,
                                enabled: wall.link.isLive && !pending && song.id != nil, busy: false) { showAgain(song) }
            } else {
                DiscoveryNotice(title: "The song has a name", detail: "We couldn't find its sleeve. The result is saved here.", symbol: "music.note", tint: tint)
            }
            if song.preview_png != nil {
                Text("Exact wall composition · stays for ten minutes. Your music keeps playing.").font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).discoverySurface()
    }

    private func alternativesList(_ alternatives: [Earworm.Alt]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Another possibility").font(.displayMid(24)).foregroundStyle(Ink.ink)
            ForEach(alternatives) { candidate in
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "music.note").foregroundStyle(tint).frame(width: 22).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                        Text(candidate.artist).font(.ui(13)).foregroundStyle(Ink.dim)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        words = "I think it might be \(candidate.title) by \(candidate.artist). \(found?.words ?? typed)"
                        typing = true; Taps.detent()
                    } label: {
                        Image(systemName: "arrow.up.left").foregroundStyle(tint).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).disabled(pending)
                        .accessibilityLabel("Refine the clue with \(candidate.title) by \(candidate.artist)")
                }.padding(16).discoverySurface()
            }
        }
    }

    private func refresh(host: String) async {
        let observedVersion = version
        let value: EarwormStatus? = await DiscoveryAPI.read("/earworm", host: host)
        guard !Task.isCancelled, host == wall.host, observedVersion == version, !busy else { return }
        loaded = true; readFailed = value == nil
        if let value { status = value; found = value.last; if problem == nil { problem = value.problem } }
    }

    private func identify() {
        guard wall.link.isLive, status?.ready == true, !pending, !typed.isEmpty else { return }
        perform(["words": typed])
    }

    private func showAgain(_ song: Earworm) {
        guard let id = song.id, !pending, wall.link.isLive else { return }
        perform(["action": "show", "id": id])
    }

    private func perform(_ body: [String: Any]) {
        typing = false; busy = true; problem = nil; version += 1
        let id = UUID(), host = wall.host
        requestID = id
        Task {
            let (value, error): (Earworm?, String?) = await DiscoveryAPI.send("/earworm", host: host, body: body)
            guard requestID == id, wall.host == host else { return }
            version += 1; busy = false; status?.pending = false
            if let value { found = value; Taps.commit() }
            problem = error
        }
    }
}

private struct DiscoveryPage<Content: View>: View {
    let title: String
    let eyebrow: String
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(eyebrow).font(.machine(9)).tracking(0.8).foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14).accessibilityHidden(true)
                content
            }.padding(.horizontal, 22).padding(.bottom, 40)
        }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .background(Ink.ground).tint(tint).navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct DiscoveryIntroduction: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(typeSize.isAccessibilitySize ? title.replacingOccurrences(of: "\n", with: " ") : title)
                .font(typeSize.isAccessibilitySize ? .ui(24, .semibold) : .display(43)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                Text(detail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    DiscoveryGlyph(symbol: symbol, tint: tint).frame(width: 64, height: 58).accessibilityHidden(true)
                }
            }
        }.padding(.bottom, 4)
    }
}

private struct DiscoveryGlyph: View {
    let symbol: String
    let tint: Color
    var body: some View {
        ZStack {
            Canvas { context, size in
                for row in 0..<12 {
                    for col in 0..<9 {
                        let rect = CGRect(x: (CGFloat(col) + 0.5) * size.width / 9, y: (CGFloat(row) + 0.5) * size.height / 12, width: 1.5, height: 1.5)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.18)))
                    }
                }
            }
            Image(systemName: symbol).font(.system(size: 36, weight: .ultraLight)).foregroundStyle(tint)
        }
    }
}

private struct DiscoveryArtwork: View {
    let png: String?
    let artURL: String?
    let title: String
    let tint: Color
    private var image: UIImage? { png.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) } }
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else if let url = artURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: unavailable
                    default: ZStack { Ink.sunk; ProgressView().tint(tint) }
                    }
                }
            } else { unavailable }
        }.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
            .background(Ink.sunk).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1))
            .accessibilityLabel(png != nil ? "Wall composition for \(title)" : "Artwork for \(title)")
    }
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo").font(.system(size: 38, weight: .ultraLight))
            Text("Artwork unavailable").font(.ui(13))
        }.foregroundStyle(Ink.dim).frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.sunk)
    }
}

private struct DiscoveryLiveWall: View {
    let frame: Data?
    var body: some View {
        Group {
            if let frame, let image = EmitterTile.render([UInt8](frame), cell: 1) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                ZStack { Ink.sunk; Text("Waiting for the live frame…").font(.ui(13)).foregroundStyle(Ink.dim) }
            }
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Current wall frame")
    }
}

private struct DiscoveryNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 22).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct DiscoveryWaiting: View {
    let title: String
    let detail: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView().tint(tint).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(20).discoverySurface().accessibilityElement(children: .combine)
    }
}

private struct DiscoveryProblem: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.signal)
            .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct DiscoveryAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                if busy { ProgressView().tint(Ink.ground) } else { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Ink.ground).padding(.horizontal, 16).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(tint, in: RoundedRectangle(cornerRadius: 16)).opacity(enabled || busy ? 1 : 0.5)
        }.buttonStyle(PressStyle()).disabled(!enabled)
    }
}

private extension View {
    func discoverySurface() -> some View {
        background(Ink.plaster, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}
