import SwiftUI
import UIKit

struct SpotifyPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @Binding var services: WallServices?
    @State private var clientID = ""
    @State private var busy = false
    @State private var readFailed = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var copied = false
    @State private var setupExpanded = false
    @State private var confirmUnlink = false
    @State private var spotify = SpotifyLink()
    @State private var request: Task<Void, Never>?
    @State private var operation = UUID()
    @FocusState private var editingID: Bool
    private let green = Color(hex: 0xA9D5AD)
    private var linked: Bool { services?.spotify.linked == true }
    private var savedID: String { services?.spotify.client_id ?? "" }
    private var typedID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var working: Bool { busy || spotify.busy }
    private var available: Bool { wall.link.isLive && services != nil && !readFailed }
    private var state: String { services?.spotify.state ?? (linked ? "ready" : savedID.isEmpty ? "unconfigured" : "unlinked") }
    private var needsSignIn: Bool { !linked || state == "expired" }
    private var validID: Bool { typedID.range(of: "^[0-9A-Za-z]{8,64}$", options: .regularExpression) != nil }
    private var hasID: Bool { !savedID.isEmpty || !DeveloperKeys.spotifyClientID.isEmpty }
    private var statusLabel: String {
        if !available { return "Waiting for the wall" }
        if working { return spotify.busy ? progressTitle : "Updating connection" }
        switch state {
        case "checking": return "Checking Spotify…"
        case "playing": return "Following your music"
        case "paused": return "Playback is paused"
        case "idle": return "Ready for your next song"
        case "expired": return "Sign-in needs renewing"
        case "refused": return "Access needs attention"
        case "rate_limited": return "Waiting for Spotify"
        case "unavailable": return "Spotify is unavailable"
        default: return linked ? "Account connected" : "Not connected yet"
        }
    }
    private var statusSymbol: String {
        if !available { return "wifi.slash" }
        switch state {
        case "playing": return "waveform"
        case "paused": return "pause.circle"
        case "expired", "refused", "unavailable": return "exclamationmark.circle"
        case "rate_limited": return "clock"
        default: return linked ? "checkmark.circle" : "link"
        }
    }
    private var progressTitle: String {
        switch spotify.phase {
        case .authorizing: return "Continue in Spotify"
        case .exchanging: return "Finishing sign-in"
        case .saving: return "Connecting your wall"
        default: return "Connecting"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                connection
                if let text = problem ?? spotify.problem ?? services?.spotify.problem {
                    Label(text, systemImage: "exclamationmark.circle")
                        .font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.tile.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(green).fixedSize(horizontal: false, vertical: true)
                } else if spotify.phase == .cancelled {
                    Text("Sign-in closed. Your connection status is shown above.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if !available {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your connection stays saved.").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text("Reconnect to the wall to sign in or change accounts.").font(.ui(14)).foregroundStyle(Ink.dim)
                        Button("Check the wall again", systemImage: "arrow.clockwise") { Task { await refresh(host: wall.host) } }
                            .font(.ui(15, .semibold)).frame(minHeight: 44).foregroundStyle(green)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if linked { account }
                setup
                fallback
                Text("Spotify plays on your devices. Tessera follows the song and shows its artwork on the wall.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 36)
        }.background(Ink.ground).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Spotify").navigationBarTitleDisplayMode(.inline).tint(green)
            .task(id: wall.host) {
                let host = wall.host
                clientID = savedID
                while !Task.isCancelled {
                    if !working { await refresh(host: host) }
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .onChange(of: savedID) { old, next in if clientID.isEmpty || clientID == old { clientID = next } }
            .onChange(of: wall.host) { _, _ in cancel(); services = nil; clientID = ""; readFailed = true; problem = nil; notice = nil }
            .onDisappear { cancel() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 14) {
                    ServiceMark(service: .spotify, side: 40)
                    Text(statusLabel).font(.ui(13, .medium)).foregroundStyle(green)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Spotify, \(statusLabel)")
            } else {
                HStack(alignment: .top) {
                    ServiceMark(service: .spotify, side: 44)
                    Spacer()
                    Text("MUSIC, CONNECTED").font(.custom(Face.monoMedium, size: 9, relativeTo: .caption2))
                        .tracking(1.2).foregroundStyle(green).multilineTextAlignment(.trailing)
                }
                Text(state == "expired" ? "Let’s reconnect." : linked ? "Your music.\nAll around." : "Let the music\nfind your wall.")
                    .font(.display(42)).tracking(-0.7).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                connectionDrawing
                Label(statusLabel, systemImage: statusSymbol).font(.ui(13, .medium)).foregroundStyle(green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(typeSize.isAccessibilitySize ? 18 : 24).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 27).fill(LinearGradient(colors: [Color(hex: 0x20392B), Color(hex: 0x121D17)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }.overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(green.opacity(0.14), lineWidth: 1))
    }
    private var connectionDrawing: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 13) {
                    Image(systemName: "iphone"); Image(systemName: "laptopcomputer"); Image(systemName: "hifispeaker")
                }.font(.system(size: 21, weight: .light)).foregroundStyle(Ink.ink.opacity(0.8)).frame(height: 30)
                Text("ANY DEVICE").font(.machine(8)).tracking(1.4).foregroundStyle(green.opacity(0.9))
            }
            Spacer(minLength: 12)
            Image(systemName: "arrow.right").font(.system(size: 15, weight: .light)).foregroundStyle(green.opacity(0.7))
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(green).frame(height: 30)
                Text("YOUR WALL").font(.machine(8)).tracking(1.4).foregroundStyle(green.opacity(0.9))
            }
        }.padding(.vertical, 6).accessibilityElement(children: .ignore)
            .accessibilityLabel("Music playing on your phone, computer or speaker appears on your wall")
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if working || state == "checking" {
                HStack(spacing: 12) { ProgressView().tint(green); Text(state == "checking" ? "Checking Spotify…" : spotify.busy ? progressTitle : "Updating your wall…").font(.ui(16, .medium)).foregroundStyle(Ink.ink) }
                    .frame(minHeight: 50).accessibilityElement(children: .combine)
                if spotify.busy { Button("Cancel sign-in") { cancel() }.font(.ui(14, .semibold)).frame(minHeight: 44) }
            } else if spotify.canRetryDelivery {
                primary("Retry sending to wall", symbol: "arrow.clockwise") { signIn(retry: true) }
            } else if needsSignIn {
                if hasID {
                    primary(state == "expired" ? "Reconnect Spotify" : "Connect Spotify", symbol: "arrow.up.right") { signIn() }
                    Text("Sign in securely with Spotify. Your password never reaches Tessera.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    primary("Set up your connection", symbol: "arrow.down") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { setupExpanded = true }
                    }
                }
            } else if ["refused", "unavailable"].contains(state) {
                primary("Check connection again", symbol: "arrow.clockwise") { retryConnection() }
            } else {
                Button { openURL(URL(string: "https://open.spotify.com")!) } label: {
                    HStack { Text("Open Spotify"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.ui(16, .semibold)).foregroundStyle(green).frame(minHeight: 48)
                }.buttonStyle(.plain)
                if state == "idle" || state == "ready" {
                    Text("Play a song on any connected device. Its artwork will follow you here.").font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) { Text(title).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 4); Image(systemName: symbol) }
                .font(.ui(16, .semibold)).foregroundStyle(Ink.ground).padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 54).background(green, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(PressStyle()).disabled(!available || working)
    }
    private var account: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.crop.circle").font(.system(size: 28, weight: .light)).foregroundStyle(green).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(services?.spotify.account_name ?? "Your Spotify account").font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
                    Text(state == "expired" ? "Saved on this wall · sign in again" : "Connected to this wall").font(.ui(13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let checked = services?.spotify.checked_at, checked.isFinite {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last checked").foregroundStyle(Ink.dim)
                    Spacer(minLength: 12)
                    Text(Date(timeIntervalSince1970: checked), style: .relative).foregroundStyle(Ink.ink)
                }.font(.ui(12)).accessibilityElement(children: .combine)
            }
            Divider().overlay(Ink.hairline)
            if confirmUnlink {
                Text("Disconnect from this wall?").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text("Your Spotify account and music stay as they are. Tessera will stop following this account.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 22) {
                    Button("Disconnect", role: .destructive) { unlink() }.foregroundStyle(Ink.signal)
                    Button("Keep connected") { confirmUnlink = false }.foregroundStyle(green)
                }.font(.ui(14, .semibold)).frame(minHeight: 44).disabled(working || !available)
            } else {
                Button("Disconnect account", systemImage: "person.crop.circle.badge.minus") { confirmUnlink = true }
                    .font(.ui(14, .medium)).foregroundStyle(Ink.dim).frame(minHeight: 44).disabled(working || !available)
            }
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }
    private var setup: some View {
        DisclosureGroup(isExpanded: $setupExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                Text("A personal Spotify app lets this wall follow your account. Its owner needs Spotify Premium, and listeners must be added under Users Management.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                    Label("Open Spotify dashboard", systemImage: "arrow.up.right").font(.ui(15, .semibold)).frame(minHeight: 44)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Add this redirect address").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text("In the app's settings, add the address exactly as shown.").font(.ui(13)).foregroundStyle(Ink.dim)
                    HStack(spacing: 8) {
                        Text(SpotifyLink.redirect).font(.machine(12)).foregroundStyle(Ink.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { UIPasteboard.general.string = SpotifyLink.redirect; copied = true; Taps.detent(intensity: 0.4) } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
                        }.accessibilityLabel(copied ? "Redirect address copied" : "Copy redirect address")
                    }.padding(.horizontal, 12).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("2. Paste the Client ID").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text("Use the Client ID from the same app. Tessera never asks for a client secret.").font(.ui(13)).foregroundStyle(Ink.dim)
                    TextField("Client ID", text: $clientID, axis: .vertical).font(.machine(12)).lineLimit(1...3)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).focused($editingID)
                        .padding(14).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Spotify Client ID")
                    if linked && typedID != savedID && !typedID.isEmpty {
                        Text("Changing the Client ID disconnects this account. You'll sign in again using the new app.").font(.ui(13)).foregroundStyle(Ink.tile).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(linked && typedID != savedID ? "Save ID and disconnect" : "Save Client ID") { save() }
                        .font(.ui(15, .semibold)).frame(minHeight: 48).disabled(!validID || typedID == savedID || !available || working)
                    if !typedID.isEmpty && !validID { Text("Enter the Client ID's letters and numbers, without spaces.").font(.ui(12)).foregroundStyle(Ink.dim) }
                }
            }.padding(.top, 16)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(hasID ? "Connection setup" : "Set up a Spotify app").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                Text(savedID.isEmpty ? "Your Client ID and sign-in address" : "Client ID saved on the wall").font(.ui(12)).foregroundStyle(Ink.dim)
            }.frame(minHeight: 48).fixedSize(horizontal: false, vertical: true)
        }.tint(green)
    }
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            Text("Another way to listen").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
            Text("Last.fm can follow Spotify too. Connect Spotify in your Last.fm account, then give Tessera your Last.fm name.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Link("Link Spotify on Last.fm", destination: URL(string: "https://www.last.fm/settings/applications")!)
                .font(.ui(14, .semibold)).frame(minHeight: 44)
            NavigationLink { LastfmPage(accent: accent, services: $services) } label: {
                HStack(spacing: 12) {
                    ServiceMark(service: .lastfm, side: 28)
                    Text("Last.fm setup").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Spacer(); Image(systemName: "chevron.right").font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
                }.frame(minHeight: 48)
            }.buttonStyle(.plain)
        }
    }

    private func refresh(host: String) async {
        guard !working else { return }
        let stamp = operation
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, operation == stamp, !working else { return }
        if let fresh { services = fresh; readFailed = false } else { readFailed = true }
    }
    private func begin(_ action: @escaping @MainActor (String, UUID) async -> Void) {
        guard !working, available else { return }
        busy = true; problem = nil; notice = nil; editingID = false
        let host = wall.host, token = UUID(); operation = token
        request = Task {
            await action(host, token)
            if operation == token { busy = false; request = nil }
        }
    }
    private func signIn(retry: Bool = false) {
        begin { host, token in
            if savedID.isEmpty && !DeveloperKeys.spotifyClientID.isEmpty {
                let seeded = await WallServices.seeded(host: host)
                guard operation == token, wall.host == host, !Task.isCancelled else { return }
                if let seeded { services = seeded }
            }
            let id = savedID
            guard !id.isEmpty else { problem = "Save a Client ID to the wall first."; return }
            let connected = retry ? await spotify.retryDelivery(host: host, clientID: id) : await spotify.connect(clientID: id, wall: host)
            guard operation == token, wall.host == host, !Task.isCancelled else { return }
            if connected {
                let fresh = await WallServices.read(host: host)
                guard operation == token, wall.host == host, !Task.isCancelled else { return }
                if let fresh { services = fresh; readFailed = false }
                notice = "Spotify is connected to your wall."; Taps.commit()
            }
        }
    }
    private func save() {
        let id = typedID
        guard validID else { return }
        begin { host, token in
            let (fresh, why) = await ServiceSave.send(["spotify": ["client_id": id]], to: host)
            guard operation == token, wall.host == host, !Task.isCancelled else { return }
            if let fresh { services = fresh }
            problem = why
            if why == nil && fresh?.spotify.client_id == id { spotify.cancel(); notice = "Client ID saved. You're ready to sign in."; Taps.commit() }
        }
    }
    private func retryConnection() {
        begin { host, token in
            let fresh = await WallServices.retrySpotify(host: host)
            guard operation == token, wall.host == host, !Task.isCancelled else { return }
            if let fresh { services = fresh; notice = "The wall is checking Spotify again." }
            else { problem = "The connection could not be checked. Please try again shortly." }
        }
    }
    private func unlink() {
        begin { host, token in
            let fresh = await WallServices.unlinkSpotify(host: host)
            guard operation == token, wall.host == host, !Task.isCancelled else { return }
            if let fresh, !fresh.spotify.linked { services = fresh; confirmUnlink = false; notice = "Disconnected from this wall."; Taps.commit() }
            else { problem = "The wall hasn't confirmed the disconnect. Please try again." }
        }
    }
    private func cancel() { operation = UUID(); request?.cancel(); request = nil; spotify.cancel(); busy = false }
}
