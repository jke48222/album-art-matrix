import SwiftUI

struct LastfmPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    @Binding var services: WallServices?

    @State private var user = ""
    @State private var key = ""
    @State private var busy = false
    @State private var readFailed = false
    @State private var editing = false
    @State private var confirmUnlink = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var request: Task<Void, Never>?
    @State private var operation = UUID()
    @FocusState private var focused: Field?
    private enum Field { case user, key }
    private let coral = Color(hex: 0xF4A49A)

    private var account: WallServices.Lastfm? { services?.lastfm }
    private var savedUser: String { account?.user ?? "" }
    private var keySet: Bool { account?.key_set == true }
    private var keyBaked: Bool { !DeveloperKeys.lastfmAPIKey.isEmpty }
    private var connected: Bool { !savedUser.isEmpty && keySet }
    private var available: Bool { wall.link.isLive && services != nil && !readFailed }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validUser: Bool { typedUser.range(of: "^[^\\s/]{1,64}$", options: .regularExpression) != nil }
    private var validKey: Bool { typedKey.isEmpty || typedKey.range(of: "^[0-9A-Za-z]{16,64}$", options: .regularExpression) != nil }
    private var canSave: Bool {
        available && !busy && validUser && validKey && (keySet || keyBaked || !typedKey.isEmpty)
            && (typedUser != savedUser || !typedKey.isEmpty || !keySet)
    }
    private var state: String { account?.state ?? (connected ? "ready" : keySet ? "unlinked" : "unconfigured") }
    private var statusTitle: String {
        if !available { return "Waiting for your wall" }
        if busy { return "Updating your connection" }
        switch state {
        case "checking": return "Checking your listening"
        case "playing": return "Listening now"
        case "idle": return "Ready for the next song"
        case "ready": return "Ready to check"
        case "refused": return "Access needs attention"
        case "not_found": return "Profile not found"
        case "rate_limited": return "Giving Last.fm a moment"
        case "unavailable": return "Last.fm is unavailable"
        case "needs_key": return "Add an API key"
        default: return "Connect your listening"
        }
    }
    private var statusSymbol: String {
        if !available { return "wifi.slash" }
        switch state {
        case "playing": return "waveform"
        case "checking", "rate_limited": return "clock"
        case "refused", "not_found", "unavailable": return "exclamationmark.circle"
        default: return connected ? "checkmark.circle" : "link"
        }
    }
    private var current: WallServices.Lastfm.Track? { available && state == "playing" ? account?.current : nil }
    /// As on Spotify's page: saved details are not a working connection when
    /// the status line under the headline says the access needs attention.
    private var headline: String {
        guard connected else { return "Last.fm" }
        return ["refused", "not_found", "unavailable", "rate_limited"].contains(state) ? "Last.fm needs attention" : "Last.fm is connected"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if connected { listening }
                if let text = problem ?? account?.problem, available || problem != nil {
                    Label(text, systemImage: "exclamationmark.circle")
                        .font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("lastfm.problem")
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(coral)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("lastfm.notice")
                }
                if !available { offline }
                // Only after a read: with nothing read from this wall its saved
                // profile is unknown, and a connected person must not be asked to connect.
                if services != nil && (!connected || editing) { editor }
                if connected { accountActions }
                reporting
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 36)
        }
        .background(Ink.ground).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        .navigationTitle("Last.fm").navigationBarTitleDisplayMode(.inline).tint(coral)
        .refreshable { await refresh(host: wall.host, check: true) }
        .task(id: "\(wall.host)|\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            if !editing { user = savedUser }
            while !Task.isCancelled {
                if !busy { await refresh(host: host) }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: savedUser) { old, next in if user.isEmpty || user == old { user = next } }
        .onChange(of: wall.host) { _, _ in
            cancel(); services = nil; user = ""; key = ""; editing = false
            confirmUnlink = false; readFailed = true; problem = nil; notice = nil
        }
        .onChange(of: scenePhase) { _, next in if next != .active { cancel(); key = "" } }
        .onDisappear { cancel(); key = "" }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 14 : 22) {
            HStack(alignment: .top, spacing: 14) {
                ServiceMark(service: .lastfm, side: 42)
                if typeSize.isAccessibilitySize {
                    Text(statusTitle).font(.ui(14, .semibold)).foregroundStyle(coral)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Spacer()
                    Text("THE LISTENING JOURNAL").font(.custom(Face.monoMedium, size: 9, relativeTo: .caption2))
                        .tracking(1.2).foregroundStyle(coral).multilineTextAlignment(.trailing)
                }
            }
            if typeSize.isAccessibilitySize, !savedUser.isEmpty {
                Text("@\(savedUser)").font(.ui(12, .medium)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Last.fm profile, \(savedUser)")
            }
            if !typeSize.isAccessibilitySize {
                Text(headline)
                    .font(.display(42)).tracking(-0.8).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(savedUser.isEmpty ? "LAST.FM TO YOUR WALL" : "@\(savedUser)")
                            .font(.machine(12)).foregroundStyle(coral).lineLimit(2)
                        Label(statusTitle, systemImage: statusSymbol).font(.ui(13, .medium)).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    listeningMark.frame(width: 60, height: 42).accessibilityHidden(true)
                }
            }
        }
        .padding(typeSize.isAccessibilitySize ? 18 : 24).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 27)
                .fill(LinearGradient(colors: [Color(hex: 0x3B2328), Color(hex: 0x201A1D)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(coral.opacity(0.16), lineWidth: 1))
        .accessibilityIdentifier("lastfm.hero")
    }

    private var listeningMark: some View {
        Canvas { context, size in
            let heights: [Int] = [2, 4, 6, 3, 5, 7, 4, 2]
            for column in heights.indices {
                for row in 0..<7 {
                    let lit = row >= 7 - heights[column]
                    let rect = CGRect(x: CGFloat(column) * size.width / 8, y: CGFloat(row) * size.height / 7, width: 4, height: 4)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(coral.opacity(lit ? 0.75 : 0.09)))
                }
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(current == nil ? "FROM YOUR PROFILE" : "LISTENING NOW").font(.machine(10)).tracking(1.3).foregroundStyle(coral)
                Spacer()
                if state == "checking" { ProgressView().controlSize(.small).tint(coral) }
            }
            if let current {
                track(current, live: true)
            } else if let recent = account?.last_listen {
                track(recent, live: false)
                Text("Your last scrobble. It isn’t reported as playing now.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state == "checking" ? "Finding your latest song…" : "No song playing right now")
                        .font(.display(typeSize.isAccessibilitySize ? 24 : 29)).foregroundStyle(Ink.ink)
                    Text("Play music in a player that reports Now Playing to Last.fm. The wall follows that public feed.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Ink.hairline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { checked; Spacer(minLength: 0); retryButton }
                VStack(alignment: .leading, spacing: 6) { checked; retryButton }
            }
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }

    private func track(_ item: WallServices.Lastfm.Track, live: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return layout {
            AsyncImage(url: item.art_url.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(coral.opacity(0.1)).overlay { Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(coral) }
            }
            .frame(width: typeSize.isAccessibilitySize ? 66 : 78, height: typeSize.isAccessibilitySize ? 66 : 78)
            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
                Text(item.artist).font(.ui(14)).foregroundStyle(coral)
                if let album = item.album, !album.isEmpty, album != "?" { Text(album).font(.ui(12)).foregroundStyle(Ink.dim) }
                if !live, let at = item.at, at.isFinite { Text(Date(timeIntervalSince1970: at), style: .relative).font(.ui(12)).foregroundStyle(Ink.dim) }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine).accessibilityIdentifier(live ? "lastfm.current" : "lastfm.lastListen")
    }

    private var checked: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Last checked").font(.ui(11)).foregroundStyle(Ink.dim)
            if let at = account?.checked_at, at.isFinite {
                Text(Date(timeIntervalSince1970: at), style: .relative).font(.ui(12, .medium)).foregroundStyle(Ink.ink)
            } else { Text("Not yet").font(.ui(12, .medium)).foregroundStyle(Ink.ink) }
        }.accessibilityElement(children: .combine)
    }

    private var retryButton: some View {
        Button { retry() } label: { Label(state == "checking" ? "Checking…" : "Check now", systemImage: "arrow.clockwise") }
            .font(.ui(14, .semibold)).foregroundStyle(coral).frame(minHeight: 44)
            .disabled(!available || busy || account?.can_retry == false || state == "checking")
            .accessibilityIdentifier("lastfm.retry")
    }

    private var offline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection settings live on your wall.").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
            Text("Reconnect to the wall to check Last.fm or change this account.").font(.ui(14)).foregroundStyle(Ink.dim)
            Button("Check the wall again", systemImage: "arrow.clockwise") { Task { await refresh(host: wall.host) } }
                .font(.ui(15, .semibold)).foregroundStyle(coral).frame(minHeight: 44)
                .accessibilityIdentifier("lastfm.reconnectWall")
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(connected ? "Edit your connection" : "Follow your profile").font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
                Spacer(minLength: 6)
                if connected { Button("Cancel") { closeEditor() }.font(.ui(14, .semibold)).foregroundStyle(coral).frame(minHeight: 44).disabled(busy) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Last.fm username").font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
                TextField("Your username", text: $user).focused($focused, equals: .user)
                    .font(.ui(17)).foregroundStyle(Ink.ink).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .submitLabel(.done).onSubmit { if canSave { save() } }
                    .padding(15).frame(minHeight: 52).background(Ink.ground, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("lastfm.username")
                Text(!typedUser.isEmpty && !validUser ? "Enter the username from your profile, without spaces or the web address." : "The name after last.fm/user/ in your profile address.")
                    .font(.ui(12)).foregroundStyle(!typedUser.isEmpty && !validUser ? coral : Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !keyBaked || keySet {
                VStack(alignment: .leading, spacing: 7) {
                    Text(keySet ? "Replace API key (optional)" : "API key").font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
                    SecureField(keySet ? "Saved privately on your wall" : "Paste your API key", text: $key)
                        .focused($focused, equals: .key).font(.ui(16)).foregroundStyle(Ink.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .privacySensitive().submitLabel(.done).onSubmit { if canSave { save() } }
                        .padding(15).frame(minHeight: 52).background(Ink.ground, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(keySet ? "Replacement Last.fm API key, optional" : "Last.fm API key")
                        .accessibilityIdentifier("lastfm.apiKey")
                    if !validKey { Text("Use the API key, 16 to 64 letters or numbers. Do not paste the shared secret.").font(.ui(12)).foregroundStyle(coral).fixedSize(horizontal: false, vertical: true) }
                    Link("Get a Last.fm API key", destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.ui(14, .semibold)).foregroundStyle(coral).frame(minHeight: 44)
                }
            }
            Button { save() } label: {
                HStack(spacing: 12) {
                    Text(busy ? "Saving connection…" : connected ? "Save changes" : "Connect Last.fm")
                    Spacer(minLength: 4)
                    if busy { ProgressView().tint(Ink.ground) } else { Image(systemName: "arrow.right") }
                }.font(.ui(16, .semibold)).foregroundStyle(canSave || busy ? Ink.ground : Ink.dim)
                    .padding(.horizontal, 17).padding(.vertical, 15).frame(maxWidth: .infinity, minHeight: 54)
                    .background(canSave || busy ? coral : Ink.tile.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(PressStyle()).disabled(!canSave).accessibilityIdentifier("lastfm.save")
            Text("Tessera reads public listening only. It doesn’t need your password or write to your Last.fm history.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !editing {
                Button {
                    user = savedUser; key = ""; confirmUnlink = false
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { editing = true }
                } label: { Label("Edit connection", systemImage: "slider.horizontal.3") }
                    .font(.ui(15, .semibold)).foregroundStyle(coral).frame(minHeight: 44)
                    .disabled(!available || busy).accessibilityIdentifier("lastfm.edit")
            }
            if confirmUnlink {
                Text("Stop following @\(savedUser)?").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text("Your Last.fm history stays untouched. The wall keeps its API key for your next connection.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { disconnectButton; keepButton }
                    VStack(alignment: .leading, spacing: 4) { disconnectButton; keepButton }
                }
            } else {
                Button("Disconnect account", systemImage: "person.crop.circle.badge.minus") { confirmUnlink = true; closeEditor() }
                    .font(.ui(14, .medium)).foregroundStyle(Ink.dim).frame(minHeight: 44)
                    .disabled(!available || busy).accessibilityIdentifier("lastfm.disconnect")
            }
        }
    }
    private var disconnectButton: some View {
        Button("Disconnect", role: .destructive) { disconnect() }.font(.ui(14, .semibold)).foregroundStyle(Ink.signal)
            .frame(minHeight: 44).disabled(busy || !available).accessibilityIdentifier("lastfm.confirmDisconnect")
    }
    private var keepButton: some View {
        Button("Keep connected") { confirmUnlink = false }.font(.ui(14, .semibold)).foregroundStyle(coral)
            .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("lastfm.keepConnected")
    }

    private var reporting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Players that report to Last.fm").font(.display(typeSize.isAccessibilitySize ? 23 : 28)).foregroundStyle(Ink.ink)
            Text("Your player must report Now Playing to Last.fm. Some scrobblers only send finished songs, so their artwork arrives after listening.")
                .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            NavigationLink { OtherPlayersPage(accent: accent, services: $services) } label: {
                HStack(spacing: 10) { Text("Connect another music player").fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); Image(systemName: "arrow.up.right") }
                    .font(.ui(15, .semibold)).foregroundStyle(coral).frame(minHeight: 48)
            }.accessibilityIdentifier("lastfm.otherPlayers")
        }.padding(.top, 4)
    }

    private func refresh(host: String, check: Bool = false) async {
        guard !busy else { return }
        let token = operation
        let fresh = await WallServices.read(host: host)
        guard !Task.isCancelled, operation == token, wall.host == host, !busy else { return }
        guard let fresh else { readFailed = true; return }
        services = fresh; readFailed = false
        let stale = fresh.lastfm.checked_at.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
        if fresh.lastfm.can_retry == true, check || stale {
            let checked = await WallServices.retryLastfm(host: host)
            guard !Task.isCancelled, operation == token, wall.host == host, !busy else { return }
            if let checked { services = checked }
        }
    }

    private func begin(_ action: @escaping @MainActor (String, UUID) async -> Void) {
        guard available, !busy else { return }
        busy = true; problem = nil; notice = nil; focused = nil
        let host = wall.host, token = UUID(); operation = token
        request = Task {
            await action(host, token)
            if operation == token { busy = false; request = nil }
        }
    }
    private func save() {
        guard canSave else { return }
        let name = typedUser
        var patch = ["user": name]
        if !typedKey.isEmpty { patch["api_key"] = typedKey }
        else if !keySet && keyBaked { patch["api_key"] = DeveloperKeys.lastfmAPIKey }
        begin { host, token in
            let (fresh, why) = await ServiceSave.send(["lastfm": patch], to: host)
            guard !Task.isCancelled, operation == token, wall.host == host else { return }
            if let fresh { services = fresh }
            problem = why
            if why == nil, fresh?.lastfm.user == name, fresh?.lastfm.key_set == true {
                key = ""; editing = false; notice = "Profile saved. The wall is checking your listening."; Taps.commit()
            } else if why == nil { problem = "The wall hasn’t confirmed this connection. Check the details and try again." }
        }
    }
    private func retry() {
        begin { host, token in
            let fresh = await WallServices.retryLastfm(host: host)
            guard !Task.isCancelled, operation == token, wall.host == host else { return }
            if let fresh { services = fresh }
            else { problem = "The connection could not be checked yet. Wait a moment and try again." }
        }
    }
    private func disconnect() {
        begin { host, token in
            let (fresh, why) = await ServiceSave.send(["lastfm": ["user": ""]], to: host)
            guard !Task.isCancelled, operation == token, wall.host == host else { return }
            if let fresh { services = fresh }
            if why == nil, fresh?.lastfm.user.isEmpty == true {
                confirmUnlink = false; user = ""; key = ""; editing = false
                notice = "This wall has stopped following your Last.fm profile."; Taps.commit()
            } else { problem = why ?? "The wall hasn’t confirmed the disconnect. Try again." }
        }
    }
    private func closeEditor() { focused = nil; key = ""; user = savedUser; editing = false }
    private func cancel() { operation = UUID(); request?.cancel(); request = nil; busy = false; focused = nil }
}

extension WallServices {
    struct Lastfm: Decodable {
        struct Track: Decodable {
            var title: String
            var artist: String
            var album: String?
            var art_url: String?
            var at: Double?
        }
        var user: String
        var key_set: Bool?
        var state: String?
        var problem: String?
        var checked_at: Double?
        var retry_after: Double?
        var can_retry: Bool?
        var current: Track?
        var last_listen: Track?
    }

}
