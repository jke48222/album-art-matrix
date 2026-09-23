import SwiftUI

struct AskPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @State private var reader = AnswerReader()
    @State private var question = ""
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var readVersion = 0
    @State private var submittedQuestion = ""
    @State private var answer: String?
    @State private var answerWasShown = false
    @State private var requestedWall = true
    @State private var problem: String?
    @State private var onWall = true
    @State private var status: AskStatus?
    @State private var statusFailed = false
    @State private var loaded = false
    @State private var serviceState: WallServices?
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @FocusState private var typing: Bool

    private let violet = Color(hex: 0xC9B4EB)
    private var typed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var pending: Bool { busy || status?.pending == true }
    private var connected: Bool { wall.link.isLive }
    private var history: [AskStatus.Item] {
        (status?.history ?? []).filter { !($0.q == submittedQuestion && $0.a == answer) }
    }

    var body: some View {
        MessagePage(title: "Ask the wall", eyebrow: "A CONVERSATION WITH YOUR ROOM", tint: violet) {
            if answer == nil { introduction }
            connectionStatus
            if let answer { answerCard(answer) }
            composer
            if pending {
                HStack(alignment: .top, spacing: 14) {
                    ProgressView().tint(violet).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("The wall is thinking").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text("You can leave this page. The answer will be kept in Recent questions.")
                            .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18).messageSurface()
                    .accessibilityElement(children: .combine)
            }
            if let problem { MessageProblem(text: problem) }
            if !history.isEmpty { recentQuestions }
        }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                await refresh(host: host)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear { reader.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.stop() } }
        .onChange(of: wall.host) { _, _ in
            reader.stop()
            status = nil; loaded = false; statusFailed = false; problem = nil
            answer = nil; submittedQuestion = ""; busy = false; requestID = UUID()
        }
    }

    private var introduction: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(typeSize.isAccessibilitySize ? "A little clarity." : "A little\nclarity.")
                    .font(typeSize.isAccessibilitySize ? .ui(22, .semibold) : .display(46)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your music. Your room.\nWhatever's on your mind.")
                    .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                AskConstellation(tint: violet).frame(width: 112, height: 144).accessibilityHidden(true)
            }
        }.padding(.bottom, 4)
    }

    @ViewBuilder private var connectionStatus: some View {
        if !connected {
            MessageNotice(title: "Connect your wall", detail: "Your question stays here while the wall is offline.", symbol: "wifi.slash", tint: violet)
        } else if !loaded {
            HStack(spacing: 10) { ProgressView().tint(violet); Text("Checking Ask the wall…").font(.ui(14)).foregroundStyle(Ink.dim) }
        } else if statusFailed {
            MessageNotice(title: "Couldn't read the wall", detail: "The connection will retry automatically. Your draft is safe.", symbol: "arrow.clockwise", tint: violet)
        } else if status?.ready != true {
            VStack(alignment: .leading, spacing: 12) {
                MessageNotice(title: "Connect Claude to begin", detail: status?.problem ?? "Add your Claude key once in Services. Your questions use that account.", symbol: "key.horizontal", tint: violet)
                NavigationLink {
                    ServicesPage(accent: accent, services: $serviceState, musicConnected: $musicConnected, musicRefused: $musicRefused)
                } label: {
                    HStack { Text("Open Services"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.ui(15, .semibold)).foregroundStyle(violet).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your question").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                if !question.isEmpty {
                    Button { question = ""; problem = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundStyle(Ink.dim).frame(width: 44, height: 44)
                    }.accessibilityLabel("Clear question").buttonStyle(.plain).disabled(pending)
                }
            }
            TextField("Your question", text: $question, prompt: Text("What played earlier this evening?").foregroundStyle(Ink.dim), axis: .vertical)
                .font(.ui(20)).foregroundStyle(Ink.ink).lineLimit(3...6)
                .focused($typing).disabled(pending).accessibilityLabel("Your question")
                .onChange(of: question) { _, value in
                    if value.count > 2000 { question = String(value.prefix(2000)) }
                    problem = nil
                }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            Toggle(isOn: $onWall) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Answer on the wall").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                    Text("You'll also have a copy here.").font(.ui(12)).foregroundStyle(Ink.dim)
                }
            }.tint(violet).disabled(pending)
            MessageAction(title: pending ? "Waiting for the wall…" : "Ask the wall", symbol: "arrow.up", tint: violet,
                          enabled: connected && !statusFailed && status?.ready == true && !typed.isEmpty && !pending,
                          busy: pending, action: ask)
            if typed.isEmpty && !pending {
                VStack(alignment: .leading, spacing: 2) {
                    prompt("What has played lately?", symbol: "music.note.list")
                    prompt("What's on the wall right now?", symbol: "square.grid.3x3")
                }
            }
            Text("Uses your Claude service. Answers can be mistaken.")
                .font(.ui(11)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(20).messageSurface()
    }

    private func prompt(_ text: String, symbol: String) -> some View {
        Button { question = text; typing = true; Taps.detent() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 19)
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.system(size: 10))
            }.font(.ui(13)).foregroundStyle(Ink.dim).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityHint("Places this suggestion in the question field")
    }

    private func answerCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("THE WALL SAYS", systemImage: "sparkle").font(.machine(9)).foregroundStyle(violet)
                Spacer()
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .foregroundStyle(violet).accessibilityLabel("Share answer")
            }
            Text(submittedQuestion).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.ui(typeSize.isAccessibilitySize ? 17 : 20, .medium)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            readButton(text)
            Label(answerWasShown ? "Sent to the wall" : (requestedWall ? "Saved here · the wall is busy" : "Only shown here"),
                  systemImage: answerWasShown ? "checkmark.circle.fill" : "text.bubble")
                .font(.ui(12)).foregroundStyle(violet).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(violet.opacity(0.075), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(violet.opacity(0.2), lineWidth: 1))
    }

    private var recentQuestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent questions").font(.displayMid(23)).foregroundStyle(Ink.ink)
                Spacer(); Text("\(history.count)").font(.machine(11)).foregroundStyle(Ink.dim)
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.a).font(.ui(16)).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let timestamp = item.ts {
                            Text(Date(timeIntervalSince1970: Double(timestamp)), format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.ui(11)).foregroundStyle(Ink.dim)
                        }
                        readButton(item.a)
                        Button { question = item.q; typing = true; problem = nil } label: {
                            Label("Ask again", systemImage: "arrow.up.left").font(.ui(13, .medium)).frame(minHeight: 44)
                        }.foregroundStyle(violet).buttonStyle(.plain).disabled(pending)
                    }.padding(.top, 14)
                } label: {
                    Text(item.q).font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }.tint(violet).padding(.horizontal, 18).padding(.vertical, 8).messageSurface()
            }
        }
    }

    private func readButton(_ text: String) -> some View {
        Button { reader.toggle(text) } label: {
            Label(reader.text == text ? "Stop reading" : "Read aloud on this iPhone",
                  systemImage: reader.text == text ? "stop.fill" : "speaker.wave.2")
                .font(.ui(13, .medium)).foregroundStyle(violet).frame(minHeight: 44)
        }.buttonStyle(.plain)
    }

    private func refresh(host: String, duringMutation: Bool = false) async {
        guard !busy || duringMutation else { return }
        guard !host.isEmpty else { loaded = true; return }
        readVersion += 1
        let version = readVersion, mutation = requestID
        let result = await AskStatus.read(host: host)
        guard !Task.isCancelled, host == wall.host, mutation == requestID, version == readVersion else { return }
        loaded = true; statusFailed = result == nil
        if let result {
            status = result
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ask-answer"), answer == nil, let item = result.history?.first {
                answer = item.a; submittedQuestion = item.q; requestedWall = false
            }
            #endif
        }
    }

    private func ask() {
        guard connected, status?.ready == true, !typed.isEmpty, !pending else { return }
        typing = false; busy = true; problem = nil
        let host = wall.host, draft = typed, show = onWall, request = UUID()
        requestID = request
        Task {
            let result = await AskStatus.ask(host: host, text: draft, onWall: show)
            guard host == wall.host, request == requestID else { return }
            if result.accepted, let text = result.answer, !text.isEmpty {
                answer = text; submittedQuestion = draft; answerWasShown = result.shown == true; requestedWall = show
                if typed == draft { question = "" }
                Taps.landed()
            } else {
                problem = result.error ?? "The wall returned no answer. Your question is still here; try again."
                Taps.error()
            }
            await refresh(host: host, duringMutation: true)
            busy = false
        }
    }
}

