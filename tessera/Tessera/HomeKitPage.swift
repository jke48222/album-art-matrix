import SwiftUI

struct HomeKitPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @State private var status: HomeKitStatus?
    @State private var busy = false
    @State private var loading = true
    @State private var failed = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var pairingExpanded = false
    @State private var remoteExpanded = false
    @State private var sourceHost = ""
    @State private var operation = UUID()
    @State private var request: Task<Void, Never>?
    private let honey = Color(hex: 0xE8B979)
    private let paper = Color(hex: 0xF4EBDD)
    private var live: Bool { wall.link.isLive && !failed }
    private var ready: Bool { live && status?.ready == true && status?.error == nil }
    private var paired: Bool { status?.paired == true }
    private var canShow: Bool { ready && !busy && !paired && status?.validModules != nil }
    private var stateTitle: String {
        if !wall.link.isLive { return "Wall offline" }
        if loading && status == nil { return "Finding your bridge" }
        if failed { return "Connection unavailable" }
        if status?.enabled == false { return "HomeKit is off" }
        if status?.error != nil { return "Bridge needs attention" }
        if !ready { return "Bridge is starting" }
        return paired ? "Paired with Apple Home" : "Ready to add to Home"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                introduction
                if !wall.link.isLive || failed {
                    message("Waiting for your wall", detail: "Reconnect on the same network to read the bridge and manage its setup code.", symbol: "wifi.slash")
                    Button("Check again", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .font(.ui(16, .semibold)).frame(minHeight: 44).accessibilityIdentifier("homekit.retry")
                } else if loading && status == nil {
                    ProgressView("Reading HomeKit status").font(.ui(15)).frame(maxWidth: .infinity, minHeight: 100).tint(honey)
                } else if status?.enabled == false {
                    message("HomeKit isn't running", detail: "Enable HomeKit in this wall’s configuration to add its accessories to Apple Home. Your other Tessera controls are still available.", symbol: "house")
                } else if let error = status?.error {
                    message("The bridge couldn't start", detail: error, symbol: "exclamationmark.circle")
                } else if ready {
                    if paired { connectedBridge } else { pairingCard }
                    if let problem { message("That didn't go through", detail: problem, symbol: "exclamationmark.circle") }
                    if let notice {
                        Label(notice, systemImage: "checkmark.circle").font(.ui(14, .medium)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("homekit.notice")
                    }
                    accessories
                    if status?.television != false { remoteGuide }
                    if paired { maintenance }
                } else {
                    message("Getting HomeKit ready", detail: "The wall is starting its bridge. Pairing will appear here when it’s ready.", symbol: "network")
                }
                footer
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 44)
        }
        .scrollIndicators(.hidden).background(Color(hex: 0x171614)).foregroundStyle(Ink.ink).tint(honey)
        .navigationTitle("Apple Home").navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task(id: "\(wall.host)|\(scene)") {
            guard scene == .active else { return }
            if sourceHost != wall.host { reset(host: wall.host) }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(status?.showing_code == true ? 2 : 5))
            }
        }
        .onChange(of: wall.host) { _, host in reset(host: host) }
        .onChange(of: scene) { _, phase in if phase != .active { cancel() } }
        .onDisappear { cancel(); status = nil; loading = true }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 12 : 17) {
            Label(stateTitle, systemImage: ready && paired ? "checkmark.circle.fill" : "house")
                .font(.ui(typeSize.isAccessibilitySize ? 11 : 13, .medium)).foregroundStyle(honey).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("homekit.state")
            if typeSize.isAccessibilitySize {
                Text(paired ? "Your home bridge" : "Pair your wall")
                    .font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Text(paired ? "Paired" : "Add to Apple Home")
                        .font(.display(43)).tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    HomeKitHouse(tint: honey).frame(width: 88, height: 96).accessibilityHidden(true)
                }
                Text(paired ? pairedSummary : "Control the wall from Siri, scenes and the Home app.")
                    .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Names only what this wall puts in Home. The remote and the sensors
    /// are left out below on a wall that does not bridge them, so the line
    /// must not promise them either.
    private var pairedSummary: String {
        let names = ["light"] + (status?.television != false ? ["remote"] : []) + (status?.sensors != false ? ["sensors"] : [])
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "The wall's \(list) \(names.count == 1 ? "is" : "are") in Apple Home."
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            pairingTicket
            pairingActions
        }
    }

    private var pairingTicket: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(status?.name ?? "Wall").font(.ui(typeSize.isAccessibilitySize ? 14 : 18, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                    Text("HOMEKIT BRIDGE").font(.machine(8)).tracking(0.5)
                }
            }.foregroundStyle(Color(hex: 0x383026))
            if let modules = status?.validModules {
                HomeKitCode(modules: modules)
                    .frame(width: typeSize.isAccessibilitySize ? 192 : 224, height: typeSize.isAccessibilitySize ? 192 : 224)
                    .frame(maxWidth: .infinity).privacySensitive().accessibilityHidden(true)
                VStack(spacing: 9) {
                    Text(status?.code ?? "").font(.machine(typeSize.isAccessibilitySize ? 14 : 25))
                        .foregroundStyle(Color(hex: 0x27231E)).privacySensitive()
                        .accessibilityLabel("Setup code").accessibilityValue(status?.code ?? "Unavailable")
                        .accessibilityIdentifier("homekit.code")
                    if !typeSize.isAccessibilitySize {
                        Text("The same code appears on your wall.").font(.ui(12)).foregroundStyle(Color(hex: 0x64594D))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity)
            } else {
                Label("The QR code isn't available yet", systemImage: "qrcode").font(.ui(17, .medium)).foregroundStyle(Color(hex: 0x383026))
                if let code = status?.code {
                    Text(code).font(.machine(typeSize.isAccessibilitySize ? 14 : 22)).foregroundStyle(Color(hex: 0x27231E)).privacySensitive()
                        .accessibilityIdentifier("homekit.code")
                }
            }
            if let error = status?.code_error {
                Text(error).font(.ui(13)).foregroundStyle(Color(hex: 0x7A3824)).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(22).background(paper, in: RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2).fill(honey).frame(width: 52, height: 3).offset(y: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var pairingActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { perform(status?.showing_code == true ? .hide : .show) } label: {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(Color(hex: 0x2D261E)) }
                    Text(status?.showing_code == true ? "Take code off the wall" : "Show code on the wall").font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: status?.showing_code == true ? "xmark" : "qrcode")
                }.foregroundStyle(Color(hex: 0x2D261E)).padding(18).frame(minHeight: 56).background(honey, in: RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain).disabled(status?.showing_code == true ? !ready || busy : !canShow)
                .opacity((canShow || status?.showing_code == true) ? 1 : 0.5)
                .accessibilityIdentifier("homekit.showCode")
            if status?.showing_code == true {
                Label("On the wall, returns automatically in \(max(1, Int(ceil(Double(status?.code_seconds_remaining ?? 180) / 60)))) min", systemImage: "clock")
                    .font(.ui(13)).foregroundStyle(honey).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("homekit.showing")
            }
            VStack(alignment: .leading, spacing: 13) {
                step("1", "Open Home", detail: "Tap +, then Add Accessory.")
                step("2", "Scan the wall", detail: "Or choose More Options and enter the eight-digit code.")
                step("3", "Name it", detail: "Choose a room and a name for the wall.")
            }
            Text("Keep your phone on the wall’s network. Home may identify this personal bridge as uncertified. Choose Add Anyway to continue.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedBridge: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("HOME BRIDGE", systemImage: "house.fill").font(.machine(10)).foregroundStyle(honey)
            Text(status?.name ?? "Wall").font(.display(32)).fixedSize(horizontal: false, vertical: true)
            Text("Paired and ready for your routines.").font(.ui(15)).foregroundStyle(Ink.dim)
            Divider().overlay(honey.opacity(0.2))
            Text("“Siri, set \(status?.name ?? "Wall") to thirty percent.”")
                .font(.ui(21, .medium)).fixedSize(horizontal: false, vertical: true)
            Text("Use the name you gave the light in Home.").font(.ui(12)).foregroundStyle(Ink.dim)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(honey.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("homekit.paired")
    }

    private var accessories: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Accessories in Home").font(.ui(22, .semibold))
            accessory("lightbulb", "The light", "Power, brightness and a colour for the lamp.", detail: "Light in Home")
            if status?.television != false {
                Divider().overlay(Ink.hairline)
                accessory("appletvremote.gen4", "The remote", "Faces as inputs. A controller when a game is on.", detail: "Television in Home")
            }
            if status?.sensors != false {
                Divider().overlay(Ink.hairline)
                accessory("waveform", "The room", "Sound and music sensors for your automations.", detail: "Two sensors in Home")
            }
        }
    }

    private var remoteGuide: some View {
        DisclosureGroup(isExpanded: $remoteExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Open the Apple TV Remote in Control Centre and choose \(status?.name ?? "Wall") Remote.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                remoteKey("arrow.up.arrow.down", "Arrows", "Step through faces. Steer the current game.")
                remoteKey("playpause", "Play / pause", "Turn the wall off and back on.")
                remoteKey("speaker.wave.2", "Volume", "Dim or brighten the wall.")
                remoteKey("info.circle", "Info", "Show the current song as a ticker.")
                if let faces = status?.faces, !faces.isEmpty {
                    Text("Available inputs").font(.ui(14, .semibold)).foregroundStyle(honey)
                    Text(faces.map(\.name).joined(separator: ", ")).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 16)
        } label: {
            Label("Using the remote", systemImage: "appletvremote.gen4").font(.ui(16, .semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("homekit.remoteGuide")
        }
    }

    private var maintenance: some View {
        DisclosureGroup(isExpanded: $pairingExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Missing a face or sensor in Home? Refresh the accessory list, then reopen Home.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Button { perform(.refresh) } label: {
                    Label(busy ? "Refreshing accessories…" : "Refresh accessories", systemImage: "arrow.clockwise")
                        .font(.ui(15, .semibold)).frame(minHeight: 44)
                }.disabled(!ready || busy).accessibilityIdentifier("homekit.refreshAccessories")
                Text("Manage people and remove this bridge in Home, then Home Settings, then Home Hubs and Bridges. Removing it there doesn't erase your Tessera settings.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 16)
        } label: {
            Text("Manage the bridge").font(.ui(16, .semibold)).frame(minHeight: 44).accessibilityIdentifier("homekit.manage")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Ink.hairline).padding(.bottom, 9)
            Text("Home hubs").font(.ui(16, .semibold))
            Text("A HomePod or Apple TV lets you run automations, share control and reach your wall away from home.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Link("Apple Home setup guide", destination: URL(string: "https://support.apple.com/en-us/104998")!)
                .font(.ui(14, .medium)).frame(minHeight: 44).accessibilityIdentifier("homekit.help")
        }
    }

    private func accessory(_ symbol: String, _ title: String, _ text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(honey).frame(width: 34, height: 36).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.ui(17, .semibold))
                Text(text).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.ui(12)).foregroundStyle(honey).padding(.top, 2)
            }
        }.accessibilityElement(children: .combine)
    }
    private func step(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.machine(11)).foregroundStyle(honey).frame(width: 26, height: 26).background(honey.opacity(0.08), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(15, .semibold))
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
    private func remoteKey(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(14, .semibold))
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(honey).frame(width: 30) }
    }
    private func message(_ title: String, detail: String, symbol: String) -> some View {
        CreativeConnectionNotice(title: title, detail: detail, symbol: symbol, tint: honey)
            .accessibilityIdentifier("homekit.problem")
    }
    private func cancel() {
        operation = UUID(); request?.cancel(); request = nil; busy = false
    }
    private func reset(host: String) {
        cancel(); sourceHost = host; status = nil; loading = true; failed = false; problem = nil; notice = nil
        pairingExpanded = false; remoteExpanded = false
    }
    private func refresh() async {
        guard !busy, scene == .active else { return }
        let host = wall.host, id = operation
        let fresh = await HomeKitStatus.read(host: host)
        guard !Task.isCancelled, wall.host == host, operation == id, scene == .active else { return }
        loading = false; failed = fresh == nil
        if let fresh {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { status = fresh }
        }
    }
    private func perform(_ action: HomeKitStatus.Action) {
        guard ready, !busy, action != .show || canShow else { return }
        let host = wall.host, id = UUID()
        operation = id; busy = true; problem = nil; notice = nil
        request = Task {
            let reply = await HomeKitStatus.perform(action, host: host)
            guard !Task.isCancelled, wall.host == host, operation == id, scene == .active else { return }
            busy = false; operation = UUID(); request = nil
            if let fresh = reply.status { status = fresh; failed = false }
            if let error = reply.error { problem = error; return }
            switch action {
            case .show: notice = "Setup code is on the wall."
            case .hide: notice = "The wall has returned to its previous view."
            case .refresh: notice = "Accessory list refreshed. Reopen Home to read it."
            }
            Taps.commit()
        }
    }
}

