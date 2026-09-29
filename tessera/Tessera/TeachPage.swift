import SwiftUI

struct TeachPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @State private var library: TaughtList?
    @State private var tuning = TuningStore()
    @State private var title = ""
    @State private var artist = ""
    @State private var query = ""
    @State private var composerOpen = false
    @State private var optionsOpen = false
    @State private var expanded: String?
    @State private var confirmForget: TaughtList.Song?
    @State private var busy = false
    @State private var forgetting: String?
    @State private var tuningBusy = false
    @State private var loaded = false
    @State private var readFailed = false
    @State private var problem: String?
    @State private var receipt: String?
    @State private var version = 0
    @State private var operation = UUID()
    @FocusState private var field: Field?
    private enum Field { case title, artist, search }
    private let mint = Color(hex: 0xBDD6B4)
    private var songs: [TaughtList.Song] { library?.songs ?? [] }
    private var filtered: [TaughtList.Song] { songs.filter { $0.matches(query) } }
    private var pending: Bool { busy || library?.teacher?.learning != nil }
    /// The wall answered but has no song library (teach switched off, or no
    /// microphone). Every write would fail with 404 there.
    private var unavailable: Bool { loaded && library?.available == false }
    private var canWrite: Bool { wall.link.isLive && loaded && !readFailed && !unavailable && !pending && forgetting == nil }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanArtist: String { artist.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MessagePage(title: "Song library", eyebrow: "MUSIC RECOGNITION", tint: mint) {
            hero
            if !wall.link.isLive || readFailed {
                MessageNotice(title: wall.link.isLive ? "Couldn't read the library" : "Your wall is offline", detail: "Your draft stays here. Reconnect or pull to refresh before changing the library.", symbol: "wifi.slash", tint: mint)
            }
            if unavailable {
                MessageNotice(title: "Teaching is off on this wall", detail: "This wall has no song library. Teaching needs the wall's microphone and the teach feature switched on in the wall's settings.", symbol: "music.note.list", tint: mint)
            }
            if pending { learning }
            if let receipt {
                MessageNotice(title: receipt, detail: "Confirmed by your wall.", symbol: "checkmark.circle", tint: mint)
            }
            if let problem = problem ?? library?.problem ?? library?.teacher?.problem ?? tuning.problem {
                MessageProblem(text: problem)
            }
            addSong
            collection
            learningSettings
        }
        .refreshable { await refresh(host: wall.host); await tuning.load(host: wall.host) }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            await tuning.load(host: host)
            while !Task.isCancelled {
                await refresh(host: host)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: wall.host) { _, _ in
            version += 1; operation = UUID(); library = nil; loaded = false
            readFailed = false; busy = false; forgetting = nil; tuningBusy = false; problem = nil; receipt = nil
        }
        .confirmationDialog("Forget this song?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }), titleVisibility: .visible) {
            if let song = confirmForget {
                Button("Forget \(song.title)", role: .destructive) { forget(song) }
            }
            Button("Keep song", role: .cancel) { confirmForget = nil }
        } message: {
            Text("Its local fingerprints will be removed. You can teach it again later.")
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-teach-compose") { composerOpen = true; title = "Nights"; artist = "Frank Ocean" }
            if ProcessInfo.processInfo.arguments.contains("-teach-options") { optionsOpen = true }
        }
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top, spacing: 12) {
                // Two lines at most beside the fingerprint, shrinking rather
                // than breaking a word when the column runs short.
                if typeSize.isAccessibilitySize {
                    Text("Taught songs").font(.ui(25, .semibold))
                        .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Taught\nsongs").font(.display(38)).foregroundStyle(Ink.ink)
                        .lineLimit(2).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    TeachFingerprint(tint: mint).frame(width: 80, height: 88).padding(.top, 5).accessibilityHidden(true)
                }
            }
            Text("These songs are recognized on the wall itself, before Shazam is asked.")
                .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if loaded {
                    Text(songs.count.formatted()).font(.display(42)).foregroundStyle(mint)
                    Text(songs.count == 1 ? "song learned" : "songs learned")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(wall.link.isLive && !readFailed ? "Reading the library…" : "Library not loaded")
                        .font(.ui(14)).foregroundStyle(Ink.dim)
                }
            }.accessibilityElement(children: .combine)
        }
    }

    private var learning: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView().tint(mint).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text("Learning").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                // teach.py joins artist and title with a spaced em dash. Show a
                // comma there instead, like the rest of the app.
                Text(library?.teacher?.learning?.replacingOccurrences(of: " \u{2014} ", with: ", ") ?? "\(cleanTitle) by \(cleanArtist)")
                    .font(.ui(14)).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
                Text("You can leave this page. Learning continues on the wall.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).messageSurface()
            .accessibilityElement(children: .combine)
    }

    private var addSong: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { composerOpen.toggle() }
                if composerOpen { field = .title } else { field = nil }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: composerOpen ? "minus" : "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(mint)
                    Text("Teach a song by name").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(composerOpen ? "Expanded" : "Collapsed")
            if composerOpen {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The wall finds a matching preview and keeps its sound fingerprint.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    entry("Song title", text: $title, focus: .title)
                    entry("Artist", text: $artist, focus: .artist)
                    Button(action: learn) {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                            Text("Teach this song").font(.ui(16, .semibold))
                        }.foregroundStyle(Ink.ground).frame(maxWidth: .infinity, minHeight: 52)
                            .background(mint.opacity(canWrite && !cleanTitle.isEmpty && !cleanArtist.isEmpty ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(PressStyle()).disabled(!canWrite || cleanTitle.isEmpty || cleanArtist.isEmpty)
                }.padding(.top, 8).padding(.bottom, 4)
            }
        }.padding(.horizontal, 18).padding(.vertical, 8).messageSurface()
    }

    private func entry(_ placeholder: String, text: Binding<String>, focus: Field) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(placeholder).font(.ui(12, .medium)).foregroundStyle(Ink.dim)
            TextField("", text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(200)); receipt = nil; problem = nil }), prompt: Text(placeholder).foregroundStyle(Ink.dim))
                .font(.ui(17)).foregroundStyle(Ink.ink).padding(14)
                .background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
                .focused($field, equals: focus).submitLabel(focus == .title ? .next : .done)
                .onSubmit { field = focus == .title ? .artist : nil }
                .accessibilityLabel(placeholder).disabled(busy)
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("The local library").font(.ui(21, .semibold)).foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
                Image(systemName: "internaldrive").font(.system(size: 16)).foregroundStyle(mint).accessibilityHidden(true)
            }
            if !loaded {
                if readFailed || !wall.link.isLive {
                    Text("Your saved songs will return here when the wall answers.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                } else {
                    HStack(spacing: 10) { ProgressView().tint(mint); Text("Reading your wall's library").font(.ui(14)).foregroundStyle(Ink.dim) }.padding(.vertical, 20)
                }
            } else if unavailable {
                Text("No library on this wall.").font(.ui(14)).foregroundStyle(Ink.dim).padding(.vertical, 12)
            } else if songs.isEmpty {
                MessageNotice(title: "No songs yet", detail: "Teach a song by name, or play music while a connected source names it. Only sound fingerprints stay on the wall, never recordings.", symbol: "music.note", tint: mint)
                    .padding(18).messageSurface()
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(mint)
                    TextField("", text: $query, prompt: Text("Search songs, artists, albums").foregroundStyle(Ink.dim))
                        .font(.ui(14)).foregroundStyle(Ink.ink).focused($field, equals: .search)
                        .autocorrectionDisabled().accessibilityLabel("Search local library")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.dim).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Clear search")
                    }
                }.padding(.leading, 14).padding(.trailing, 5).frame(minHeight: 52).messageSurface()
                if filtered.isEmpty {
                    Text("No songs match “\(query)”. Try a title, artist or album.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { song in
                        songRow(song)
                        if song.id != filtered.last?.id { Rule() }
                    }
                }
            }
        }
    }

    private func songRow(_ song: TaughtList.Song) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded = expanded == song.id ? nil : song.id }
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    if !typeSize.isAccessibilitySize { TeachArtwork(song: song, tint: mint).frame(width: 58, height: 58) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        Text(song.artist).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        Text(song.sources).font(.ui(11, .medium)).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded == song.id ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.dim)
                }.frame(minHeight: 66).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityHint("Show learning details")
            if expanded == song.id {
                VStack(alignment: .leading, spacing: 10) {
                    if let album = song.album, !album.isEmpty { Text(album).font(.ui(14)).foregroundStyle(Ink.ink) }
                    Text("\((song.landmarks ?? 0).formatted()) sound landmarks, recognized \(song.matched.formatted()) \(song.matched == 1 ? "time" : "times")")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    if let match = library?.last_match, match.id == song.id {
                        Label("Last match: \(match.score) aligned landmarks", systemImage: "checkmark.seal")
                            .font(.ui(13)).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
                        Text("\(library?.min_score ?? 15) are needed to recognize a song. This is a match score, not a probability.")
                            .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    Button { confirmForget = song } label: {
                        Label(forgetting == song.id ? "Forgetting…" : "Forget this song", systemImage: "trash")
                            .font(.ui(13, .medium)).foregroundStyle(Ink.signal).frame(minHeight: 44)
                    }.buttonStyle(.plain).disabled(!canWrite)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(.vertical, 12)
    }

    private var learningSettings: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("How songs are learned").font(.ui(21, .semibold)).foregroundStyle(Ink.ink)
            VStack(alignment: .leading, spacing: 14) {
                learningToggle("Recognize my library first", detail: "Ask your own songs before Shazam.", key: "teach")
                Rule()
                learningToggle("Learn from the room", detail: "When another source names a song, learn how it sounds here after 15 seconds of music.", key: "teach_by_ear")
            }.padding(18).messageSurface()
            DisclosureGroup(isExpanded: $optionsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Higher values need a stronger match. Lower values can recognize sooner, but risk a wrong song.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    Stepper(value: Binding(get: { Int(tuning.values["teach_match_score"] ?? Double(library?.min_score ?? 15)) }, set: { send("teach_match_score", Double($0)) }), in: 5...60) {
                        Text("\(Int(tuning.values["teach_match_score"] ?? Double(library?.min_score ?? 15))) aligned landmarks")
                            .font(.ui(14, .medium)).foregroundStyle(mint)
                    }.disabled(!canWrite || tuningBusy || tuning.values["teach_match_score"] == nil)
                }.padding(.top, 12)
            } label: { Text("Match sensitivity").font(.ui(15, .medium)).foregroundStyle(Ink.ink).frame(minHeight: 44) }
            NavigationLink(value: SettingsDestination.hearing) {
                HStack(spacing: 12) {
                    Image(systemName: "ear.badge.waveform").foregroundStyle(mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hearing & gestures").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                        Text("Microphone, listening gate and room feedback").font(.ui(12)).foregroundStyle(Ink.dim)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.dim)
                }.frame(minHeight: 52)
            }.buttonStyle(.plain)
            Text("Fingerprints stay on your wall. Audio recordings aren't saved.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func learningToggle(_ title: String, detail: String, key: String) -> some View {
        Toggle(isOn: Binding(get: { (tuning.values[key] ?? 0) > 0.5 }, set: { send(key, $0 ? 1 : 0, isBool: true) })) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.tint(mint).disabled(!canWrite || tuningBusy || tuning.values[key] == nil)
    }

    private func send(_ key: String, _ value: Double, isBool: Bool = false) {
        guard canWrite, !tuningBusy else { return }
        tuningBusy = true
        let host = wall.host
        Task {
            await tuning.send(key, value, isBool: isBool)
            guard host == wall.host else { return }
            tuningBusy = false
            if tuning.problem == nil { Taps.commit(); await refresh(host: host) }
        }
    }

    private func refresh(host: String) async {
        let revision = version
        let fresh = await TaughtList.read(host: host)
        guard host == wall.host, !Task.isCancelled, revision == version else { return }
        guard let fresh else { readFailed = true; return }
        library = fresh; loaded = true; readFailed = false
    }

    private func learn() {
        guard canWrite, !cleanTitle.isEmpty, !cleanArtist.isEmpty else { return }
        busy = true; problem = nil; receipt = nil; field = nil; version += 1
        let host = wall.host, wanted = cleanTitle, performer = cleanArtist, id = UUID()
        operation = id
        Task {
            let result = await TaughtList.learn(host: host, title: wanted, artist: performer)
            guard host == wall.host, operation == id else { return }
            version += 1; busy = false; problem = result.1
            if result.0 {
                receipt = "Learned \(wanted)"; title = ""; artist = ""; composerOpen = false; Taps.commit()
            }
            await refresh(host: host)
        }
    }

    private func forget(_ song: TaughtList.Song) {
        guard canWrite else { return }
        forgetting = song.id; confirmForget = nil; problem = nil; receipt = nil; version += 1
        let host = wall.host, id = UUID(); operation = id
        Task {
            let result = await TaughtList.forgetReply(host: host, id: song.id)
            guard host == wall.host, operation == id else { return }
            version += 1; forgetting = nil; problem = result.1
            if result.0 { receipt = "Forgot \(song.title)"; expanded = nil; Taps.commit() }
            await refresh(host: host)
        }
    }
}

private struct TeachArtwork: View {
    let song: TaughtList.Song
    let tint: Color
    var body: some View {
        AsyncImage(url: song.art_url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else {
                ZStack {
                    Ink.plaster
                    Circle().stroke(tint.opacity(0.3), lineWidth: 1).padding(7)
                    Circle().stroke(tint.opacity(0.2), lineWidth: 1).padding(13)
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(tint)
                }
            }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
    }
}

/// A static sound-print motif, not a simulated live recording or confidence meter.
private struct TeachFingerprint: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            for ring in 0..<8 {
                let inset = CGFloat(ring) * 4.1 + 4
                let rect = CGRect(x: inset, y: inset * 0.9, width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 1.8))
                var path = Path()
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.width * 0.46, height: rect.height * 0.46))
                context.stroke(path, with: .color(tint.opacity(0.25 + Double(ring) * 0.065)), style: StrokeStyle(lineWidth: 1.5, dash: ring % 3 == 0 ? [14, 5, 29, 9] : [38, 5, 15, 4]))
            }
        }
    }
}
