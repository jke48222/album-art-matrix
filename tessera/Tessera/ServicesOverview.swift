import SwiftUI

/// One route to each connection. The overview reads status; setup lives in its destination.
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
    private let mint = Color(hex: 0xADD2C5)
    private var available: Bool { wall.link.isLive && checked && !failed }
    private var spotifyReady: Bool { services?.spotify.linked == true && !["expired", "refused", "unavailable", "rate_limited", "checking"].contains(services?.spotify.state ?? "") }
    private var lastfmReady: Bool { ["idle", "playing"].contains(services?.lastfm.state ?? "") }
    private var listenbrainzReady: Bool { ["ready", "playing"].contains(services?.listenbrainz?.read_state ?? "") }
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
                    Text("SERVICES / CONNECT YOUR WORLD").font(.machine(9)).tracking(1.2).foregroundStyle(mint)
                    Text("Good music.\nEverywhere.").font(typeSize.isAccessibilitySize ? .ui(26, .semibold) : .display(42)).foregroundStyle(Ink.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose where you listen. Tessera brings it to the wall.").font(.ui(15)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                connectionSummary
                featuredLayout {
                    NavigationLink {
                        AppleMusicPage(accent: accent, musicConnected: $musicConnected, musicRefused: $musicRefused)
                    } label: {
                        featured(.appleMusic, detail: "From this iPhone", state: musicRefused ? "Permission needed" : musicConnected ? "Access allowed" : "Connect", ready: musicConnected, tint: Color(hex: 0xEBA19E))
                    }.buttonStyle(PressStyle(scale: 0.985)).accessibilityIdentifier("services.appleMusic")
                    NavigationLink { SpotifyPage(accent: accent, services: $services) } label: {
                        featured(.spotify, detail: "Across your devices", state: spotifyStatus, ready: available && spotifyReady, tint: mint)
                    }.buttonStyle(PressStyle(scale: 0.985)).accessibilityIdentifier("services.spotify")
                }
                section("More ways to listen", subtitle: "A player, a record, a room full of sound.") {
                    destination("Last.fm", detail: available && lastfmReady ? services?.lastfm.user ?? "Connected" : "Listening from linked music players", status: state(lastfmReady), service: .lastfm) { LastfmPage(accent: accent, services: $services) }
                    Rule()
                    destination("ListenBrainz", detail: "Your listening journal and scrobbles", status: state(listenbrainzReady), symbol: "waveform") { ListenBrainzPage(accent: accent, services: $services) }
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
                DisclosureGroup(isExpanded: $showPriority) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Playing music takes priority over a paused source. For the same song, a player’s pause takes priority over a stale listening report.").font(.ui(14)).foregroundStyle(Ink.dim)
                        if available, let order = services?.source_order, !order.isEmpty {
                            ForEach(Array(order.enumerated()), id: \.offset) { index, name in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    Text(String(format: "%02d", index + 1)).font(.machine(11)).foregroundStyle(mint)
                                    Text(Self.sourceName(name)).font(.ui(14)).foregroundStyle(Ink.ink)
                                }
                            }
                            Text("Your wall’s configured preference, in order.").font(.ui(12)).foregroundStyle(Ink.dim)
                        } else {
                            Text("Connect to the wall to read its source order.").font(.ui(13)).foregroundStyle(Ink.dim)
                        }
                    }.padding(.top, 14)
                } label: { Label("How the wall chooses", systemImage: "arrow.triangle.branch").font(.ui(15, .medium)).foregroundStyle(Ink.ink) }
                .tint(mint).padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                section("A little more possibility", subtitle: "Art, answers and your record collection.") {
                    destination("Claude", detail: "Questions and conversations", status: available && services?.claude?.problem != nil ? "Needs attention" : state(services?.claude?.isReady == true), symbol: "text.bubble") { ClaudePage(accent: accent, services: $services) }
                    Rule()
                    destination("Discogs", detail: "Bring your record shelf along", status: available && services?.discogs?.syncing == true ? "Reading collection" : available && services?.discogs?.problem != nil ? "Needs attention" : state(services?.discogs?.token_set == true && !(services?.discogs?.user ?? "").isEmpty), symbol: "opticaldisc") { DiscogsPage(accent: accent, services: $services) }
                    Rule()
                    destination("Images", detail: "Draw from your imagination", status: !available ? "Not checked" : services?.images?.busy == true ? "Drawing" : services?.images?.problem != nil ? "Needs attention" : services?.images?.ready != true ? "Set up" : services?.images?.verified == true ? "Ready" : "Key saved", symbol: "paintbrush") { ImagesPage(accent: accent, services: $services) }
                    Rule()
                    destination("Posters", detail: "The films and shows you love", status: !available ? "Not checked" : services?.tmdb?.checking == true ? "Checking" : services?.tmdb?.problem != nil ? "Needs attention" : services?.tmdb?.key_set != true ? "Set up" : services?.tmdb?.verified == true ? "Ready" : "Key saved", symbol: "tv") { PostersPage(accent: accent, services: $services) }
                    Rule()
                    destination("Pictures", detail: "Search the web or your Google provider", status: available ? (services?.google?.key_set == true && services?.google?.cx_set == true ? "Google ready" : "Web search") : "Not checked", symbol: "photo") { PicturesPage(accent: accent, services: $services) }
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
            if qaRoute == "lastfm" { LastfmPage(accent: accent, services: $services) }
            else if qaRoute == "listenbrainz" { ListenBrainzPage(accent: accent, services: $services) }
            else if qaRoute == "otherPlayers" { OtherPlayersPage(accent: accent, services: $services) }
            else if qaRoute == "claude" { ClaudePage(accent: accent, services: $services) }
            else if qaRoute == "discogs" { DiscogsPage(accent: accent, services: $services) }
            else if qaRoute == "posters" { PostersPage(accent: accent, services: $services) }
            else if qaRoute == "images" { ImagesPage(accent: accent, services: $services) }
            else if qaRoute == "airplay" { AirPlayPage(accent: accent, services: $services) }
            else if qaRoute == "homekit" { HomeKitPage(accent: accent) }
            else if qaRoute == "mac" { MacReporterPage(accent: accent, services: $services) }
            else if qaRoute == "spotify" { SpotifyPage(accent: accent, services: $services) }
            else { AppleMusicPage(accent: accent, musicConnected: $musicConnected, musicRefused: $musicRefused) }
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
    private func state(_ ready: Bool) -> String { available ? (ready ? "Ready" : "Set up") : "Not checked" }
    private func featured(_ service: Service, detail: String, state: String, ready: Bool, tint: Color) -> some View {
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
    }
    private func section<C: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.ui(19, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim)
            VStack(spacing: 0, content: content).padding(.horizontal, 17).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    private func destination<C: View>(_ title: String, detail: String, status: String, service: Service? = nil, symbol: String = "link", @ViewBuilder page: () -> C) -> some View {
        NavigationLink(destination: page) {
            HStack(alignment: .center, spacing: 13) {
                if !typeSize.isAccessibilitySize {
                    if let service { ServiceMark(service: service) } else { GlyphMark(symbol: symbol) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                    Text(detail).font(.ui(12)).foregroundStyle(Ink.dim)
                    Text(status).font(.machine(9)).foregroundStyle(status == "Ready" ? mint : Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2); Chevron()
            }.padding(.vertical, 17).contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.99)).accessibilityElement(children: .combine)
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
        ["phone": "This iPhone", "airplay": "AirPlay", "applemusic": "Apple Music / Mac reporter", "mac": "Mac reporter", "spotify": "Spotify", "lastfm": "Last.fm", "listenbrainz": "ListenBrainz", "ears": "The wall’s ears", "posters": "Film and TV recognition"][name] ?? name
    }
}
