import SwiftUI

struct AirPlayPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @Binding var services: WallServices?

    @State private var name = ""
    @State private var editing = false
    @State private var details = false
    @State private var readFailed = false
    @State private var checked = false
    @State private var busy = false
    @State private var confirmAction: Action?
    @State private var problem: String?
    @State private var notice: String?
    @State private var request: Task<Void, Never>?
    @State private var operation = UUID()
    @FocusState private var nameFocused: Bool

    private enum Action { case stop, restart }
    private let mint = Color(hex: 0xBBD2BD)
    private let deep = Color(hex: 0x1D2A25)
    private var ap: WallServices.Airplay? { services?.airplay }
    private var rx: WallServices.Airplay.Receiver? { ap?.receiver }
    private var available: Bool { wall.link.isLive && services != nil && !readFailed }
    private var receiving: Bool { available && ["playing", "paused"].contains(ap?.state ?? "") }
    private var track: WallServices.Airplay.Track? { receiving ? ap?.current : nil }
    private var manageable: Bool { available && rx != nil && rx?.external != true && rx?.controllable != false }
    private var savedName: String { rx?.name ?? "Wall" }
    private var typedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool {
        !typedName.isEmpty && typedName.unicodeScalars.count <= 40
            && !typedName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private var canSave: Bool { manageable && !busy && validName && typedName != savedName }
    private var receiverState: String {
        guard available else { return checked || readFailed || !wall.link.isLive ? "offline" : "loading" }
        guard let rx else { return "unavailable" }
        if rx.external == true { return "external" }
        if let state = rx.state { return state }
        if rx.on == false { return "off" }
        if rx.installed == false { return "not_installed" }
        if rx.running == true { return "ready" }
        return rx.problem == nil ? "starting" : "error"
    }
    private var statusTitle: String {
        if busy { return "Updating the receiver" }
        switch receiverState {
        case "offline": return "Your wall is offline"
        case "loading": return "Finding the receiver"
        case "external": return receiving ? "Receiving from your device" : "Managed on the wall"
        case "off": return "Receiver is off"
        case "not_installed": return "Set up the receiver"
        case "starting": return "Receiver is starting"
        case "error": return "Receiver needs attention"
        case "unavailable": return "Receiver is unavailable"
        default:
            return ap?.state == "playing" ? "Receiving now" : ap?.state == "paused" ? "Stream paused" : "Ready for a connection"
        }
    }
    private var statusSymbol: String {
        switch receiverState {
        case "offline": return "wifi.slash"
        case "loading", "starting": return "clock"
        case "off": return "power"
        case "not_installed", "unavailable": return "arrow.down.circle"
        case "error": return "exclamationmark.circle"
        case "external": return "server.rack"
        default: return ap?.state == "paused" ? "pause.circle" : receiving ? "waveform" : "checkmark.circle"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if let problem { message(problem, symbol: "exclamationmark.circle", id: "airplay.problem") }
                if let notice { message(notice, symbol: "checkmark.circle", id: "airplay.notice") }
                if receiving && !typeSize.isAccessibilitySize { incoming }
                // Nothing read yet is loading, not offline: the hero says
                // "Finding the receiver" and the body must agree.
                if receiverState == "loading" {
                    ProgressView("Reading the receiver").tint(mint).frame(maxWidth: .infinity, minHeight: 80)
                        .accessibilityIdentifier("airplay.loading")
                } else if !available { offline }
                else if receiverState == "not_installed" || receiverState == "unavailable" { installation }
                else if receiverState == "external" { external }
                else { receiverControls }
                if receiving && typeSize.isAccessibilitySize { incoming }
                if available, receiverState == "error" { recovery }
                if available { connectionGuide }
                if available, rx != nil { receiverDetails }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 36)
        }
        .background(Ink.ground).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        .navigationTitle("AirPlay").navigationBarTitleDisplayMode(.inline).tint(mint)
        .refreshable { await refresh(host: wall.host) }
        .task(id: "\(wall.host)|\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            if !editing { name = savedName }
            while !Task.isCancelled {
                if !busy { await refresh(host: host) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: savedName) { old, next in if !editing || name == old { name = next } }
        .onChange(of: wall.host) { _, _ in
            cancel(); services = nil; name = ""; editing = false; details = false
            checked = false; readFailed = false; problem = nil; notice = nil
        }
        .onChange(of: scenePhase) { _, next in if next != .active { cancel() } }
        .onDisappear { cancel() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 14 : 22) {
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .top) {
                    Image(systemName: "airplay.audio").font(.system(size: 25, weight: .light)).foregroundStyle(mint)
                        .accessibilityHidden(true)
                    Spacer()
                    Text(rx?.external == true ? "EXTERNAL RECEIVER" : rx?.protocol == "airplay2" ? "AIRPLAY 2 RECEIVER" : "WIRELESS RECEIVER")
                        .font(.custom(Face.monoMedium, size: 9, relativeTo: .caption2)).tracking(1)
                        .foregroundStyle(mint).multilineTextAlignment(.trailing)
                }
            }
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(rx?.external == true ? "External receiver" : savedName)
                            .font(.display(44)).tracking(-0.8).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Music sent here shows its artwork on the wall.").font(.ui(15)).foregroundStyle(mint.opacity(0.9))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    antenna.frame(width: 76, height: 100).accessibilityHidden(true)
                }
            }
            Label(statusTitle, systemImage: statusSymbol).font(.ui(typeSize.isAccessibilitySize ? 12 : 13, .medium))
                .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("airplay.status")
            if typeSize.isAccessibilitySize, rx?.external != true {
                Text(savedName).font(.ui(13, .semibold)).foregroundStyle(mint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(typeSize.isAccessibilitySize ? 19 : 24).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 27).fill(LinearGradient(colors: [Color(hex: 0x31443B), deep], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(mint.opacity(0.15), lineWidth: 1))
        .accessibilityIdentifier("airplay.hero")
    }

    private var antenna: some View {
        Canvas { context, size in
            for column in 0..<11 {
                for row in 0..<14 {
                    let point = CGRect(x: CGFloat(column) * 7, y: CGFloat(row) * 7, width: 2, height: 2)
                    context.fill(Path(ellipseIn: point), with: .color(mint.opacity(0.15)))
                }
            }
            let center = CGPoint(x: size.width / 2, y: size.height * 0.65)
            for radius in [CGFloat(18), 30, 42] {
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(218), endAngle: .degrees(322), clockwise: false)
                context.stroke(arc, with: .color(mint.opacity(receiving ? 0.9 : 0.48)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            var stem = Path()
            stem.move(to: CGPoint(x: center.x - 9, y: center.y + 7))
            stem.addLine(to: CGPoint(x: center.x, y: center.y - 5))
            stem.addLine(to: CGPoint(x: center.x + 9, y: center.y + 7))
            stem.closeSubpath()
            context.fill(stem, with: .color(mint))
        }
    }

    private var incoming: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ap?.state == "paused" ? "PAUSED AT THE SOURCE" : "RECEIVED OVER AIRPLAY")
                .font(typeSize.isAccessibilitySize ? .ui(10, .medium) : .machine(10)).tracking(typeSize.isAccessibilitySize ? 0 : 1).foregroundStyle(mint)
            if let track {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 17))
                layout {
                    AsyncImage(url: artworkURL(track.art_url)) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else {
                            RoundedRectangle(cornerRadius: 12).fill(deep)
                                .overlay { Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(mint) }
                        }
                    }
                    .frame(width: typeSize.isAccessibilitySize ? 72 : 104, height: typeSize.isAccessibilitySize ? 72 : 104)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.ui(typeSize.isAccessibilitySize ? 13 : 20, .semibold)).foregroundStyle(Ink.ink)
                        if !track.artist.isEmpty { Text(track.artist).font(.ui(typeSize.isAccessibilitySize ? 11 : 15)).foregroundStyle(mint) }
                        if let album = track.album, !album.isEmpty { Text(album).font(.ui(12)).foregroundStyle(Ink.dim) }
                    }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("airplay.current")
            } else {
                Text("A stream is connected.").font(.display(27)).foregroundStyle(Ink.ink)
                Text("Waiting for the sender to share its track details and artwork.").font(.ui(14)).foregroundStyle(Ink.dim)
            }
            if let from = ap?.connected_from, !from.isEmpty {
                Label(from, systemImage: "iphone.radiowaves.left.and.right").font(.ui(13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("airplay.sender")
            }
            Text("Playback stays in the app sending the music.").font(.ui(12)).foregroundStyle(Ink.dim)
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }

    private var receiverControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { rx?.on == true }, set: { next in
                if !next && receiving { confirmAction = .stop }
                else { change(["airplay_receiver": next], expectedOn: next) }
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receive AirPlay").font(.ui(typeSize.isAccessibilitySize ? 12 : 17, .semibold)).foregroundStyle(Ink.ink)
                    Text(rx?.on != true ? "Hidden from the AirPlay menu" : receiverState == "ready" ? "Visible to devices on your network" : "Waiting for the receiver to be ready")
                        .font(.ui(typeSize.isAccessibilitySize ? 10 : 13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
            }.disabled(!manageable || busy || rx?.installed == false).accessibilityIdentifier("airplay.enabled")
            if busy { Label("Waiting for the wall to confirm…", systemImage: "clock").font(.ui(13)).foregroundStyle(mint) }
            if confirmAction == .stop { confirmation }
            Divider().overlay(Ink.hairline)
            if editing { nameEditor }
            else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { editing = true; name = savedName }
                    nameFocused = true
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("AirPlay name").font(.ui(typeSize.isAccessibilitySize ? 10 : 12)).foregroundStyle(Ink.dim)
                            Text(savedName).font(.ui(typeSize.isAccessibilitySize ? 13 : 17, .medium)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "pencil").font(.system(size: 15, weight: .medium)).foregroundStyle(mint)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!manageable || busy).accessibilityIdentifier("airplay.editName")
            }
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name in the AirPlay menu").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
            TextField("Wall", text: $name).font(.ui(17)).foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.done)
                .focused($nameFocused).onSubmit { saveName() }
                .padding(14).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("AirPlay receiver name").accessibilityIdentifier("airplay.name")
            Text(!typedName.isEmpty && !validName ? "Use up to 40 characters on one line." : "Changing the name restarts the receiver and ends its current stream.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button(busy ? "Saving…" : "Save name") { saveName() }
                    .font(.ui(15, .semibold)).foregroundStyle(canSave ? mint : Ink.dim)
                    .frame(minHeight: 44).disabled(!canSave).accessibilityIdentifier("airplay.saveName")
                Button("Cancel") { nameFocused = false; editing = false; name = savedName }
                    .font(.ui(15)).foregroundStyle(Ink.dim).frame(minHeight: 44).disabled(busy)
                    .accessibilityIdentifier("airplay.cancelName")
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmAction == .stop ? "Stop receiving this stream?" : "Restart this receiver?")
                .font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
            Text("The sender will disconnect. You can select the wall again when it’s ready.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button(confirmAction == .stop ? "Stop receiving" : "Restart") {
                    if confirmAction == .stop { change(["airplay_receiver": false], expectedOn: false) }
                    else { restart() }
                    confirmAction = nil
                }.font(.ui(14, .semibold)).frame(minHeight: 44).accessibilityIdentifier("airplay.confirmAction")
                Button("Keep receiving") { confirmAction = nil }.font(.ui(14)).foregroundStyle(Ink.dim).frame(minHeight: 44)
                    .accessibilityIdentifier("airplay.cancelAction")
            }.disabled(busy)
        }.padding(15).background(deep, in: RoundedRectangle(cornerRadius: 14))
    }

    private var connectionGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How to connect").font(.display(typeSize.isAccessibilitySize ? 25 : 31)).foregroundStyle(Ink.ink)
            guideStep("01", title: "Stay on the same network", text: "Connect your iPhone, iPad or Mac to the wall’s local network.")
            guideStep("02", title: "Open your player’s AirPlay menu", text: rx?.external == true ? "Select the receiver configured on your wall." : "Select “\(savedName)” to send the stream and its available artwork.")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: rx?.output == "silent" || rx?.external != true ? "speaker.slash" : "info.circle")
                    .font(.system(size: 19, weight: .light)).foregroundStyle(mint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(rx?.external == true ? "Your receiver controls the audio" : "This receiver is silent")
                        .font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                    Text(rx?.external == true ? "Its audio output and AirPlay version are configured on the wall. Tessera reads the metadata it shares." : "Selecting it can move sound away from your phone. Classic AirPlay cannot join an iPhone speaker group. Grouping with HomePod requires an AirPlay 2 receiver.")
                        .font(.ui(13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
            }.padding(16).background(mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            Link(destination: URL(string: "https://support.apple.com/guide/iphone/homepod-and-other-wireless-speakers-iph315e0d58d/ios")!) {
                Label("Apple’s AirPlay guide", systemImage: "arrow.up.right").font(.ui(14, .semibold)).foregroundStyle(mint).frame(minHeight: 44)
            }.accessibilityIdentifier("airplay.guide")
        }
    }

    private func guideStep(_ number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.machine(11)).foregroundStyle(mint).frame(width: 27, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                Text(text).font(.ui(14)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receiverDetails: some View {
        DisclosureGroup(isExpanded: $details) {
            VStack(alignment: .leading, spacing: 14) {
                Text(rx?.external == true ? "System managed, configuration is read-only here" : rx?.protocol == "airplay2" ? "AirPlay 2, silent audio output" : rx?.protocol == "classic" ? "Classic AirPlay, silent audio output" : "Protocol will be known when the receiver starts")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                if let version = rx?.version, rx?.external != true {
                    Text("Shairport Sync \(version.components(separatedBy: "-").first ?? version)")
                        .font(.ui(12)).foregroundStyle(Ink.dim)
                }
                if manageable, rx?.on == true, rx?.installed == true {
                    Button("Restart receiver", systemImage: "arrow.clockwise") {
                        if receiving { confirmAction = .restart }
                        else { restart() }
                    }.font(.ui(14, .semibold)).foregroundStyle(mint).frame(minHeight: 44).disabled(busy)
                        .accessibilityIdentifier("airplay.restart")
                    if confirmAction == .restart { confirmation }
                }
                Link("AirPlay 2 installation guide", destination: URL(string: "https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md")!)
                    .font(.ui(14, .semibold)).foregroundStyle(mint).frame(minHeight: 44)
                    .accessibilityIdentifier("airplay.installGuide")
            }.padding(.top, 14)
        } label: {
            Text("Receiver details").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                .frame(minHeight: 44).accessibilityIdentifier("airplay.details")
        }
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(receiverState == "not_installed" ? "Install the receiver" : "AirPlay isn’t enabled on this wall.")
                .font(.display(typeSize.isAccessibilitySize ? 24 : 29)).foregroundStyle(Ink.ink)
            Text(receiverState == "not_installed" ? "Install the bundled receiver on the Raspberry Pi, then return here to name it and turn it on." : "Enable the AirPlay feature in the wall’s configuration, then check again.")
                .font(.ui(14)).foregroundStyle(Ink.dim)
            if receiverState == "not_installed" {
                Text("pi/install-airplay.sh").font(.machine(12)).foregroundStyle(mint).textSelection(.enabled)
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading).background(deep, in: RoundedRectangle(cornerRadius: 12))
            }
            refreshButton
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var external: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Another receiver is running").font(.display(typeSize.isAccessibilitySize ? 24 : 29)).foregroundStyle(Ink.ink)
            Text("Another Shairport Sync receiver is running on the wall. Its name, power and audio output are managed there. Tessera can read its track information when it uses the shared metadata pipe.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            refreshButton
        }.accessibilityIdentifier("airplay.external")
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The receiver couldn’t stay running.").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
            Text("The wall retries automatically. Check the receiver installation or restart it in Receiver details.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            refreshButton
        }.accessibilityIdentifier("airplay.receiverProblem")
    }

    private var offline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reconnect to your wall.").font(.display(typeSize.isAccessibilitySize ? 24 : 29)).foregroundStyle(Ink.ink)
            Text("Receiver controls and incoming artwork return when your wall answers. Your saved setup stays on the wall.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button("Check again", systemImage: "arrow.clockwise") { Task { await refresh(host: wall.host) } }
            .font(.ui(14, .semibold)).foregroundStyle(mint).frame(minHeight: 44).disabled(busy)
            .accessibilityIdentifier("airplay.refresh")
    }
    private func message(_ text: String, symbol: String, id: String) -> some View {
        Label(text, systemImage: symbol).font(.ui(14)).foregroundStyle(Ink.ink)
            .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(deep, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier(id)
    }
    private func artworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        if url.path.hasPrefix("/art/airplay/") { return URL(string: "http://\(wall.host)\(url.path)") }
        return url
    }

    private func refresh(host: String) async {
        let token = operation
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, operation == token, scenePhase == .active, !busy else { return }
        checked = true; readFailed = fresh == nil
        if let fresh { services = fresh }
    }
    private func begin(_ action: @escaping @MainActor (String, UUID) async -> Void) {
        guard manageable, !busy else { return }
        nameFocused = false; busy = true; problem = nil; notice = nil
        let host = wall.host, token = UUID(); operation = token
        request = Task {
            await action(host, token)
            if operation == token { busy = false; request = nil }
        }
    }
    private func saveName() {
        guard canSave else { return }
        change(["airplay_name": typedName], expectedName: typedName)
    }
    private func change(_ patch: [String: Any], expectedName: String? = nil, expectedOn: Bool? = nil) {
        begin { host, token in
            let result = await AirPlayCommand.post(path: "/state", patch: patch, host: host)
            guard active(host, token) else { return }
            guard result.accepted else { problem = result.problem; Taps.error(); return }
            for _ in 0..<12 {
                let fresh = await WallServices.read(host: host)
                guard active(host, token) else { return }
                if let fresh {
                    services = fresh; readFailed = false; checked = true
                    let receiver = fresh.airplay?.receiver
                    let matchingName = expectedName == nil || receiver?.name == expectedName
                    let matchingPower = expectedOn == nil || receiver?.on == expectedOn
                    let stopped = expectedOn != false || receiver?.running == false
                    if matchingName && matchingPower && stopped && receiver?.external != true {
                        if expectedName != nil { editing = false; name = expectedName ?? "" }
                        notice = expectedOn == false ? "Receiver stopped. Your saved name is kept." : expectedName != nil ? "Name saved. Select it in your player’s AirPlay menu when the receiver is ready." : "Receiver enabled. It will appear in the AirPlay menu when ready."
                        confirmAction = nil; Taps.commit(); return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            problem = "The setting was accepted, but the receiver hasn’t confirmed it yet. Check again before retrying."
        }
    }
    private func restart() {
        begin { host, token in
            let result = await AirPlayCommand.post(path: "/airplay/restart", patch: [:], host: host)
            guard active(host, token) else { return }
            if result.accepted { notice = "Restart requested. The receiver will return to Ready when it is available."; Taps.commit() }
            else { problem = result.problem; Taps.error() }
        }
    }
    private func active(_ host: String, _ token: UUID) -> Bool {
        !Task.isCancelled && operation == token && wall.host == host && scenePhase == .active
    }
    private func cancel() { operation = UUID(); request?.cancel(); request = nil; busy = false; nameFocused = false; confirmAction = nil }
}

private enum AirPlayCommand {
    struct Result { let accepted: Bool; let problem: String? }
    static func post(path: String, patch: [String: Any], host: String) async -> Result {
        guard let url = URL(string: "http://\(host)\(path)"), let data = try? JSONSerialization.data(withJSONObject: patch) else {
            return Result(accepted: false, problem: "The wall address is unavailable.")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else {
            return Result(accepted: false, problem: "The wall didn’t confirm the change. Your draft is kept. Reconnect and check again.")
        }
        let accepted = (response as? HTTPURLResponse)?.statusCode == 200 && WallAcknowledgement.accepted(responseData)
        return Result(accepted: accepted, problem: accepted ? nil : "The wall could not apply this change. Check whether the receiver is managed by another service, then try again.")
    }
}

extension WallServices {
    struct Airplay: Decodable {
        struct Receiver: Decodable {
            var installed: Bool?
            var version: String?
            var on: Bool?
            var name: String?
            var port: Int?
            var running: Bool?
            var up_s: Int?
            var restarts: Int?
            var external: Bool?
            var problem: String?
            var state: String?
            var controllable: Bool?
            var output: String?
            var `protocol`: String?
        }
        struct Track: Decodable {
            var title: String
            var artist: String
            var album: String?
            var art_url: String?
            var progress_ms: Int?
            var duration_ms: Int?
            var is_playing: Bool?
        }
        var receiver: Receiver?
        var running: Bool?
        var pipe_exists: Bool?
        var reading: Bool?
        var state: String?
        var connected_from: String?
        var user_agent: String?
        var last: String?
        var error: String?
        var current: Track?
    }
}
