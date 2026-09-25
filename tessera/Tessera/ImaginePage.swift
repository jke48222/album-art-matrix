import SwiftUI

/// One studio owns the prompt, current creation and saved collection. Image
/// provider preferences remain in Services; they are not duplicated here.
struct ImaginePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @State private var prompt = ""
    @State private var gallery: WallImagined?
    @State private var selectedID: String?
    @State private var submitting = false
    @State private var mutatingID: String?
    @State private var problem: String?
    @State private var loaded = false
    @State private var readFailed = false
    @State private var readVersion = 0
    @State private var requestID = UUID()
    @State private var removal: WallImagined.Item?
    @State private var serviceState: WallServices?
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @FocusState private var typing: Bool
    private let peach = Color(hex: 0xEFBF9A)
    private var typed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var connected: Bool { wall.link.isLive }
    private var pending: Bool { submitting || gallery?.isDrawing == true }
    private var selected: WallImagined.Item? {
        let items = gallery?.images ?? []
        return items.first(where: { $0.id == selectedID }) ?? items.first
    }
    private var liveOnWall: Bool {
        connected && wall.state.displayedMode == "imagine" && gallery?.on_wall == true
    }
    private var showLive: Bool {
        liveOnWall && (pending || selected?.id == gallery?.showing_id)
    }
    private var canAct: Bool { connected && !readFailed && !pending && mutatingID == nil }
    private var statusTitle: String {
        if typeSize.isAccessibilitySize {
            if pending { return "Taking shape." }
            if gallery?.live?.stage == "failed" { return "A fresh start." }
            return selected != nil ? "Your creation." : "A new idea."
        }
        if pending { return gallery?.live?.stage == "partial" ? "Colour is arriving." : "An idea takes shape." }
        if gallery?.live?.stage == "failed" { return "A fresh start." }
        if selected != nil { return "Made of imagination." }
        return "Make room for\nthe unexpected."
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    heading.id("studio-top")
                    connection
                    canvas
                    if let problem { notice(problem, symbol: "exclamationmark.circle") }
                    composer
                    if let items = gallery?.images, !items.isEmpty {
                        collection(items) {
                            if reduceMotion { proxy.scrollTo("studio-top", anchor: .top) }
                            else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("studio-top", anchor: .top) } }
                        }
                    }
                }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 40)
            }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        }
        .background(Ink.ground).tint(peach).navigationTitle("Imagine")
        .navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                await refresh(host)
                try? await Task.sleep(for: .seconds(pending ? 1.5 : 5))
            }
        }
        .onChange(of: wall.host) { _, _ in
            gallery = nil; selectedID = nil; problem = nil; loaded = false; readFailed = false
            submitting = false; mutatingID = nil; requestID = UUID(); readVersion += 1
        }
        .confirmationDialog("Remove this picture?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible) {
            if let item = removal {
                Button("Remove from collection", role: .destructive) { change(item, operation: .forget) }
                Button("Cancel", role: .cancel) { removal = nil }
            }
        } message: {
            Text("The saved picture will be deleted from your wall. If it is on display, the wall will return to its previous face.")
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THE IMAGINATION STUDIO").font(.machine(9)).tracking(0.8).foregroundStyle(peach)
                .accessibilityHidden(true)
            Text(statusTitle).font(typeSize.isAccessibilitySize ? .ui(25, .semibold) : .display(38))
                .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(pending ? "The picture is being created on your wall. You can leave this page; it will be saved here." : "A few words. A whole new world for your wall.")
                .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var connection: some View {
        if !connected {
            notice("Your wall is offline. Your words stay here until it reconnects.", symbol: "wifi.slash")
        } else if !loaded {
            HStack(spacing: 10) { ProgressView().tint(peach); Text("Opening your studio…").font(.ui(14)).foregroundStyle(Ink.dim) }
        } else if readFailed {
            VStack(alignment: .leading, spacing: 4) {
                notice("The studio isn't answering. Any accepted creation keeps running on the wall.", symbol: "wifi.exclamationmark")
                Button("Try connection again") { Task { await refresh(wall.host) } }
                    .font(.ui(14, .semibold)).frame(minHeight: 44).buttonStyle(.plain)
            }
        } else if gallery?.ready != true {
            VStack(alignment: .leading, spacing: 9) {
                notice("Connect an image service to create. Saved pictures are always yours to revisit.", symbol: "key.horizontal")
                NavigationLink {
                    ServicesPage(accent: accent, services: $serviceState, musicConnected: $musicConnected, musicRefused: $musicRefused)
                } label: {
                    HStack { Text("Connect in Services"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.ui(15, .semibold)).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if showLive {
                    PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1)
                        .accessibilityLabel(pending ? "Actual wall canvas, creation in progress" : "Actual wall artwork")
                } else if let item = selected {
                    artwork(item).accessibilityLabel("Saved picture: \(item.prompt)")
                } else {
                    ImagineBlankCanvas(tint: peach)
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(pending ? "CREATING ON YOUR WALL" : "YOUR NEXT PICTURE")
                                    .font(.machine(9)).foregroundStyle(peach)
                                Text(pending ? "Waiting for the first image" : "Begins with a few words")
                                    .font(.ui(14)).foregroundStyle(Ink.dim)
                            }.padding(22)
                        }.accessibilityElement(children: .combine)
                }
            }.aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Ink.hairline, lineWidth: 1))
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(showLive ? "LIVE WALL" : (selected == nil ? "BLANK CANVAS" : "SAVED ARTWORK"),
                          systemImage: showLive ? "circle.fill" : "square.stack")
                        .font(.machine(9)).foregroundStyle(showLive ? Ink.moss : peach)
                    Spacer(minLength: 0)
                    if pending {
                        ProgressView().tint(peach).accessibilityLabel("Creating image")
                    } else if let item = selected, let date = item.date {
                        Text(date, format: .dateTime.month(.abbreviated).day()).font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                }
                if pending {
                    Text(gallery?.progressDescription ?? "Starting your creation…")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    if let words = gallery?.live?.prompt, !words.isEmpty {
                        Text(words).font(.ui(17, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let item = selected {
                    Text(item.prompt).font(.ui(18, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        if let provider = item.provider { Text(provider == "google" ? "Imagen" : "OpenAI") }
                        if let seconds = item.took_s, seconds.isFinite {
                            Text("·"); Text("\(Int(seconds.rounded()))s to create")
                        }
                    }.font(.ui(12)).foregroundStyle(Ink.dim)
                    if !showLive {
                        action(mutatingID == item.id ? "Putting it on the wall…" : "Show on the wall", symbol: "square.grid.3x3", enabled: canAct, busy: mutatingID == item.id) {
                            change(item, operation: .show)
                        }
                    } else {
                        Text("On display for ten minutes, or until you choose another face.")
                            .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 16) {
                        Button { prompt = item.prompt; typing = true; Taps.detent() } label: {
                            Label("Use these words", systemImage: "text.quote").font(.ui(13, .medium)).frame(minHeight: 44)
                        }.disabled(pending).buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button { removal = item } label: {
                            Image(systemName: "trash").font(.system(size: 17)).frame(width: 44, height: 44)
                        }.accessibilityLabel("Remove picture from collection").disabled(!canAct).buttonStyle(.plain).foregroundStyle(Ink.dim)
                    }
                } else {
                    Text("Original pictures made for your room. Every finished creation is kept here.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 16)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(selected == nil ? "Start with a thought" : "Imagine something new")
                    .font(.ui(18, .semibold)).foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
                Image(systemName: "sparkles").foregroundStyle(peach).accessibilityHidden(true)
            }
            TextField("Describe your picture", text: $prompt,
                      prompt: Text("A glass moon floating above a quiet sea…").foregroundStyle(Ink.dim), axis: .vertical)
                .font(.ui(20)).foregroundStyle(Ink.ink).lineLimit(3...7).focused($typing)
                .disabled(pending).accessibilityLabel("Picture description")
                .onChange(of: prompt) { _, value in
                    if value.count > 1200 { prompt = String(value.prefix(1200)) }
                    problem = nil
                }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            if typed.isEmpty && !pending {
                VStack(alignment: .leading, spacing: 0) {
                    promptRow("Something otherworldly", words: "A glass moon floating over a still ink-blue sea, luminous amber reflections", symbol: "moon.stars")
                    promptRow("A small beautiful thing", words: "A tiny red mushroom beneath a towering fern, warm morning light on velvet moss", symbol: "leaf")
                }
            }
            action(pending ? "Creating your picture…" : "Create a picture", symbol: "sparkles",
                   enabled: canAct && gallery?.ready == true && !typed.isEmpty && (gallery?.cooldown_s ?? 0) <= 0,
                   busy: pending, perform: create)
            Text((gallery?.cooldown_s ?? 0) > 0 && !pending
                 ? "The studio is taking a short breath. Ready again in \(Int(ceil(gallery?.cooldown_s ?? 0))) seconds."
                 : "Uses your image service. Creation can take a few minutes. Finished pictures stay on the wall for ten minutes.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Ink.hairline, lineWidth: 1))
    }

    private func promptRow(_ title: String, words: String, symbol: String) -> some View {
        Button { prompt = words; typing = true; Taps.detent() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.system(size: 10))
            }.font(.ui(13)).foregroundStyle(Ink.dim).frame(minHeight: 44)
        }.buttonStyle(.plain)
    }

    private func collection(_ items: [WallImagined.Item], scroll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your collection").font(.ui(22, .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                Text("\(items.count)").font(.machine(12)).foregroundStyle(peach)
            }
            Text("Choose a picture to revisit it. Nothing changes on the wall until you press Show.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 20) {
                ForEach(items) { item in
                    Button {
                        selectedID = item.id; problem = nil; typing = false; Taps.detent(); scroll()
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            artwork(item).aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected?.id == item.id ? peach : Ink.hairline, lineWidth: selected?.id == item.id ? 2 : 1))
                            Text(item.prompt).font(.ui(13, .medium)).foregroundStyle(Ink.ink).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Select saved picture: \(item.prompt)")
                        .accessibilityAddTraits(selected?.id == item.id ? .isSelected : [])
                        .disabled(pending || mutatingID != nil)
                }
            }
        }
    }

    private func artwork(_ item: WallImagined.Item) -> some View {
        AsyncImage(url: WallImagined.imageURL(host: wall.host, id: item.id)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Ink.plaster).aspectRatio(1, contentMode: .fit).overlay {
                    if phase.error != nil {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 25))
                            Text("Picture unavailable").font(.ui(12))
                        }.foregroundStyle(Ink.dim)
                    } else { ProgressView().tint(peach) }
                }
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.ui(14)).foregroundStyle(Ink.dim)
            .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }

    private func action(_ title: String, symbol: String, enabled: Bool, busy: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) }
                else { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Ink.ground).padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(peach, in: RoundedRectangle(cornerRadius: 16)).opacity(enabled || busy ? 1 : 0.55)
        }.buttonStyle(PressStyle()).disabled(!enabled)
    }

    @MainActor private func refresh(_ host: String) async {
        let version = readVersion
        let result = await WallImagined.read(host: host)
        guard !Task.isCancelled, host == wall.host, version == readVersion else { return }
        loaded = true; readFailed = result == nil
        guard let result else { return }
        let oldStage = gallery?.live?.stage
        if result.showing_id != gallery?.showing_id, result.showing_id != nil { selectedID = result.showing_id }
        gallery = result
        if result.live?.stage == "failed" { problem = result.live?.problem ?? result.problem ?? "This picture couldn't be created. Your words are ready to try again." }
        else if let failure = result.problem, !result.isDrawing { problem = failure }
        if oldStage == "waiting" || oldStage == "partial", result.live?.stage == "done" {
            Taps.commit()
            AccessibilityNotification.Announcement("Your picture is ready in Imagine.").post()
        }
    }

    private func create() {
        guard canAct, gallery?.ready == true, !typed.isEmpty else { return }
        let host = wall.host, words = typed, token = UUID()
        requestID = token; readVersion += 1; submitting = true; problem = nil; typing = false
        Task {
            let result = await WallImagined.create(host: host, prompt: words)
            guard host == wall.host, requestID == token else { return }
            submitting = false; readVersion += 1
            if result.ok { Taps.detent() }
            else { problem = result.error }
            await refresh(host)
        }
    }

    private func change(_ item: WallImagined.Item, operation: WallImagined.Operation) {
        guard canAct else { return }
        let host = wall.host, token = UUID()
        requestID = token; readVersion += 1; mutatingID = item.id; removal = nil; problem = nil
        Task {
            let result = await WallImagined.change(host: host, id: item.id, operation: operation)
            guard host == wall.host, requestID == token else { return }
            mutatingID = nil; readVersion += 1
            if result.ok {
                if operation == .forget, selectedID == item.id { selectedID = nil }
                else if operation == .show { selectedID = item.id }
                Taps.commit()
            } else { problem = result.error }
            await refresh(host)
        }
    }
}

private struct ImagineBlankCanvas: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x111419)))
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
            for ring in 0..<5 {
                let radius = CGFloat(30 + ring * 17)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.09 - Double(ring) * 0.012)), lineWidth: 1)
            }
            for index in 0..<4 {
                let angle = Double(index) * .pi / 2 + .pi / 4
                let x = center.x + cos(angle) * 48, y = center.y + sin(angle) * 48
                context.fill(Path(roundedRect: CGRect(x: x - 3, y: y - 3, width: 6, height: 6), cornerRadius: 1), with: .color(tint.opacity(0.72)))
            }
            let mark = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            context.fill(Path(roundedRect: mark, cornerRadius: 3), with: .color(tint))
        }.accessibilityHidden(true)
    }
}
