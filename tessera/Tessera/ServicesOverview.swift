import SwiftUI

private let servicesMint = Color(hex: 0xADD2C5)

/// One route to each connection. The overview reads status; setup lives in its destination.
///
/// Rows, cards and sections are their own small views. Built inline in one
/// body, the page was a single generic type so large that an unoptimised
/// (Debug) build overflowed the iPhone's main-thread stack while SwiftUI
/// instantiated it; the simulator's larger stack hid this.
struct ServicesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?
    @Binding var musicConnected: Bool
    @Binding var musicRefused: Bool
    @State private var refreshing = false
    @State private var failed = false
    @State private var checked = false
    @State private var sourceHost = ""
    @State private var showPriority = false
    @State private var qaRoute: String?
    private let mint = servicesMint
    private var available: Bool { wall.link.isLive && checked && !failed }
    private var spotifyReady: Bool { services?.spotify.linked == true && !["expired", "refused", "unavailable", "rate_limited", "checking"].contains(services?.spotify.state ?? "") }
    /// A configured account stays ready while another source plays: the wall
    /// stops re-checking a reader that is out of the chain, and its state
    /// falls back to "ready" or "checking". Only a real error is not ready.
    private var lastfmReady: Bool {
        guard let lastfm = services?.lastfm else { return false }
        return lastfm.key_set == true && !lastfm.user.isEmpty
            && !["refused", "not_found", "needs_key", "unlinked", "unconfigured", "unavailable", "rate_limited"].contains(lastfm.state ?? "")
    }
    private var listenbrainzReady: Bool {
        !(services?.listenbrainz?.user ?? "").isEmpty
            && !["refused", "unlinked", "offline", "unavailable", "rate_limited"].contains(services?.listenbrainz?.read_state ?? "")
    }
    private static let troubled = ["refused", "not_found", "unavailable", "offline", "rate_limited"]
    private var readyCount: Int {
        [musicConnected, available && spotifyReady,
         available && lastfmReady, available && listenbrainzReady,
         available && services?.hearing?.listening == true, available && services?.airplay?.running == true].filter { $0 }.count
    }
    private var featuredLayout: AnyLayout { typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SERVICES").font(.machine(9)).tracking(1.2).foregroundStyle(mint)
                    // At accessibility sizes the headline is capped, so a word never splits across lines.
                    Text("Connect where your music plays").font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(42)).foregroundStyle(Ink.ink)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose where you listen. Tessera brings it to the wall.").font(.ui(15)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                connectionSummary
                recommendation
                featuredLayout {
                    FeaturedServiceLink(service: .appleMusic, detail: "From this iPhone", state: musicRefused ? "Permission needed" : musicConnected ? "Access allowed" : "Connect", ready: musicConnected, tint: Color(hex: 0xEBA19E)) {
                        AppleMusicPage(accent: accent, musicConnected: $musicConnected, musicRefused: $musicRefused)
                    }.accessibilityIdentifier("services.appleMusic")
                    FeaturedServiceLink(service: .spotify, detail: "Across your devices", state: spotifyStatus, ready: available && spotifyReady, tint: mint) {
                        SpotifyPage(accent: accent, services: $services)
                    }.accessibilityIdentifier("services.spotify")
                }
                ServiceSection(title: "More ways to listen", subtitle: "Other music sources, players and the room.") {
                    destination("Last.fm", detail: available && lastfmReady ? services?.lastfm.user ?? "Connected" : "Listening from linked music players", status: journalStatus(lastfmReady, services?.lastfm.state), service: .lastfm) { LastfmPage(accent: accent, services: $services) }
                    Rule()
                    destination("ListenBrainz", detail: "Your listening journal and scrobbles", status: journalStatus(listenbrainzReady, services?.listenbrainz?.read_state), symbol: "waveform") { ListenBrainzPage(accent: accent, services: $services) }
                    Rule()
                    destination("Other music players", detail: "Tidal, Deezer, SoundCloud and more", status: "Find a path", symbol: "point.3.connected.trianglepath.dotted") { OtherPlayersPage(accent: accent, services: $services) }
                        .accessibilityIdentifier("services.otherPlayers")
                    Rule()
                    destination("The wall’s ears", detail: "Recognize music playing in the room", status: state(services?.hearing?.listening == true), symbol: "ear") { HearingPage(accent: accent, services: $services) }
                    Rule()
                    destination("AirPlay", detail: "Send audio to your wall", status: state(services?.airplay?.running == true), symbol: "airplayaudio") { AirPlayPage(accent: accent, services: $services) }
                    Rule()
                    destination("Your Mac", detail: "Playback from the Mac reporter", status: state(services?.mac?.answering == true), symbol: "desktopcomputer") { MacReporterPage(accent: accent, services: $services) }
                }
                SourceOrderDisclosure(expanded: $showPriority, order: available ? (services?.source_order ?? []).map(Self.sourceName) : [])
                ServiceSection(title: "Other connections", subtitle: "Questions, records, pictures and posters.") {
                    destination("Claude", detail: "Questions and conversations", status: available && services?.claude?.isOff == true ? "Off" : available && services?.claude?.problem != nil ? "Needs attention" : state(services?.claude?.isReady == true), symbol: "text.bubble") { ClaudePage(accent: accent, services: $services) }
                    Rule()
                    destination("Discogs", detail: "Your Discogs collection", status: available && services?.discogs?.syncing == true ? "Reading collection" : available && services?.discogs?.problem != nil ? "Needs attention" : state(services?.discogs?.token_set == true && !(services?.discogs?.user ?? "").isEmpty), symbol: "opticaldisc") { DiscogsPage(accent: accent, services: $services) }
                    Rule()
                    destination("Images", detail: "Pictures from a description", status: !available ? "Not checked" : services?.images?.busy == true ? "Drawing" : services?.images?.problem != nil ? "Needs attention" : services?.images?.ready != true ? "Set up" : services?.images?.verified == true ? "Ready" : "Key saved", symbol: "paintbrush") { ImagesPage(accent: accent, services: $services) }
                    Rule()
                    destination("Posters", detail: "Film and TV posters", status: !available ? "Not checked" : services?.tmdb?.checking == true ? "Checking" : services?.tmdb?.problem != nil ? "Needs attention" : services?.tmdb?.key_set != true ? "Set up" : services?.tmdb?.verified == true ? "Ready" : "Key saved", symbol: "tv") { PostersPage(accent: accent, services: $services) }
                    Rule()
                    destination("Pictures", detail: "Search the web or your Google provider", status: picturesStatus, symbol: "photo") { PicturesPage(accent: accent, services: $services) }
                }

            }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 42)
        }
        .scrollIndicators(.hidden).background(Ink.ground.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task(id: "\(wall.host)|\(wall.link.isLive)|\(scene == .active)") {
            guard scene == .active else { return }
            musicConnected = Service.appleMusicAuthorized; musicRefused = Service.appleMusicRefused
            if sourceHost != wall.host { sourceHost = wall.host; checked = false; services = nil }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        #if DEBUG
        .navigationDestination(isPresented: Binding(get: { qaRoute != nil }, set: { if !$0 { qaRoute = nil } })) {
            ServicesQARoute(route: qaRoute ?? "", accent: accent, services: $services, musicConnected: $musicConnected, musicRefused: $musicRefused)
        }
        .onAppear {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "-service-page"), args.indices.contains(i + 1) { qaRoute = args[i + 1] }
        }
        #endif
    }
    private var connectionSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: available ? "checkmark.circle" : "antenna.radiowaves.left.and.right").font(.system(size: 24)).foregroundStyle(mint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(available ? "\(readyCount) listening source\(readyCount == 1 ? "" : "s") ready" : refreshing ? "Reading your connections" : "Wall status unavailable")
                    .font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text(available ? "Phone access and wall connections, together." : "Apple Music access stays on this phone. Wall connections will refresh when it answers.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                if !available && !refreshing {
                    Button("Try again") { Task { await refresh() } }.font(.ui(14, .semibold)).foregroundStyle(mint).frame(minHeight: 44).accessibilityIdentifier("services.retry")
                }
            }
            Spacer(minLength: 0)
            if refreshing { ProgressView().tint(mint).accessibilityLabel("Refreshing connections") }
        }.padding(18).background(mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
    private var spotifyStatus: String {
        guard available else { return "Not checked" }
        if services?.spotify.state == "checking" { return "Checking" }
        if let status = services?.spotify.state, ["expired", "refused", "unavailable", "rate_limited"].contains(status) { return "Needs attention" }
        return services?.spotify.linked == true ? "Connected" : "Connect"
    }
    /// Off comes first: a wall with Show me switched off also reports a problem.
    private var picturesStatus: String {
        guard available else { return "Not checked" }
        let google = services?.google
        if google?.state == "off" { return "Off" }
        if google?.checking == true { return "Checking" }
        if google?.problem != nil { return "Needs attention" }
        guard google?.key_set == true && google?.cx_set == true else { return "Built-in search" }
        return google?.verified == true ? "Google checked" : "Saved"
    }
    private func state(_ ready: Bool) -> String { available ? (ready ? "Ready" : "Set up") : "Not checked" }
    /// An account in an error state needs attention, not setup.
    private func journalStatus(_ ready: Bool, _ reported: String?) -> String {
        if available, Self.troubled.contains(reported ?? "") { return "Needs attention" }
        return state(ready)
    }
    /// One next step, from state already on this page. Refused phone access
    /// comes first because nothing on the wall can fix it.
    private enum NextStep { case settings, spotifyReconnect, spotifyCheck, appleMusic }
    private var nextStep: NextStep? {
        if musicRefused { return .settings }
        guard available else { return nil }
        switch services?.spotify.state ?? "" {
        case "expired", "refused": return .spotifyReconnect
        case "unavailable", "rate_limited": return .spotifyCheck
        default: break
        }
        return readyCount == 0 && !musicConnected ? .appleMusic : nil
    }
    @ViewBuilder private var recommendation: some View {
        if let step = nextStep {
            NavigationLink {
                switch step {
                case .settings, .appleMusic: AppleMusicPage(accent: accent, musicConnected: $musicConnected, musicRefused: $musicRefused)
                case .spotifyReconnect, .spotifyCheck: SpotifyPage(accent: accent, services: $services)
                }
            } label: {
                HStack(alignment: .center, spacing: 13) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Next step").font(.ui(12, .medium)).foregroundStyle(mint)
                        Text(Self.title(step)).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text(Self.detail(step)).font(.ui(12)).foregroundStyle(Ink.dim)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2); Chevron()
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18)).contentShape(RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(PressStyle(scale: 0.99)).accessibilityElement(children: .combine)
                .accessibilityIdentifier("services.nextStep")
        }
    }
    private static func title(_ step: NextStep) -> String {
        switch step {
        case .settings: "Allow Apple Music in Settings"
        case .spotifyReconnect: "Reconnect Spotify"
        case .spotifyCheck: "Check Spotify"
        case .appleMusic: "Allow Apple Music on this iPhone"
        }
    }
    private static func detail(_ step: NextStep) -> String {
        switch step {
        case .settings: "Music access is off for Tessera on this iPhone."
        case .spotifyReconnect: "The wall can no longer read your Spotify account."
        case .spotifyCheck: "The wall cannot reach Spotify right now."
        case .appleMusic: "No listening source is ready yet. Start with the music on this iPhone."
        }
    }
    private func destination<C: View>(_ title: String, detail: String, status: String, service: Service? = nil, symbol: String = "link", @ViewBuilder page: @escaping () -> C) -> ServiceRow<C> {
        ServiceRow(title: title, detail: detail, status: status, service: service, symbol: symbol, page: page)
    }
    private func refresh() async {
        guard !refreshing else { return }
        guard wall.link.isLive else { failed = true; return }
        refreshing = true
        let host = wall.host
        defer { refreshing = false }
        let result = await WallServices.read(host: host)
        guard !Task.isCancelled, wall.host == host, wall.link.isLive else { return }
        checked = true; failed = result == nil
        if let result { services = result }
    }
    private static func sourceName(_ name: String) -> String {
        ["phone": "This iPhone", "airplay": "AirPlay", "applemusic": "Apple Music / Mac reporter", "mac": "Mac reporter", "spotify": "Spotify", "lastfm": "Last.fm", "listenbrainz": "ListenBrainz", "ears": "The wall’s ears", "posters": "Film and TV recognition", "applemusic-account": "Apple Music account"][name] ?? name
    }
}