private struct HomeKitHouse: View {
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var roof = Path()
            roof.move(to: CGPoint(x: w * 0.1, y: h * 0.42))
            roof.addLine(to: CGPoint(x: w * 0.5, y: h * 0.12))
            roof.addLine(to: CGPoint(x: w * 0.9, y: h * 0.42))
            context.stroke(roof, with: .color(tint.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let room = CGRect(x: w * 0.22, y: h * 0.4, width: w * 0.56, height: h * 0.48)
            context.fill(Path(roundedRect: room, cornerRadius: 5), with: .color(tint.opacity(0.08)))
            context.stroke(Path(roundedRect: room, cornerRadius: 5), with: .color(tint.opacity(0.25)), lineWidth: 1)
            for y in 0..<5 { for x in 0..<5 {
                let rect = CGRect(x: w * 0.34 + CGFloat(x) * 6, y: h * 0.5 + CGFloat(y) * 6, width: 3.4, height: 3.4)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(tint.opacity(0.4 + Double((x + y) % 3) * 0.2)))
            } }
        }
    }
}

/// Draws the wall's canonical 64x64 QR composition using the wall's module matrix.
private struct HomeKitCode: View {
    let modules: [String]
    var body: some View {
        Canvas { context, size in
            let count = modules.count
            let scale = 64 / (count + 8)
            let offset = (64 - count * scale) / 2
            let unit = min(size.width, size.height) / 64
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for (y, row) in modules.enumerated() {
                for (x, value) in row.enumerated() where value == "1" {
                    let rect = CGRect(x: CGFloat(offset + x * scale) * unit, y: CGFloat(offset + y * scale) * unit,
                                      width: CGFloat(scale) * unit, height: CGFloat(scale) * unit)
                    context.fill(Path(rect), with: .color(.black), style: FillStyle(antialiased: false))
                }
            }
        }.drawingGroup(opaque: true).accessibilityHidden(true)
    }
}

