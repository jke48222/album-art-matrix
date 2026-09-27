import SwiftUI

struct ImagesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var key = ""
    @State private var busy = false
    @State private var loading = true
    @State private var readFailed = false
    @State private var editing = false
    @State private var removing = false
    @State private var switchingTo: String?
    @State private var problem: String?
    @State private var feedback: String?
    @State private var revision = UUID()
    @State private var sourceHost = ""
    private let sage = Color(hex: 0xBCD3B9)
    private var im: WallServices.Images? { services?.images }
    private var ready: Bool { im?.ready == true }
    private var provider: String { im?.provider ?? "openai" }
    private var providerName: String { provider == "google" ? "Google" : "OpenAI" }
    private var quality: String { im?.quality ?? "medium" }
    private var working: Bool { busy || im?.busy == true || im?.pending_change == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        wall.link.isLive && services != nil && !working && typedKey.range(of: "^[A-Za-z0-9_-]{20,300}$", options: .regularExpression) != nil
    }
    private var statusTitle: String {
        if !wall.link.isLive { return "Wall offline" }
        if loading && im == nil { return "Reading the image engine" }
        if readFailed { return "Status unavailable" }
        if im?.pending_change == true { return "Settings waiting for this drawing" }
        if im?.busy == true { return "Drawing with \(providerName)" }
        if im?.problem != nil { return "The last creation needs attention" }
        if im?.verified == true { return "\(providerName), image received" }
        return ready ? "\(providerName) key saved" : "Choose an engine, add your key"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !wall.link.isLive {
                    CreativeConnectionNotice(title: "Your wall is offline", detail: "Reconnect to change providers or keys. Saved status may be out of date.", symbol: "wifi.slash", tint: sage)
                } else if readFailed {
                    CreativeConnectionNotice(title: "Couldn't read image settings", detail: "Your wall's provider and saved artwork haven't changed.", symbol: "exclamationmark.circle", tint: sage)
                    Button("Read again") { Task { await refresh() } }.font(.ui(15, .semibold)).foregroundStyle(sage).frame(minHeight: 44)
                }
                if loading && im == nil {
                    ProgressView("Reading image settings").tint(sage).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    if let issue = problem ?? im?.problem {
                        CreativeConnectionNotice(title: "Before the next picture", detail: issue, symbol: "exclamationmark.circle", tint: sage)
                            .accessibilityIdentifier("images.problem")
                    }
                    if im?.busy == true {
                        CreativeConnectionNotice(title: "A picture is in progress", detail: im?.pending_change == true ? "The current provider will finish its request. Your saved settings take effect afterward." : "Open Imagine to follow the canvas. Provider settings can be changed when it finishes.", symbol: "paintbrush.pointed", tint: sage)
                    }
                    if ready { imagineLink }
                    providerPicker
                    if let target = switchingTo { switchConfirmation(target) }
                    if ready { keyManagement } else { credentials }
                    qualitySection
                    modelFacts
                    if let last = im?.last { latestCreation(last) }
                    if let feedback {
                        Label(feedback, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(sage).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("images.notice")
                    }
                }
                privacy
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(Color(hex: 0x141915)).foregroundStyle(Ink.ink)
            .navigationTitle("Images").navigationBarTitleDisplayMode(.inline).tint(sage)
            .refreshable { await refresh() }
            .task(id: "\(wall.host)|\(scenePhase)") {
                guard scenePhase == .active else { return }
                if sourceHost.isEmpty { sourceHost = wall.host }
                else if sourceHost != wall.host { reset(host: wall.host) }
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(im?.busy == true ? 2 : 8))
                }
            }
            .onChange(of: wall.host) { _, host in reset(host: host) }
            .onChange(of: provider) { _, _ in key = ""; removing = false; switchingTo = nil }
            .onDisappear { key = ""; revision = UUID(); busy = false }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 18) {
            HStack(spacing: 10) {
                Image(systemName: "paintbrush.pointed").font(.system(size: 21, weight: .medium))
                Text(typeSize.isAccessibilitySize ? "IMAGE ENGINE" : "THE IMAGE ENGINE").font(.machine(typeSize.isAccessibilitySize ? 10 : 11)).tracking(typeSize.isAccessibilitySize ? 0 : 1.7)
                Spacer(minLength: 0)
            }.foregroundStyle(sage)
            if !typeSize.isAccessibilitySize {
                Text("Image provider").font(.display(39)).tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                ImageEngineStudy(tint: sage).frame(height: 78).accessibilityHidden(true)
            }
            Group {
                if typeSize.isAccessibilitySize { Text(statusTitle) }
                else { Label(statusTitle, systemImage: !wall.link.isLive ? "wifi.slash" : im?.verified == true ? "checkmark.circle" : "circle.dotted") }
            }.font(.ui(typeSize.isAccessibilitySize ? 12 : 14, .medium)).foregroundStyle(sage).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("images.status")
        }
    }
    private var imagineLink: some View {
        NavigationLink { ImaginePage(accent: accent) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(im?.busy == true ? "Follow this drawing" : "Open Imagine").font(.ui(typeSize.isAccessibilitySize ? 17 : 22, .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !typeSize.isAccessibilitySize { Text("Describe a picture in Imagine").font(.ui(14)).foregroundStyle(Color(hex: 0x3C5141)) }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { Image(systemName: "arrow.up.right").font(.system(size: 22, weight: .medium)) }
            }.foregroundStyle(Color(hex: 0x1C2A20)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(sage, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier("images.openImagine")
    }
    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who draws").font(.ui(22, .semibold))
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                providerTile("openai", name: "OpenAI", family: "GPT Image", number: "01")
                providerTile("google", name: "Google", family: "Imagen", number: "02")
            }
        }
    }
    private func providerTile(_ value: String, name: String, family: String, number: String) -> some View {
        Button {
            guard value != provider, !working else { return }
            Taps.detent(intensity: 0.4)
            if ready || !key.isEmpty { switchingTo = value }
            else { change(["provider": value, "api_key": "", "model": ""], receipt: "\(name) selected. Add its API key to begin.") }
        } label: {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 8 : 19) {
                if !typeSize.isAccessibilitySize {
                    HStack {
                        Text(number).font(.machine(11)).foregroundStyle(provider == value ? Color(hex: 0x455D49) : Ink.dim)
                        Spacer(minLength: 0)
                        Image(systemName: provider == value ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(provider == value ? Color(hex: 0x344A39) : Ink.dim)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.ui(typeSize.isAccessibilitySize ? 16 : 19, .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(family).font(.ui(12)).opacity(0.72).fixedSize(horizontal: false, vertical: true)
                    }
                    if typeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        Image(systemName: provider == value ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).padding(.top, 6)
                    }
                }
            }.foregroundStyle(provider == value ? Color(hex: 0x1C2A20) : Ink.ink).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(provider == value ? sage : Ink.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).disabled(working || !wall.link.isLive || services == nil)
            .accessibilityLabel("\(name), \(family)").accessibilityValue(provider == value ? "Selected" : "Not selected")
            .accessibilityIdentifier("images.provider.\(value)")
    }
    private func switchConfirmation(_ target: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Switch to \(target == "google" ? "Google" : "OpenAI")?").font(.ui(18, .semibold))
            Text("The current provider's key will be removed from this wall. Add the new provider's key next. Your saved pictures stay in Imagine.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            CreativeConnectionAction(title: "Switch provider", tint: sage, enabled: !working && wall.link.isLive) {
                change(["provider": target, "api_key": "", "model": ""], receipt: "Provider changed. Add its API key to begin.")
            }.accessibilityIdentifier("images.confirmSwitch")
            Button("Keep \(providerName)") { switchingTo = nil }.font(.ui(15, .medium)).frame(minHeight: 44).foregroundStyle(sage)
                .accessibilityIdentifier("images.cancelSwitch")
        }.padding(18).background(sage.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
    }
    private var keyManagement: some View {
        DisclosureGroup(isExpanded: $editing) { credentials.padding(.top, 18) } label: {
            Text("Manage \(providerName) key").font(.ui(17, .semibold)).foregroundStyle(Ink.ink).frame(minHeight: 48)
                .accessibilityIdentifier("images.manage")
        }.tint(sage)
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ready ? "Your \(providerName) connection" : "Connect \(providerName)").font(.ui(22, .semibold)).fixedSize(horizontal: false, vertical: true)
            CreativeCredentialField(title: provider == "google" ? "Gemini API key" : "OpenAI API key", hint: ready ? "Paste a replacement key" : provider == "google" ? "Paste your Gemini API key" : "sk-…", text: $key, secure: true)
                .accessibilityIdentifier("images.key")
            CreativeConnectionAction(title: busy ? "Saving…" : "Save API key", tint: sage, busy: busy, enabled: canSave) {
                change(["api_key": typedKey, "provider": provider], receipt: "Key saved. Image access is confirmed when you create in Imagine.")
            }.accessibilityIdentifier("images.save")
            Button { openURL(URL(string: provider == "google" ? "https://aistudio.google.com/apikey" : "https://platform.openai.com/api-keys")!) } label: {
                Label(provider == "google" ? "Get a key in Google AI Studio" : "Get a key in OpenAI Platform", systemImage: "arrow.up.right").font(.ui(14, .medium)).frame(minHeight: 44)
            }.foregroundStyle(sage)
            Text("Saving a key doesn't generate an image or confirm billing access. Creation requests use your provider's API billing, separately from a chat subscription.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if ready {
                Divider().overlay(sage.opacity(0.15))
                if removing {
                    Text("Remove this key? Creating new pictures will stop. Your collection remains available in Imagine.").font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Remove API key", role: .destructive) { change(["api_key": ""], receipt: "API key removed. Your saved artwork is still in Imagine.") }
                        .font(.ui(15, .semibold)).frame(minHeight: 44).disabled(working || !wall.link.isLive).accessibilityIdentifier("images.confirmRemove")
                    Button("Keep connected") { removing = false }.font(.ui(15)).frame(minHeight: 44)
                } else {
                    Button("Remove key from this wall", role: .destructive) { removing = true }.font(.ui(14, .medium)).frame(minHeight: 44)
                        .disabled(working || !wall.link.isLive).accessibilityIdentifier("images.remove")
                }
            }
        }
    }
    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("The level of detail").font(.ui(22, .semibold)).fixedSize(horizontal: false, vertical: true)
            if provider == "google" {
                CreativeConnectionFact(title: "Quality", value: "Set by your Imagen model")
                Text("Google uses the selected model's output settings. OpenAI's low, medium and high choices don't apply here.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(["low", "medium", "high"], id: \.self) { value in
                    Button { change(["quality": value], receipt: "\(value.capitalized) quality saved for the next picture.") } label: {
                        HStack(alignment: .center, spacing: 16) {
                            Image(systemName: quality == value ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(quality == value ? sage : Ink.dim)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(value.capitalized).font(.ui(16, .semibold))
                                Text(value == "low" ? "A quicker study" : value == "medium" ? "A balance of speed and detail" : "More detail, longer to draw").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(working || !wall.link.isLive || services == nil || quality == value)
                        .accessibilityValue(quality == value ? "Selected" : "Not selected").accessibilityIdentifier("images.quality.\(value)")
                }
                Text("Cost and timing depend on the model and your provider. The wall keeps the full image and adapts it to the panel.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var modelFacts: some View {
        VStack(alignment: .leading, spacing: 15) {
            Divider().overlay(sage.opacity(0.15))
            CreativeConnectionFact(title: "Requested model", value: im?.model ?? "Not reported")
            if let used = im?.model_used, !used.isEmpty {
                CreativeConnectionFact(title: "Last model used", value: used)
                if used != im?.model { Text("The requested model wasn't available to this key. The wall used the supported model above.").font(.ui(13)).foregroundStyle(Ink.dim) }
            }
            CreativeConnectionFact(title: "Pictures created", value: im?.images.map(String.init) ?? "Not reported")
            Divider().overlay(sage.opacity(0.15))
        }
    }
    private func latestCreation(_ last: WallServices.Images.Last) -> some View {
        NavigationLink { ImaginePage(accent: accent) } label: {
            HStack(alignment: .center, spacing: 16) {
                if !typeSize.isAccessibilitySize {
                    AsyncImage(url: WallImagined.imageURL(host: wall.host, id: last.id)) { image in image.resizable().scaledToFill() } placeholder: {
                        ZStack { sage.opacity(0.07); Image(systemName: "photo").foregroundStyle(sage.opacity(0.5)) }
                    }.frame(width: 70, height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last creation").font(.ui(12, .medium)).foregroundStyle(sage)
                    Text(last.prompt).font(.ui(16, .medium)).foregroundStyle(Ink.ink).lineLimit(3)
                    Text("View in Imagine").font(.ui(12)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(sage)
            }.padding(.vertical, 8)
        }.buttonStyle(.plain).accessibilityIdentifier("images.latest")
    }
    private var privacy: some View {
        Label {
            Text("The key stays on your wall. Your picture descriptions are sent to the selected provider. Provider changes never reuse the other service's key.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(sage) }
    }
    private func reset(host: String) {
        sourceHost = host; revision = UUID(); key = ""; busy = false; loading = true
        problem = nil; feedback = nil; readFailed = false; removing = false; switchingTo = nil; services = nil
    }
    private func refresh() async {
        guard !busy else { return }
        let host = wall.host, id = revision
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, revision == id else { return }
        loading = false; readFailed = fresh == nil
        if let fresh { services = fresh }
    }
    private func change(_ patch: [String: String], receipt: String) {
        guard wall.link.isLive, !working else { return }
        let host = wall.host, id = UUID(); revision = id; busy = true; problem = nil; feedback = nil
        Task {
            let (fresh, why) = await ServiceSave.send(["images": patch], to: host)
            guard !Task.isCancelled, wall.host == host, revision == id else { return }
            revision = UUID(); busy = false
            if let fresh { services = fresh; readFailed = false }
            problem = why
            if why == nil { key = ""; removing = false; switchingTo = nil; editing = false; feedback = receipt; Taps.commit() }
        }
    }
}

private struct ImageEngineStudy: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let width = size.width / 7
            for index in 0..<7 {
                let frame = CGRect(x: CGFloat(index) * width, y: 8, width: width - 5, height: size.height - 16)
                let opacity = 0.06 + Double(index) * 0.023
                context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(tint.opacity(opacity)))
                let inset = CGFloat(4 + index * 2)
                context.stroke(Path(ellipseIn: frame.insetBy(dx: inset, dy: 7 + CGFloat(index))), with: .color(tint.opacity(0.25 + Double(index) * 0.07)), lineWidth: 1)
            }
        }
    }
}

extension WallServices {
    struct Images: Decodable {
        struct Last: Decodable { var id: String; var prompt: String; var usd: Double?; var ts: Int? }
        var ready: Bool
        var provider: String?
        var model: String?
        var model_used: String?
        var quality: String?
        var images: Int?
        var cost_usd: Double?
        var last: Last?
        var busy: Bool?
        var problem: String?
        var verified: Bool?
        var pending_change: Bool?
        var pending_provider: String?
    }
}
