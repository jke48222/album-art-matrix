import SwiftUI

struct VoicePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @State private var status: VoiceStatus?
    @State private var meter: VoiceMeter?
    @State private var loaded = false
    @State private var stale = false
    @State private var said = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var requestID = UUID()
    @State private var threshold = 0.5
    @State private var editingThreshold = false
    @State private var tuning = false
    @State private var enrollDestination = false
    @State private var debugDestinationOpened = false
    @State private var lastAnnouncedState: String?
    @State private var serviceState: WallServices?
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @FocusState private var typing: Bool
    private let violet = Color(hex: 0xBEAFEA)
    private var available: Bool { wall.link.isLive && status?.on == true && !stale }
    private var state: String { meter?.state ?? status?.state ?? "idle" }
    private var canListen: Bool { available && state == "idle" && meter?.mic_available != false && !busy }
    private var typed: String { said.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VoicePageLayout(title: "Voice", eyebrow: "A VOICE IN THE ROOM", tint: violet) {
            hero
            if let problem { VoiceProblem(text: problem) }
            if let issue = status?.problem ?? status?.wake_problem ?? status?.wake?.problem ?? status?.speech?.problem {
                VoiceProblem(text: issue)
            }
            if !wall.link.isLive {
                VoiceNotice(title: "Your wall is offline", detail: "Reconnect to use its microphone. Your typed command stays here.", symbol: "wifi.slash", tint: violet)
            } else if stale {
                VoiceNotice(title: "Waiting for the wall", detail: "Live levels are unavailable. Reconnecting automatically.", symbol: "arrow.clockwise", tint: violet)
            } else if loaded && status?.on != true {
                VStack(alignment: .leading, spacing: 10) {
                    VoiceNotice(title: "Voice is switched off", detail: "Enable Voice in Services to use the wall’s microphone and wake word.", symbol: "mic.slash", tint: violet)
                    NavigationLink {
                        ServicesPage(accent: accent, services: $serviceState, musicConnected: $musicConnected, musicRefused: $musicRefused)
                    } label: {
                        HStack { Text("Open Services"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.ui(15, .semibold)).foregroundStyle(violet).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            } else if meter?.mic_available == false {
                VoiceNotice(title: "No microphone signal", detail: "Check the microphone connected to the wall. Typed commands still work.", symbol: "mic.slash", tint: violet)
            }
            commandComposer
            wakeWord
            recent
            VoiceNotice(title: "The microphone is on your wall", detail: "Wake-word matching and speech recognition happen on the wall. Questions use your connected Claude account; searches use their connected services.", symbol: "waveform", tint: Ink.dim)
        }
        .navigationDestination(isPresented: $enrollDestination) { WakeEnrollPage(accent: violet) }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-voice-tuning") { tuning = true }
            if !debugDestinationOpened && ProcessInfo.processInfo.arguments.contains("-voice-enroll") {
                debugDestinationOpened = true; enrollDestination = true
            }
            #endif
        }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            var tick = 0
            while !Task.isCancelled {
                if tick % 4 == 0 { await refresh(host: host) }
                let meterVersion = requestID
                if let reading = await VoiceMeter.read(host: host), !Task.isCancelled, host == wall.host, meterVersion == requestID {
                    meter = reading
                    if lastAnnouncedState != reading.state {
                        lastAnnouncedState = reading.state
                        if ["listening", "thinking", "answering", "missed"].contains(reading.state ?? "") {
                            UIAccessibility.post(notification: .announcement, argument: stateTitle)
                        }
                    }
                } else if !Task.isCancelled, host == wall.host, meterVersion == requestID { meter = nil }
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: wall.host) { _, _ in
            requestID = UUID(); busy = false; status = nil; meter = nil; loaded = false; stale = false
            problem = nil; editingThreshold = false; lastAnnouncedState = nil
        }
    }

    private var stateTitle: String {
        if !wall.link.isLive { return "A quiet connection." }
        if !loaded { return "Finding your voice." }
        if stale { return "One moment." }
        if status?.on != true { return "Voice is resting." }
        if state == "idle" && meter?.mic_available == false { return "A quiet microphone." }
        switch state {
        case "listening": return "I’m listening."
        case "thinking": return "A little thought."
        case "answering": return "On your wall."
        case "enrolling": return "Learning your voice."
        case "missed": return "Say that again?"
        default: return "Just say the word."
        }
    }

    private var stateDetail: String {
        if !wall.link.isLive { return "Voice will be here when your wall reconnects." }
        if !loaded { return "Checking the wall’s microphone and wake word." }
        if stale { return "The last status is out of date." }
        if status?.on != true { return "Turn on Voice to start a conversation." }
        if state == "idle" && meter?.mic_available == false { return "The wall isn’t receiving audio. You can still type a command below." }
        switch state {
        case "listening": return "Speak toward the wall. A short pause finishes your request."
        case "thinking": return "Working through what you said."
        case "answering": return "Your answer is appearing on the panel."
        case "enrolling": return "Continue your phrase in Wake word & sensitivity."
        case "missed": return "The wall didn’t catch that. Try a little closer."
        default: return "Say “\(status?.wake?.label ?? "the wake word")”, then ask for what you want."
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(spacing: 8) {
                Circle().fill(available ? violet : Ink.dim).frame(width: 6, height: 6)
                Text(available ? "WALL MICROPHONE" : "VOICE CONNECTION").font(.machine(9)).tracking(1).foregroundStyle(violet)
                Spacer()
                if busy || !loaded && wall.link.isLive { ProgressView().controlSize(.small).tint(violet) }
            }.accessibilityHidden(true)
            Text(stateTitle).font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(44))
                .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(stateDetail).font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            VoiceSignal(level: available ? meter?.level_over : nil, tint: violet).frame(height: 67)
                .accessibilityLabel("Wall microphone level")
                .accessibilityValue(meter?.mic_available == false ? "Unavailable" : meter?.level_over.map { String(format: "%.0f decibels above the room", $0) } ?? "Not available")
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE WALL").font(.machine(9)).tracking(0.8).foregroundStyle(Ink.dim)
                    Text(wall.state.mode == "off" ? "The panel is resting" : "Exactly what’s on the panel")
                        .font(.ui(13)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if wall.link.isLive, let data = wall.frame, let bitmap = FinishSwatch.bitmap([UInt8](data)) {
                    Image(uiImage: bitmap).resizable().interpolation(.none).frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Current wall frame")
                } else {
                    Image(systemName: "square.dashed").font(.system(size: 32)).foregroundStyle(Ink.dim)
                        .frame(width: 58, height: 58).accessibilityLabel("Wall frame unavailable")
                }
            }.padding(.top, 15).overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
            VoiceAction(title: state == "listening" ? "Listening at the wall" : "Listen now", symbol: "mic.fill", tint: violet, enabled: canListen, busy: busy) {
                send(path: "/voice/wake", body: [:])
            }
        }.padding(22).voiceSurface()
    }

    private var commandComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Or type a command").font(.ui(18, .semibold)).foregroundStyle(Ink.ink); Spacer(); Image(systemName: "keyboard").foregroundStyle(violet).accessibilityHidden(true) }
            TextField("Command", text: $said, prompt: Text("Set a timer for ten minutes").foregroundStyle(Ink.dim), axis: .vertical)
                .font(.ui(19)).foregroundStyle(Ink.ink).lineLimit(2...5).focused($typing)
                .padding(16).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 16))
                .onChange(of: said) { _, value in if value.count > 1000 { said = String(value.prefix(1000)) } }
            if said.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { suggestion("Show the clock"); suggestion("What is playing?") }
                    VStack(alignment: .leading, spacing: 4) { suggestion("Show the clock"); suggestion("What is playing?") }
                }
            }
            VoiceAction(title: "Send to the wall", symbol: "arrow.up", tint: violet, enabled: available && !busy && !typed.isEmpty && ["idle", "listening"].contains(state), busy: false) {
                typing = false; send(path: "/voice/say", body: ["text": typed], clearsDraft: true)
            }
        }
    }

    private func suggestion(_ text: String) -> some View {
        Button { said = text; typing = true; Taps.detent(intensity: 0.3) } label: {
            Text(text).font(.ui(12, .medium)).foregroundStyle(violet).padding(.horizontal, 12).frame(minHeight: 44)
                .background(violet.opacity(0.08), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var wakeWord: some View {
        DisclosureGroup(isExpanded: $tuning) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose the phrase that starts a conversation.").font(.ui(14)).foregroundStyle(Ink.dim)
                ForEach(status?.wake_choices ?? [], id: \.name) { choice in
                    HStack(spacing: 12) {
                        Button { send(path: "/voice/wakeword", body: ["name": choice.name]) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.name == status?.wake?.model ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21)).foregroundStyle(choice.name == status?.wake?.model ? violet : Ink.dim)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.label).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                                    Text(choice.kind == "own" ? "Your phrase" : "Built in").font(.ui(12)).foregroundStyle(Ink.dim)
                                }
                                Spacer(minLength: 0)
                                if choice.name == status?.wake_loading { ProgressView().tint(violet) }
                            }.frame(minHeight: 50).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!available || busy || status?.wake_loading != nil || state != "idle")
                            .accessibilityAddTraits(choice.name == status?.wake?.model ? .isSelected : [])
                        if choice.kind == "own", choice.name != status?.wake?.model {
                            Button { send(path: "/voice/wakeword/forget", body: ["name": choice.name]) } label: {
                                Image(systemName: "trash").foregroundStyle(Ink.dim).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).disabled(!available || busy || status?.wake_loading != nil)
                                .accessibilityLabel("Forget \(choice.label)")
                        }
                    }
                }
                Rule()
                HStack {
                    Text("Wake sensitivity").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(threshold < (status?.wake?.default_threshold ?? 0.5) - 0.07 ? "High" : threshold > (status?.wake?.default_threshold ?? 0.5) + 0.07 ? "Low" : "Balanced")
                        .font(.ui(12, .semibold)).foregroundStyle(violet)
                }
                WakeMeter(accent: violet, threshold: $threshold, meter: meter, onEditing: { editingThreshold = $0 }, onCommit: commitThreshold)
                    .disabled(!available || busy || status?.wake_loading != nil)
                Text("Move left to wake more easily. Move right to reduce accidental wakes.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                if let value = status?.wake?.default_threshold, abs(threshold - value) > 0.02 {
                    Button("Reset sensitivity") { threshold = value; commitThreshold() }.font(.ui(14, .semibold)).foregroundStyle(violet).frame(minHeight: 44).disabled(!available || busy)
                }
                NavigationLink { WakeEnrollPage(accent: violet) } label: {
                    HStack(spacing: 12) { Image(systemName: "waveform.badge.plus"); Text(state == "enrolling" ? "Continue learning your phrase" : "Teach your own phrase"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                        .font(.ui(15, .semibold)).foregroundStyle(violet).frame(minHeight: 50)
                }.buttonStyle(.plain)
            }.padding(.top, 20)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("Wake word & sensitivity").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                Text(status?.wake?.label ?? "Waiting for the wall").font(.ui(14)).foregroundStyle(Ink.dim)
            }.padding(.vertical, 7)
        }.tint(violet).padding(18).voiceSurface()
    }

    @ViewBuilder private var recent: some View {
        let items = status?.history ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recently heard").font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.problem == nil ? "quote.opening" : "exclamationmark.circle").foregroundStyle(violet).accessibilityHidden(true)
                            Text(item.text).font(.ui(17, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        }
                        if let response = item.problem ?? item.answer ?? item.command {
                            Text(response).font(.ui(14)).foregroundStyle(item.problem == nil ? Ink.dim : Ink.signal).fixedSize(horizontal: false, vertical: true)
                        }
                    }.textSelection(.enabled).padding(17).voiceSurface()
                }
            }
        } else if let text = status?.last_text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last heard").font(.ui(18, .semibold)).foregroundStyle(Ink.ink)
                Text(text).font(.ui(17)).foregroundStyle(Ink.ink)
                if let result = status?.last_answer ?? status?.last_command { Text(result).font(.ui(14)).foregroundStyle(Ink.dim) }
            }.textSelection(.enabled).padding(18).voiceSurface()
        }
    }

    private func refresh(host: String) async {
        let version = requestID
        let result = await VoiceStatus.read(host: host)
        guard !Task.isCancelled, host == wall.host, version == requestID else { return }
        loaded = true; stale = result == nil
        if let result {
            status = result
            if !editingThreshold && !busy, let value = result.wake?.threshold { threshold = min(0.95, max(0.3, value)) }
        }
    }

    private func commitThreshold() {
        var body: [String: Any] = ["threshold": (threshold * 100).rounded() / 100]
        if let model = status?.wake?.model { body["expected_model"] = model }
        send(path: "/voice/wakeword", body: body)
    }

    private func send(path: String, body: [String: Any], clearsDraft: Bool = false) {
        guard wall.link.isLive, !busy else { return }
        let host = wall.host, request = UUID(), originalDraft = said
        requestID = request; busy = true; problem = nil
        Task {
            let (code, json) = await VoiceStatus.send(host: host, path: path, body: body)
            guard host == wall.host, request == requestID else { return }
            if code == 200 {
                meter = nil
                if let data = try? JSONSerialization.data(withJSONObject: json), let updated = try? JSONDecoder().decode(VoiceStatus.self, from: data) {
                    status = updated
                    if let value = updated.wake?.threshold { threshold = min(0.95, max(0.3, value)) }
                }
                if clearsDraft && said == originalDraft { said = "" }
                Taps.commit()
            } else {
                problem = json["error"] as? String ?? (code == 409 ? "The wall is busy. Wait a moment, then try again." : "The wall didn’t confirm that change. Please try again.")
                if let confirmed = status?.wake?.threshold { threshold = confirmed }
            }
            busy = false
            await refresh(host: host)
        }
    }
}