/// A large card for one of the two main music services.
private struct FeaturedServiceLink<Page: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let service: Service
    let detail: String
    let state: String
    let ready: Bool
    let tint: Color
    @ViewBuilder let page: () -> Page
    var body: some View {
        NavigationLink(destination: page) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    ServiceMark(service: service, side: 48)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 20, weight: .medium)).foregroundStyle(tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(service.name).font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
                    Text(detail).font(.ui(13)).foregroundStyle(Ink.dim)
                }
                Label(state, systemImage: ready ? "checkmark.circle.fill" : "arrow.right.circle")
                    .font(.ui(13, .medium)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true).frame(minHeight: typeSize.isAccessibilitySize ? 0 : 34, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(LinearGradient(colors: [tint.opacity(0.13), Ink.plaster], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(tint.opacity(0.15), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 23)).accessibilityElement(children: .combine)
        }.buttonStyle(PressStyle(scale: 0.985))
    }
}

/// A titled group of rows on a plaster card.
private struct ServiceSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.ui(19, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim)
            VStack(spacing: 0, content: content).padding(.horizontal, 17).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// One row that opens a connection's own page.
struct ServiceRow<Page: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let detail: String
    let status: String
    let service: Service?
    let symbol: String
    @ViewBuilder let page: () -> Page
    var body: some View {
        NavigationLink(destination: page) {
            HStack(alignment: .center, spacing: 13) {
                if !typeSize.isAccessibilitySize {
                    if let service { ServiceMark(service: service) } else { GlyphMark(symbol: symbol) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                    Text(detail).font(.ui(12)).foregroundStyle(Ink.dim)
                    Text(status).font(.machine(9)).foregroundStyle(status == "Ready" ? servicesMint : Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2); Chevron()
            }.padding(.vertical, 17).contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.99)).accessibilityElement(children: .combine)
    }
}