struct NotePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @State private var text = ""
    @State private var minutes: Double = 30
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var readVersion = 0
    @State private var problem: String?
    @State private var receipt: String?
    @State private var countdown: NoteCountdown?
    @State private var preview: UIImage?
    @State private var previewProblem: String?
    @State private var previewRetry = 0
    @State private var phase = 0.5
    @State private var loaded = false
    @State private var statusFailed = false
    @State private var customDuration = false
    @FocusState private var typing: Bool

    private let gold = Color(hex: 0xEBC57F)
    private var typed: String { String(PixelFont.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
    private var connected: Bool { wall.link.isLive }
    private var previewKey: String { "\(wall.host)|\(typed)|\(wall.state.color)|\(wall.state.speed)|\(phase)|\(previewRetry)" }

    var body: some View {
        MessagePage(title: "Notes", eyebrow: "SOMETHING FOR THE ROOM", tint: gold) {
            VStack(alignment: .leading, spacing: 8) {
                Text(typeSize.isAccessibilitySize ? "Leave a little light." : "Leave a\nlittle light.").font(typeSize.isAccessibilitySize ? .ui(22, .semibold) : .display(43)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A few words, for a little while. Then back to your wall.").font(.ui(15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !connected {
                MessageNotice(title: "Your draft stays here", detail: "Reconnect the wall to preview or send this note.", symbol: "wifi.slash", tint: gold)
            }
            if let countdown { activeNote(countdown) }
            if statusFailed {
                Text("Couldn't refresh the current note. Showing the last received state.").font(.ui(13)).foregroundStyle(Ink.dim)
            }
            draftPreview
            composer
            if let problem { MessageProblem(text: problem) }
            if let receipt { Label(receipt, systemImage: "checkmark.circle.fill").font(.ui(14)).foregroundStyle(gold).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                await refresh(host: host)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: "\(previewKey)|\(wall.link.isLive)|\(scenePhase)") {
            if scenePhase == .active { await refreshPreview() }
        }
        .onChange(of: wall.host) { _, _ in countdown = nil; loaded = false; busy = false; receipt = nil; problem = nil; requestID = UUID() }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-note-draft"), text.isEmpty {
                text = "Back at seven. Dinner's in the oven."
            }
            #endif
        }
    }

    private var draftPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color(hex: 0x070807)
                if let preview {
                    Image(uiImage: preview).resizable().interpolation(.none).scaledToFit()
                } else if typed.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft").font(.system(size: 24, weight: .light))
                        Text("Your words, in lights").font(.ui(14))
                    }.foregroundStyle(Ink.dim).padding(20)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.alignleft").font(.system(size: 30, weight: .ultraLight))
                        Text(previewProblem == nil ? "Preparing the wall's pixels" : "Preview unavailable")
                            .font(.ui(14)).multilineTextAlignment(.center)
                    }.foregroundStyle(Ink.dim).padding(20)
                }
            }.frame(maxWidth: .infinity).frame(height: typed.isEmpty ? (typeSize.isAccessibilitySize ? 110 : 80) : (typeSize.isAccessibilitySize ? 140 : 196))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel(typed.isEmpty ? "Empty note preview" : "Draft note rendered using the wall's pixels")
            HStack(alignment: .firstTextBaseline) {
                Text("DRAFT PREVIEW").font(.machine(9)).foregroundStyle(gold)
                Spacer(minLength: 8)
                Text("Not on the wall yet").font(.ui(11)).foregroundStyle(Ink.dim)
            }
            if !typed.isEmpty {
                Slider(value: $phase, in: 0...1).tint(gold).accessibilityLabel("Note preview position")
                    .accessibilityValue("\(Int(phase * 100)) percent")
                if let previewProblem {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(previewProblem).font(.ui(12)).foregroundStyle(Ink.dim)
                        Button { previewRetry += 1 } label: {
                            Label("Retry preview", systemImage: "arrow.clockwise")
                                .font(.ui(13, .semibold)).foregroundStyle(gold).frame(minHeight: 44)
                        }.buttonStyle(.plain).disabled(!connected)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your message").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Spacer(); Text("\(typed.count) / 120").font(.machine(10)).foregroundStyle(Ink.dim)
                }
                TextField("Your message", text: $text, prompt: Text("Dinner's in the oven. Back at seven.").foregroundStyle(Ink.dim), axis: .vertical)
                    .font(.ui(20)).foregroundStyle(Ink.ink).lineLimit(3...5).focused($typing)
                    .accessibilityLabel("Note message").disabled(busy)
                    .onChange(of: text) { _, value in
                        let normalized = PixelFont.normalize(value)
                        if normalized.count > 120 { text = String(normalized.prefix(120)) }
                        receipt = nil; problem = nil
                    }
            }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Keep it up for").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(Int(minutes)) min").font(.machine(13)).foregroundStyle(gold)
                }
                let columns = typeSize.isAccessibilitySize ? 2 : 4
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach([5, 15, 30, 60], id: \.self) { duration in
                        Button { minutes = Double(duration); customDuration = false; receipt = nil; Taps.detent() } label: {
                            Text("\(duration) min").font(.ui(13, .medium)).foregroundStyle(minutes == Double(duration) ? Ink.ground : Ink.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(minutes == Double(duration) ? gold : Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(PressStyle()).accessibilityAddTraits(minutes == Double(duration) ? .isSelected : [])
                    }
                }
                DisclosureGroup(isExpanded: $customDuration) {
                    VStack(spacing: 14) {
                        Slider(value: $minutes, in: 1...720, step: 1).tint(gold).accessibilityLabel("Note duration in minutes")
                        Stepper("\(Int(minutes)) minutes", value: $minutes, in: 1...720, step: 1)
                            .font(.ui(15)).foregroundStyle(Ink.ink).accessibilityLabel("Precise note duration")
                    }.padding(.top, 12)
                } label: { Text("Custom duration").font(.ui(14)).foregroundStyle(Ink.dim).frame(minHeight: 44) }.tint(gold)
                Text("Returns to the previous face when time is up. Choosing another face takes the note down.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.disabled(busy)
            MessageAction(title: busy ? "Waiting for the wall…" : (countdown == nil ? "Put it on the wall" : "Replace the current note"),
                          symbol: "arrow.up.right", tint: gold, enabled: connected && !typed.isEmpty && !busy, busy: busy) { send(clear: false) }
        }.padding(20).messageSurface()
            .onChange(of: minutes) { _, _ in receipt = nil }
    }

    private func activeNote(_ value: NoteCountdown) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let left = value.remaining()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(left > 0 ? "ON THE WALL" : "TIME COMPLETE", systemImage: left > 0 ? "circle.fill" : "checkmark")
                            .font(.machine(9)).foregroundStyle(gold)
                        Text(value.text).font(.displayMid(typeSize.isAccessibilitySize ? 18 : 25)).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize, let frame = wall.frame, wall.state.mode == "ticker" {
                        PanelCanvas(px: [UInt8](frame), duty: 1).frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Live wall frame")
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(left > 0 ? "\(NoteCountdown.duration(left)) left" : "Refreshing the wall…")
                        .font(.machine(typeSize.isAccessibilitySize ? 10 : 13)).foregroundStyle(gold).monospacedDigit()
                    Spacer(minLength: 0)
                    Button { send(clear: true) } label: {
                        Text("Take down").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Ink.hairline, in: Capsule())
                    }.buttonStyle(PressStyle()).disabled(busy || !connected)
                }
            }.padding(20).background(gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(gold.opacity(0.22), lineWidth: 1))
        }
    }

    private func refresh(host: String, duringMutation: Bool = false) async {
        guard !busy || duringMutation else { return }
        readVersion += 1
        let version = readVersion, mutation = requestID
        let result = await NoteStatus.read(host: host)
        guard !Task.isCancelled, host == wall.host, mutation == requestID, version == readVersion else { return }
        loaded = true; statusFailed = result == nil
        if let result {
            let next = NoteCountdown(status: result)
            if let previous = countdown, next == nil {
                receipt = previous.remaining() == 0 ? "Note finished. Your wall is back." : "The note is no longer on the wall."
            }
            countdown = next
        }
    }

    private func refreshPreview() async {
        guard !typed.isEmpty, connected else { preview = nil; previewProblem = nil; return }
        let key = previewKey, host = wall.host, message = typed
        do {
            try await Task.sleep(for: .milliseconds(250))
            var request = try MessageAPI.request(host: host, path: "/ticker/preview", timeout: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": message, "style": "across", "colors": [],
                "color": wall.state.color, "speed": wall.state.speed, "phase": phase])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, key == previewKey else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encoded = json["px"] as? String, let pixels = Data(base64Encoded: encoded),
                  let bitmap = FinishSwatch.bitmap([UInt8](pixels)) else { throw URLError(.badServerResponse) }
            preview = bitmap; previewProblem = nil
        } catch {
            guard !Task.isCancelled, key == previewKey else { return }
            preview = nil; previewProblem = "Couldn't load the draft pixels. Your words are safe."
        }
    }

    private func send(clear: Bool) {
        guard connected, !busy, clear || !typed.isEmpty else { return }
        typing = false; busy = true; problem = nil; receipt = nil
        let host = wall.host, draft = typed, duration = minutes, request = UUID(), noteID = countdown?.id
        requestID = request
        Task {
            let result = clear ? await NoteStatus.clear(host: host, id: noteID) : await NoteStatus.post(host: host, text: draft, minutes: duration)
            guard host == wall.host, request == requestID else { return }
            if result.accepted {
                if clear { countdown = nil; receipt = "Note taken down." }
                else {
                    if typed == draft { text = "" }
                    receipt = "On the wall for \(Int(duration)) minutes."
                }
                Taps.landed()
            } else { problem = result.error; Taps.error() }
            await refresh(host: host, duringMutation: true)
            busy = false
        }
    }
}