struct WakeMeter: View {
    let accent: Color
    @Binding var threshold: Double
    var meter: VoiceMeter?
    var onEditing: (Bool) -> Void = { _ in }
    var onCommit: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.sunk)
                    Capsule().fill(accent.opacity(0.25)).frame(width: geometry.size.width * unit(meter?.peak))
                    Capsule().fill(accent).frame(width: geometry.size.width * unit(meter?.score))
                }
            }.frame(height: 8).accessibilityHidden(true)
            Slider(value: $threshold, in: 0.3...0.95, step: 0.01) { Text("Wake threshold") } onEditingChanged: { editing in
                onEditing(editing); if !editing { onCommit() }
            }.tint(accent).frame(minHeight: 44)
                .accessibilityLabel("Wake sensitivity threshold")
                .accessibilityValue("\(Int((threshold * 100).rounded())) percent. Lower wakes more easily.")
            HStack {
                Text("More sensitive"); Spacer(); Text("Less sensitive")
            }.font(.ui(12)).foregroundStyle(Ink.dim).accessibilityHidden(true)
        }.animation(reducedMotion ? nil : .easeOut(duration: 0.18), value: meter?.score)
    }
    private func unit(_ value: Double?) -> CGFloat { CGFloat(min(1, max(0, value ?? 0))) }
}