struct HomeKitStatus: Decodable {
    struct Face: Decodable { var id: Int; var name: String; var mode: String }
    var enabled: Bool?
    var ready: Bool?
    var error: String?
    var code_error: String?
    var name: String?
    var paired: Bool?
    var code: String?
    var uri: String?
    var qr_modules: [String]?
    var showing_code: Bool?
    var code_seconds_remaining: Int?
    var television: Bool?
    var sensors: Bool?
    var faces: [Face]?
    var validModules: [String]? {
        guard let rows = qr_modules, (21...49).contains(rows.count), (rows.count - 21) % 4 == 0,
              rows.allSatisfy({ $0.count == rows.count && $0.allSatisfy({ $0 == "0" || $0 == "1" }) }) else { return nil }
        return rows
    }
    enum Action: String { case show, hide, refresh }
    struct Reply { var status: HomeKitStatus?; var error: String? }

    static func read(host: String) async -> HomeKitStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/homekit") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(HomeKitStatus.self, from: data)
    }
    static func perform(_ action: Action, host: String) async -> Reply {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/homekit/\(action.rawValue)") else {
            return Reply(error: "Reconnect to your wall and try again.")
        }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let fresh = try? JSONDecoder().decode(HomeKitStatus.self, from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return Reply(status: fresh, error: fresh?.code_error ?? fresh?.error ?? "The bridge isn't ready. Check its status and try again.")
            }
            guard let fresh, fresh.ready == true, fresh.error == nil else {
                return Reply(status: fresh, error: "The wall couldn't confirm this change. Check its status and try again.")
            }
            if action == .show && fresh.showing_code != true {
                return Reply(status: fresh, error: "The setup code wasn't displayed. Try again when the bridge is ready.")
            }
            if action == .hide && fresh.showing_code == true {
                return Reply(status: fresh, error: "The code is still on the wall. Try taking it down again.")
            }
            return Reply(status: fresh)
        } catch {
            return Reply(error: "The wall didn't reply. Reconnect, then check whether the change reached it.")
        }
    }
}