private struct MessagePage<Content: View>: View {
    let title: String
    let eyebrow: String
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text(eyebrow).font(.machine(9)).tracking(0.8).foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                content
            }.padding(.horizontal, 22).padding(.bottom, 40)
        }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .background(Ink.ground).tint(tint).navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct MessageNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MessageProblem: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.signal)
            .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct MessageAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) } else { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Ink.ground).padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 54).background(tint, in: RoundedRectangle(cornerRadius: 16))
                .opacity(enabled || busy ? 1 : 0.55)
        }.buttonStyle(PressStyle()).disabled(!enabled)
    }
}

private struct AskConstellation: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 9
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for row in 0..<15 {
                for column in 0..<12 {
                    let x = CGFloat(column) * step + 7, y = CGFloat(row) * step + 8
                    let distance = hypot((x - center.x) / 1.05, (y - center.y) / 1.5)
                    let ring = abs(distance - 31) < 8
                    let cross = abs(x - center.x) < 6 || abs(y - center.y) < 6
                    let alpha = ring ? 0.7 : (cross && distance < 33 ? 0.95 : 0.09)
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: ring ? 4 : 3, height: ring ? 4 : 3), cornerRadius: 1), with: .color(tint.opacity(alpha)))
                }
            }
        }
    }
}

private extension View {
    func messageSurface() -> some View {
        background(Ink.plaster, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}
