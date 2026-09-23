import SwiftUI

/// One draft, one send, in the same place as the selected wall face.
struct TickerWorkbench: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @State private var message = ""
    @State private var style = "across"
    @State private var inks: [String] = []
    @State private var color = Color(hex: 0xF4F1EA)
    @State private var speed = 1.0
    @State private var repeats = true
    @State private var phase = 0.35
    @State private var preview: UIImage?
    @State private var previewProblem: String?
    @State private var sending = false
    @State private var receipt: String?
    @State private var problem: String?
    @State private var initialized = false
    @State private var colouring = false
    @FocusState private var typing: Bool

    private var normalized: String { String(PixelFont.normalize(message).prefix(120)) }
    private var empty: Bool { normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var signature: String { "\(wall.host)|\(normalized)|\(style)|\(inks.joined())|\(color.wallHex)|\(speed)|\(phase)" }
    private var ink: Color { accent.toned(forDark: true) }
    private let motions = [("across", "Across", "arrow.left"), ("up", "Rising", "arrow.up"), ("tilt", "Crawl", "arrow.up.forward")]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("A MESSAGE FOR THE ROOM").font(.machine(8)).tracking(1.1).foregroundStyle(ink)
                Text("Words, in motion.").font(.display(typeSize.isAccessibilitySize ? 18 : 34)).foregroundStyle(Ink.ink)
                Text("A little note. A big entrance.").font(.ui(14)).foregroundStyle(Ink.dim)
            }
            previewPanel
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Message").font(.ui(14, .semibold)); Spacer()
                    Text("\(normalized.count) / 120").font(.machine(10)).foregroundStyle(Ink.dim)
                }
                TextField("Something worth putting in lights", text: $message, axis: .vertical)
                    .font(.ui(19, .medium)).lineLimit(3...5).focused($typing)
                    .padding(16).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityLabel("Ticker message")
                    .onChange(of: message) { _, value in
                        if value.count > 120 { message = String(value.prefix(120)) }
                        receipt = nil; problem = nil
                    }
            }.foregroundStyle(Ink.ink)
            VStack(alignment: .leading, spacing: 10) {
                Text("Motion").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(motions, id: \.0) { motion in
                        Button { style = motion.0; receipt = nil; Taps.detent() } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: motion.2).font(.system(size: 25, weight: .light))
                                HStack { Text(motion.1).font(.ui(14, .semibold)); Spacer(minLength: 0)
                                    if style == motion.0 { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                                }
                            }.foregroundStyle(style == motion.0 ? Ink.ground : Ink.ink)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(style == motion.0 ? ink : Ink.sunk, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(PressStyle()).accessibilityAddTraits(style == motion.0 ? .isSelected : [])
                    }
                }
            }
            DisclosureGroup(isExpanded: $colouring) {
                LetterInker(text: normalized, colors: inks, accent: ink, base: color.wallHex) { inks = $0; receipt = nil }.padding(.top, 16)
            } label: {
                HStack {
                    Text("Letter colours").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                    Spacer()
                    ColorPicker("Base ink", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 44, height: 44)
                }
            }.tint(ink)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Pace").font(.ui(14, .semibold)); Spacer()
                    Text(String(format: "%.1f×", speed)).font(.machine(12)).foregroundStyle(Ink.dim)
                }
                Slider(value: $speed, in: 0.2...3, step: 0.1).tint(ink).accessibilityLabel("Message pace")
                Picker("At the end", selection: $repeats) {
                    Text("Keep looping").tag(true); Text("Once, then music").tag(false)
                }.pickerStyle(.segmented)
                Text(repeats ? "Stays on the wall until you choose another face." : "Returns to album art after the complete message.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Ink.ink)
            if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.ui(13)).foregroundStyle(Ink.signal) }
            if let receipt { Label(receipt, systemImage: "checkmark.circle.fill").font(.ui(13)).foregroundStyle(ink) }
            Button { send() } label: {
                HStack(spacing: 10) {
                    if sending { ProgressView().tint(Ink.ground) }
                    else { Image(systemName: "arrow.up.right") }
                    Text(sending ? "Sending message…" : "Send message").font(.ui(16, .semibold))
                }.foregroundStyle(Ink.ground).frame(maxWidth: .infinity, minHeight: 54)
                    .background(ink, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(PressStyle()).disabled(empty || sending || !(wall.link.isLive || wall.link.isStandIn))
            if !wall.link.isLive && !wall.link.isStandIn {
                Text("Your draft is here. Reconnect the wall to preview or send it.").font(.ui(13)).foregroundStyle(Ink.dim)
            }
        }
        .onAppear {
            guard !initialized else { return }; initialized = true
            message = wall.state.tickerText; style = wall.state.tickerStyle; inks = wall.state.tickerColors
            speed = wall.state.speed; color = Color.wall(hex: wall.state.color); repeats = wall.state.tickerLoop
        }
        .task(id: "\(signature)|\(initialized)|\(wall.link.isLive)|\(scenePhase)") {
            if scenePhase == .active { await refreshPreview() }
        }
        .onChange(of: signature) { _, _ in receipt = nil }
        .onChange(of: repeats) { _, _ in receipt = nil }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(hex: 0x080C0B)
                if let preview { Image(uiImage: preview).resizable().interpolation(.none).scaledToFit() }
                else {
                    VStack(spacing: 8) {
                        Image(systemName: "textformat").font(.system(size: 32, weight: .ultraLight))
                        Text(empty ? "Your words go here" : "Preparing the wall’s pixels").font(.ui(12))
                    }.foregroundStyle(Ink.dim)
                }
            }.aspectRatio(1.65, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 15))
                .accessibilityLabel("Draft ticker rendered by the wall")
            HStack {
                Text("DRAFT PREVIEW").font(.machine(8)).tracking(1)
                Spacer()
                Text("Scrub to read").font(.ui(11))
            }.foregroundStyle(Ink.dim)
            Slider(value: $phase, in: 0...1).tint(ink).accessibilityLabel("Preview position")
                .accessibilityValue("\(Int(phase * 100)) percent")
            if let previewProblem { Text(previewProblem).font(.ui(12)).foregroundStyle(Ink.dim) }
        }
    }

    private func refreshPreview() async {
        guard initialized, wall.link.isLive, let url = URL(string: "http://\(wall.host)/ticker/preview") else {
            preview = nil; previewProblem = wall.link.isStandIn ? "The wall generates this preview when connected." : nil; return
        }
        let key = signature
        do {
            try await Task.sleep(for: .milliseconds(250))
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": normalized, "style": style, "colors": inks,
                "color": color.wallHex, "speed": speed, "phase": phase])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, signature == key else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encoded = json["px"] as? String, let pixels = Data(base64Encoded: encoded),
                  let bitmap = FinishSwatch.bitmap([UInt8](pixels)) else { throw URLError(.badServerResponse) }
            preview = bitmap; previewProblem = nil
        } catch {
            guard !Task.isCancelled, signature == key else { return }
            preview = nil; previewProblem = "Preview unavailable. Reconnect your updated wall and try again."
        }
    }

    private func send() {
        typing = false; sending = true; problem = nil; receipt = nil
        let text = normalized, motion = style, colors = inks, hex = color.wallHex, pace = speed, loop = repeats
        let key = signature
        Task {
            let accepted = await wall.sendTicker(text: text, style: motion, colors: colors, color: hex, speed: pace, loop: loop)
            sending = false
            if accepted {
                if key == signature && loop == repeats { receipt = wall.link.isStandIn ? "Playing in your phone preview" : "Message accepted by your wall" }
                Taps.landed()
            } else { problem = "The wall didn’t accept the message. Your draft is safe; try again."; Taps.error() }
        }
    }
}
