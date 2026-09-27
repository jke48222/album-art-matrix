import SwiftUI
import UIKit

extension WallServices {
    struct Mac: Decodable {
        struct Track: Decodable { var title: String; var artist: String; var album: String?; var art_url: String?; var is_playing: Bool? }
        var endpoint: String
        var answering: Bool?
        var state: String?
        var checked_at: Double?
        var current: Track?
        var problem: String?
    }
}

/// The wall's reporter origin and the phone's optional forwarding target are
/// separate paths. Saving one must never silently change the other.
struct MacReporterPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var services: WallServices?
    @State private var address = ""
    @State private var forwarding = ""
    @State private var editing = false
    @State private var diagnostics = false
    @State private var extraForwarding = false
    @State private var unlinking = false
    @State private var busy = false
    @State private var failed = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var request: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var initializedHost: String?
    @FocusState private var fieldFocused: Bool
    private let mint = Color(hex: 0xB5D5C5)
    private var mac: WallServices.Mac? { services?.mac }
    private var endpoint: String { mac?.endpoint ?? "" }
    private var available: Bool { wall.link.isLive && services != nil && !failed }
    /// Opened with nothing read yet (from Other players, or after a host
    /// change): reading, not offline, until the first read answers or fails.
    private var loading: Bool { wall.link.isLive && services == nil && !failed }
    private var linked: Bool { !endpoint.isEmpty }
    private var current: WallServices.Mac.Track? { available && ["playing", "paused"].contains(mac?.state ?? "") ? mac?.current : nil }
    private var name: String { URL(string: endpoint)?.host()?.replacingOccurrences(of: ".local", with: "") ?? "Your Mac" }
    private var status: String {
        if loading { return "Reading the Mac connection" }
        guard available else { return "Waiting for the wall" }
        if busy { return "Updating the connection" }
        switch mac?.state {
        case "playing": return "Music is arriving"
        case "paused": return "Playback is paused"
        case "idle": return "Connected, nothing playing"
        case "checking": return "Checking from the wall"
        case "unavailable": return "Reporter unreachable"
        case "stale": return "Time to check again"
        case "local": return "Running on this Mac"
        default: return linked ? "Address saved, not checked yet" : "Connect a Mac"
        }
    }
    private var canSave: Bool { available && !busy && Self.origin(address) != nil && Self.origin(address) != endpoint }
    static func origin(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, !text.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 } == true }) else { return nil }
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              ["http", "https"].contains(parts.scheme ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", (1...65535).contains(parts.port ?? 8787) else { return nil }
        guard host.contains(":") || host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else { return nil }
        parts.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); parts.port = parts.port ?? 8787; parts.path = ""
        return parts.url?.absoluteString
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if loading {
                    ProgressView("Reading the Mac connection").tint(mint).frame(maxWidth: .infinity, minHeight: 80)
                        .accessibilityIdentifier("mac.loading")
                } else if !available {
                    Label("Connect to the wall to check or change its Mac reporter.", systemImage: "wifi.slash").font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Try again") { run(check: false) }.frame(minHeight: 44).accessibilityIdentifier("mac.retryWall")
                }
                if let text = problem ?? (available ? mac?.problem : nil) {
                    Label(text, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mac.problem")
                }
                if let notice { Text(notice).font(.ui(14)).foregroundStyle(mint).accessibilityIdentifier("mac.notice") }
                if typeSize.isAccessibilitySize { connection }
                if let current { track(current) }
                if !typeSize.isAccessibilitySize { connection }
                // Only after a read: the saved address is unknown until then.
                if services != nil && (!linked || editing) { editor }
                setup
                troubleshooting
                forwardingControls
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 40)
        }.background(Ink.ground).tint(mint).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Your Mac").navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh(wall.host, check: linked) }
            .task(id: "\(wall.host)|\(scene == .active)") {
                guard scene == .active else { return }
                if initializedHost != wall.host { initializedHost = wall.host; address = endpoint; forwarding = wall.push.host }
                while !Task.isCancelled {
                    if !busy { await refresh(wall.host) }
                    do { try await Task.sleep(for: .seconds(4)) } catch { break }
                }
            }
            .onChange(of: endpoint) { old, next in if !editing || address == old { address = next } }
            .onChange(of: wall.host) { _, _ in cancel(); services = nil; address = ""; editing = false; failed = false; notice = nil; problem = nil }
            .onChange(of: scene) { _, next in if next != .active { cancel() } }
            .onDisappear { cancel() }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            if typeSize.isAccessibilitySize { Text("Mac reporter").font(.ui(14,.semibold)).foregroundStyle(mint) }
            else { Label("FROM YOUR MAC", systemImage: "desktopcomputer").font(.machine(10)).tracking(1.2).foregroundStyle(mint) }
            if !typeSize.isAccessibilitySize {
                Text("Mac reporter").font(.display(42)).tracking(-0.7).foregroundStyle(Ink.ink)
                HStack(spacing: 20) {
                    Image(systemName: "laptopcomputer").font(.system(size: 47, weight: .ultraLight))
                    Canvas { ctx, size in
                        for i in 0..<7 { let x = CGFloat(i) * size.width / 7; ctx.fill(Path(ellipseIn: CGRect(x:x, y:size.height/2 - 2, width:3, height:3)), with:.color(mint.opacity(Double(i+2)/10))) }
                    }.frame(height: 38)
                    Image(systemName: "square.grid.3x3.fill").font(.system(size: 37, weight: .ultraLight))
                }.foregroundStyle(mint).padding(.vertical, 6).accessibilityHidden(true)
            }
            Label(status, systemImage: available && mac?.answering == true ? "checkmark.circle" : "network")
                .font(.ui(14, .medium)).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mac.status")
        }.padding(24).frame(maxWidth:.infinity, alignment:.leading)
            .background(LinearGradient(colors:[Color(hex:0x1D322D),Color(hex:0x18201D)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:26))
            .overlay(RoundedRectangle(cornerRadius:26).strokeBorder(mint.opacity(0.15),lineWidth:1))
    }
    private func track(_ track: WallServices.Mac.Track) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(track.is_playing == true ? "PLAYING ON THE MAC" : "PAUSED ON THE MAC").font(.machine(10)).tracking(1).foregroundStyle(mint)
            Text(track.title).font(.ui(typeSize.isAccessibilitySize ? 18 : 23, .semibold)).foregroundStyle(Ink.ink)
            Text(track.artist).font(.ui(15)).foregroundStyle(Ink.dim)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(20).background(Ink.plaster,in:RoundedRectangle(cornerRadius:20)).accessibilityIdentifier("mac.current")
    }
    private var connection: some View {
        VStack(alignment:.leading, spacing:14) {
            Text(linked ? name : "The connection").font(.ui(21,.semibold)).foregroundStyle(Ink.ink)
            if linked {
                Text(endpoint).font(.machine(12)).foregroundStyle(Ink.dim).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:8)) : AnyLayout(HStackLayout(alignment:.top,spacing:12))) {
                    if let stamp = mac?.checked_at {
                        VStack(alignment:.leading,spacing:3) { Text("Last checked").font(.ui(11)); Text(Date(timeIntervalSince1970:stamp),style:.relative).font(.ui(12)) }.foregroundStyle(Ink.dim)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength:12) }
                    Button { run(check:true) } label: { Label("Check now",systemImage:"arrow.clockwise").font(.ui(14,.semibold)) }.frame(minHeight:44).disabled(!available || busy).accessibilityIdentifier("mac.check")
                }
                if busy { ProgressView().tint(mint).accessibilityLabel("Checking Mac connection") }
                if !editing { Button("Change address") { address=endpoint;editing=true }.frame(minHeight:44).accessibilityIdentifier("mac.edit") }
                if unlinking {
                    Text("Stop reading music from this Mac? Your phone and other players stay connected.").font(.ui(14)).foregroundStyle(Ink.dim)
                    Button("Disconnect Mac",role:.destructive) { save("") }.frame(minHeight:44).accessibilityIdentifier("mac.confirmDisconnect")
                    Button("Keep connected") { unlinking=false }.frame(minHeight:44)
                } else { Button("Disconnect Mac",role:.destructive) { unlinking=true }.frame(minHeight:44).disabled(!available || busy).accessibilityIdentifier("mac.disconnect") }
            } else { Text("The wall reads what your Mac is playing through its reporter. Your phone can send music directly to the wall without a Mac.").font(.ui(14)).foregroundStyle(Ink.dim) }
        }
    }
    private var editor: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Mac reporter address").font(.ui(16,.semibold))
            TextField("studio-mac.local:8787",text:$address).font(.machine(14)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($fieldFocused).padding(16).background(Ink.plaster,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("mac.address")
            if !address.isEmpty && Self.origin(address) == nil { Text("Use a hostname and port, without a path or password.").font(.ui(12)).foregroundStyle(Ink.dim) }
            Button("Save and check") { if let origin=Self.origin(address) { save(origin) } }.font(.ui(15,.semibold)).frame(maxWidth:.infinity,minHeight:50).foregroundStyle(Color(hex:0x17251F)).background(mint,in:RoundedRectangle(cornerRadius:14)).disabled(!canSave).opacity(canSave ? 1 : 0.4).accessibilityIdentifier("mac.save")
            if linked { Button("Cancel editing") { editing=false;address=endpoint }.frame(minHeight:44) }
        }.foregroundStyle(Ink.ink)
    }
    private var setup: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Set up the reporter").font(.ui(22,.semibold)).foregroundStyle(Ink.ink)
            step("01","Start the reporter","On the Mac, run the reporter from your Tessera checkout. Keep the Mac awake while listening.")
            ShareLink(item:"From the album-art-matrix folder on your Mac, run:\npython3 scripts/mac_reporter.py\n\nThen enter your Mac’s local hostname and port 8787 in Tessera.") { Label("Send setup to your Mac",systemImage:"square.and.arrow.up").font(.ui(14,.semibold)) }.frame(minHeight:44).accessibilityIdentifier("mac.shareSetup")
            step("02","Find its name","In Mac System Settings, open General, then Sharing. Use the local hostname shown there, with :8787 at the end.")
            step("03","Allow access","Allow the reporter’s Automation access to Music and local network access if macOS asks. For other players, install media-control on the Mac.")
        }
    }
    private func step(_ number:String,_ title:String,_ text:String) -> some View {
        HStack(alignment:.top,spacing:14) {
            Text(number).font(.machine(11)).foregroundStyle(mint).padding(.top,4)
            VStack(alignment:.leading,spacing:5) { Text(title).font(.ui(15,.semibold)).foregroundStyle(Ink.ink);Text(text).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal:false,vertical:true) }
        }
    }
    private var troubleshooting: some View {
        DisclosureGroup(isExpanded:$diagnostics) {
            VStack(alignment:.leading,spacing:16) {
                Text("Keep the Mac and wall on the same network. Guest Wi-Fi and a sleeping Mac can stop the connection. An idle reporter is still connected.").font(.ui(14)).foregroundStyle(Ink.dim)
                Link("Mac network permissions",destination:URL(string:"https://support.apple.com/en-nz/guide/mac-help/mchla4f49138/mac")!).frame(minHeight:44)
                Link("Reporter setup and source",destination:URL(string:"https://github.com/jke48222/album-art-matrix/blob/main/scripts/mac_reporter.py")!).frame(minHeight:44)
                Link("Support other Mac players",destination:URL(string:"https://github.com/ungive/media-control")!).frame(minHeight:44)
            }.padding(.top,16)
        } label: { Text("Connection help").font(.ui(16,.medium)).foregroundStyle(Ink.ink).accessibilityIdentifier("mac.help") }
    }
    private var forwardingControls: some View {
        DisclosureGroup(isExpanded:$extraForwarding) {
            VStack(alignment:.leading,spacing:14) {
                Text("Optional: also send this iPhone’s playback to a reporter. This is separate from the Mac address saved on your wall.").font(.ui(13)).foregroundStyle(Ink.dim)
                TextField("Mac hostname:8787",text:$forwarding).font(.machine(13)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padding(14).background(Ink.plaster,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("mac.forwardingAddress")
                Button("Save phone forwarding") {
                    let trimmed=forwarding.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard trimmed.isEmpty || Self.origin(trimmed)?.hasPrefix("http://") == true else { return }
                    wall.push.host=trimmed.isEmpty ? "" : String(Self.origin(trimmed)!.dropFirst(7));wall.push.restart();Taps.commit();notice=trimmed.isEmpty ? "Phone forwarding is off." : "Phone forwarding address saved."
                }.frame(minHeight:44).disabled(!forwarding.isEmpty && Self.origin(forwarding)?.hasPrefix("http://") != true).accessibilityIdentifier("mac.saveForwarding")
            }.padding(.top,16)
        } label: { Text("Phone forwarding").font(.ui(16,.medium)).foregroundStyle(Ink.ink) }
    }
    private func refresh(_ host:String,check:Bool=false) async {
        let id = operation
        let fresh=check ? await WallServices.retryMac(host:host) : await WallServices.read(host:host)
        guard !Task.isCancelled,host==wall.host,id==operation,scene == .active else { return }
        failed=fresh==nil;if let fresh { services=fresh }
    }
    private func run(check:Bool) {
        guard !busy else { return };busy=true;let host=wall.host;let id=UUID();operation=id
        request=Task { await refresh(host,check:check);guard !Task.isCancelled,id==operation,host==wall.host else { return };busy=false }
    }
    private func save(_ value:String) {
        guard available,!busy else { return };busy=true;fieldFocused=false;problem=nil;notice=nil;let host=wall.host;let id=UUID();operation=id
        request=Task {
            let (fresh,why)=await ServiceSave.send(["mac":["endpoint":value]],to:host)
            guard !Task.isCancelled,id==operation,host==wall.host else { return }
            if let fresh { services=fresh };problem=why;busy=false
            if why==nil && fresh?.mac?.endpoint != value { problem="The wall did not confirm this address. Your draft is kept."; return }
            if why==nil { editing=false;unlinking=false;address=value;notice=value.isEmpty ? "Mac disconnected." : "Address saved. The wall is checking the reporter.";Taps.commit() }
        }
    }
    private func cancel() { operation=UUID();request?.cancel();request=nil;busy=false }
}