private struct VoiceSignal: View {
    let level: Double?
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let amount = min(1, max(0, (level ?? 0) / 30))
            let count = 39
            for index in 0..<count {
                let x = CGFloat(index) / CGFloat(count - 1) * size.width
                let envelope = sin(Double(index) / Double(count - 1) * .pi)
                let shape = 0.4 + 0.6 * abs(sin(Double(index) * 1.8))
                let height = 3 + amount * envelope * shape * (size.height - 6)
                let rect = CGRect(x: x - 1.5, y: (size.height - height) / 2, width: 3, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint.opacity(level == nil ? 0.2 : 0.8)))
            }
        }
    }
}

private struct VoicePageLayout<Content: View>: View {
    let title: String
    let eyebrow: String
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text(eyebrow).font(.machine(9)).tracking(1).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true).padding(.top, 14).accessibilityHidden(true)
                content
            }.padding(.horizontal, 22).padding(.bottom, 40)
        }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively).background(Ink.ground).tint(tint)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct VoiceNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct VoiceProblem: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.signal)
            .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct VoiceAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) } else { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Ink.ground).padding(16).frame(maxWidth: .infinity, minHeight: 54)
                .background(tint.opacity(enabled || busy ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(PressStyle()).disabled(!enabled)
    }
}