/// How the wall picks between sources, with its configured order when known.
private struct SourceOrderDisclosure: View {
    @Binding var expanded: Bool
    /// Display names in the wall's order; empty when the wall has not answered.
    let order: [String]
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Playing music takes priority over a paused source. For the same song, a player’s pause takes priority over a stale listening report.").font(.ui(14)).foregroundStyle(Ink.dim)
                if !order.isEmpty {
                    ForEach(Array(order.enumerated()), id: \.offset) { index, name in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(String(format: "%02d", index + 1)).font(.machine(11)).foregroundStyle(servicesMint)
                            Text(name).font(.ui(14)).foregroundStyle(Ink.ink)
                        }
                    }
                    Text("Your wall’s configured preference, in order.").font(.ui(12)).foregroundStyle(Ink.dim)
                } else {
                    Text("Connect to the wall to read its source order.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }.padding(.top, 14)
        } label: { Label("How the wall chooses", systemImage: "arrow.triangle.branch").font(.ui(15, .medium)).foregroundStyle(Ink.ink) }
        .tint(servicesMint).padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
    }
}

#if DEBUG
/// The page a -service-page launch argument opens, for QA.
private struct ServicesQARoute: View {
    let route: String
    let accent: Color
    @Binding var services: WallServices?
    @Binding var musicConnected: Bool
    @Binding var musicRefused: Bool
    var body: some View {
        switch route {
        case "lastfm": LastfmPage(accent: accent, services: $services)
        case "listenbrainz": ListenBrainzPage(accent: accent, services: $services)
        case "otherPlayers": OtherPlayersPage(accent: accent, services: $services)
        case "claude": ClaudePage(accent: accent, services: $services)
        case "discogs": DiscogsPage(accent: accent, services: $services)
        case "pictures": PicturesPage(accent: accent, services: $services)
        case "posters": PostersPage(accent: accent, services: $services)
        case "images": ImagesPage(accent: accent, services: $services)
        case "airplay": AirPlayPage(accent: accent, services: $services)
        case "homekit": HomeKitPage(accent: accent)
        case "mac": MacReporterPage(accent: accent, services: $services)
        case "spotify": SpotifyPage(accent: accent, services: $services)
        default: AppleMusicPage(accent: accent, musicConnected: $musicConnected, musicRefused: $musicRefused)
        }
    }
}
#endif