private extension View {
    func voiceSurface() -> some View {
        background(Ink.plaster, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}

struct WakeEnrollPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let accent: Color
    @State private var phrase = ""
    @State private var enroll: EnrollState?
    @State private var problem: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var stale = false
    @State private var requestID = UUID()
    @State private var lastStage = ""
    @State private var lastTakes = 0
    @State private var dismissedResult = false
    @FocusState private var typing: Bool
    private var typed: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var active: Bool { ["takes", "talk", "building"].contains(enroll?.stage ?? "") }

    var body: some View {
        VoicePageLayout(title: "Your wake word", eyebrow: "MADE FOR YOUR VOICE", tint: accent) {
            Text(active ? "Make it yours." : enroll?.stage == "done" ? "A familiar voice." : "A phrase\nonly you choose.")
                .font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(42)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !loaded && wall.link.isLive { ProgressView("Checking for an existing session…").font(.ui(14)).tint(accent) }
            if !wall.link.isLive || stale {
                VoiceNotice(title: "Reconnect to continue", detail: "The wall keeps your current session while this page reconnects.", symbol: "wifi.slash", tint: accent)
            }
            if active, let enrollment = enroll { progressCard(enrollment) }
            else if let enrollment = enroll, enrollment.stage == "done" { doneCard(enrollment) }
            else { composer }
            if let problem { VoiceProblem(text: problem) }
            if let enrollment = enroll, ["failed", "cancelled"].contains(enrollment.stage) {
                VoiceProblem(text: enrollment.problem ?? enrollment.message)
            }
            if !active && enroll?.stage != "done" {
                VStack(alignment: .leading, spacing: 22) {
                    instruction("01", title: "Choose a little phrase", detail: "Two or three words that you wouldn’t say by accident.")
                    instruction("02", title: "Say it six times", detail: "Stand where you usually talk to the wall. Pause after each take.")
                    instruction("03", title: "Let the room sound normal", detail: "Talk naturally for ten seconds. This helps the wall avoid accidental wakes.")
                }
            }
            VoiceNotice(title: "Learned on your wall", detail: "The wall uses its own microphone. People who will use the phrase can share the six takes.", symbol: "mic", tint: Ink.dim)
        }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            while !Task.isCancelled {
                let version = requestID
                let status = await VoiceStatus.read(host: host)
                guard !Task.isCancelled, host == wall.host else { return }
                if version == requestID {
                    loaded = true; stale = status == nil
                    if let update = status?.enroll, !dismissedResult || ["takes", "talk", "building"].contains(update.stage) {
                        accept(update)
                    }
                }
                try? await Task.sleep(for: .milliseconds(active ? 400 : 1500))
            }
        }
        .onChange(of: wall.host) { _, _ in
            requestID = UUID(); busy = false; enroll = nil; loaded = false; stale = false; problem = nil; dismissedResult = false
            lastStage = ""; lastTakes = 0
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your phrase").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
            TextField("Wake phrase", text: $phrase, prompt: Text("Hey Tessera").foregroundStyle(Ink.dim))
                .font(.ui(23)).foregroundStyle(Ink.ink).textInputAutocapitalization(.words).submitLabel(.done).focused($typing)
                .onChange(of: phrase) { _, value in if value.count > 40 { phrase = String(value.prefix(40)) } }
            Text("The wall will listen after you tap Start.").font(.ui(13)).foregroundStyle(Ink.dim)
            VoiceAction(title: busy ? "Starting…" : "Start learning", symbol: "waveform.badge.plus", tint: accent,
                        enabled: wall.link.isLive && loaded && !stale && typed.count >= 3 && !busy, busy: busy) { start() }
        }.padding(20).voiceSurface()
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.machine(11)).foregroundStyle(accent).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func progressCard(_ value: EnrollState) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("“\(value.phrase)”").font(typeSize.isAccessibilitySize ? .ui(23, .semibold) : .display(32)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(0..<max(0, min(10, value.samples)), id: \.self) { index in
                    let complete = index < value.takes
                    ZStack {
                        Circle().fill(complete ? accent : Ink.sunk)
                        Circle().strokeBorder(index == value.takes && value.stage == "takes" ? accent : Ink.hairline, lineWidth: 1)
                        if complete { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.ground) }
                    }.frame(maxWidth: 36).aspectRatio(1, contentMode: .fit)
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel("\(value.takes) of \(value.samples) phrases recorded")
            Text(value.message).font(.ui(18, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            if value.stage == "takes" {
                VoiceSignal(level: value.level_over, tint: accent).frame(height: 60).accessibilityHidden(true)
                Text(value.recording == true ? "Recording this take" : "Waiting for your next phrase")
                    .font(.ui(13)).foregroundStyle(Ink.dim)
            } else if value.stage == "talk" {
                let total = max(1, value.talk_s ?? 10)
                let left = max(0, min(total, value.talk_left ?? total))
                ProgressView(value: total - left, total: total).tint(accent)
                    .accessibilityLabel("Room sound recording").accessibilityValue("\(Int(left.rounded(.up))) seconds remaining")
                Text("\(Int(left.rounded(.up))) seconds · talk about anything else").font(.ui(14)).foregroundStyle(Ink.dim)
            } else {
                HStack(spacing: 12) { ProgressView().tint(accent); Text("Finding what makes your phrase distinct.").font(.ui(14)).foregroundStyle(Ink.dim) }
            }
            if value.stage != "building" {
                Button("Stop this session") { cancel() }.font(.ui(15, .semibold)).foregroundStyle(accent)
                    .frame(minHeight: 44).disabled(!wall.link.isLive || busy)
            }
        }.padding(22).voiceSurface().animation(reducedMotion ? nil : Motion.settle, value: value.takes)
    }

    private func doneCard(_ value: EnrollState) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(accent).accessibilityHidden(true)
            Text("“\(value.phrase)” is ready.").font(.ui(24, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(qualityLine(value.quality)).font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            VoiceAction(title: "Try your wake word", symbol: "mic", tint: accent, enabled: true, busy: false) { dismiss() }
            Button("Record it again") { phrase = value.phrase; enroll = nil; dismissedResult = true }
                .font(.ui(15, .semibold)).foregroundStyle(accent).frame(minHeight: 44)
        }.padding(22).voiceSurface()
    }

    private func qualityLine(_ quality: String?) -> String {
        switch quality {
        case "good": "Your phrase is distinct from everyday conversation. It is now the wall’s wake word."
        case "fair": "Your phrase is ready. If it wakes by accident, lower the sensitivity on the Voice page."
        default: "Your phrase is ready, but sounds similar to ordinary talk. A longer or less common phrase may work better."
        }
    }

    private func accept(_ value: EnrollState) {
        enroll = value
        if lastStage != value.stage || lastTakes != value.takes {
            if value.stage == "done" || value.takes > lastTakes { Taps.commit() }
            UIAccessibility.post(notification: .announcement, argument: value.message)
            lastStage = value.stage; lastTakes = value.takes
        }
    }

    private func start() {
        guard !busy, wall.link.isLive, typed.count >= 3 else { return }
        typing = false
        mutate(path: "/voice/enroll", body: ["phrase": typed, "samples": 6])
    }

    private func cancel() { mutate(path: "/voice/enroll/cancel", body: [:]) }

    private func mutate(path: String, body: [String: Any]) {
        guard !busy, wall.link.isLive else { return }
        let host = wall.host, version = UUID()
        requestID = version; busy = true; problem = nil
        Task {
            let (code, json) = await VoiceStatus.send(host: host, path: path, body: body)
            guard version == requestID, host == wall.host else { return }
            if code == 200 {
                dismissedResult = false
                if let object = json["enroll"], let data = try? JSONSerialization.data(withJSONObject: object), let value = try? JSONDecoder().decode(EnrollState.self, from: data) {
                    accept(value)
                } else if path.hasSuffix("cancel") { enroll = nil; dismissedResult = true }
                else { problem = "The wall didn’t return the learning session. Reconnecting…" }
            } else { problem = json["error"] as? String ?? "The wall didn’t confirm that. Please try again." }
            busy = false
        }
    }
}
