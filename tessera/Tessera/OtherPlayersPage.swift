import SwiftUI

/// Guidance leads to the existing connection editors. This page never impersonates
/// a provider's sign-in or infers that an installed music app is connected.
struct OtherPlayersPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @Binding var services: WallServices?
    @State private var player: GuidePlayer = .tidal
    @State private var journal: GuideJournal = .lastfm
    @State private var refreshing = false
    @State private var checkedHost = ""
    @State private var failed = false
    @State private var showNative = false
    private let blue = Color(hex: 0xA9C5DD)
    private var available: Bool { wall.link.isLive && checkedHost == wall.host && !failed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    if !typeSize.isAccessibilitySize {
                        Text("MORE WAYS TO LISTEN").font(.machine(9)).tracking(1.5).foregroundStyle(blue)
                    }
                    Text(typeSize.isAccessibilitySize ? "Choose your player" : "Your player.\nYour wall.")
                        .font(typeSize.isAccessibilitySize ? .ui(18, .semibold) : .display(42))
                        .foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
                    Text(typeSize.isAccessibilitySize ? "Find its path to your wall." : "Bring the music you love along. Choose a player to find its path to Tessera.")
                        .font(.ui(typeSize.isAccessibilitySize ? 13 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                playerPicker
                routeCard
                VStack(alignment: .leading, spacing: 20) {
                    Text("Make the connection").font(.ui(21, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
                    step("01", "Add Web Scrobbler", "Install it in the browser where you listen. It supports Chrome, Firefox and Safari, including Safari on iPhone.") {
                        external("Get the extension", "https://webscrobbler.com/", id: "otherPlayers.extension")
                    }
                    step("02", "Choose a listening journal", "In the extension’s Accounts settings, connect the same account you’ll use on your wall.") {
                        if typeSize.isAccessibilitySize {
                            journalPicker.pickerStyle(.menu)
                        } else {
                            journalPicker.pickerStyle(.segmented)
                        }
                    }
                    step("03", "Play in your browser", "Open \(player.name)’s website in that browser and start a song. The extension reports its title and artist to \(journal.rawValue).") {
                        external("Open \(player.name)", player.url, id: "otherPlayers.playerLink")
                    }
                    step("04", "Follow that account", "Add your \(journal.rawValue) username to Tessera. Listening reports may arrive a few seconds behind the player.") {
                        NavigationLink {
                            if journal == .lastfm { LastfmPage(accent: accent, services: $services) }
                            else { ListenBrainzPage(accent: accent, services: $services) }
                        } label: {
                            Label("Set up \(journal.rawValue)", systemImage: "arrow.right")
                                .font(.ui(15, .semibold)).foregroundStyle(blue).frame(minHeight: 44)
                        }.buttonStyle(PressStyle(scale: 0.98)).accessibilityIdentifier("otherPlayers.setup")
                    }
                }
                signalCard
                if let native = player.nativeGuide {
                    DisclosureGroup(isExpanded: $showNative) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(native.detail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                            external("Read the connection guide", native.url, id: "otherPlayers.nativeGuide")
                        }.padding(.top, 12)
                    } label: { Text("Using the \(player.name) app?").font(.ui(16, .medium)).foregroundStyle(Ink.ink) }
                    .tint(blue).padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Another way in").font(.ui(20, .semibold)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
                    Text("For music outside a browser, use a supported Mac player or let the wall recognize what’s playing in the room.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    NavigationLink { AddressesPage(accent: accent, onChange: {}) } label: {
                        alternative("Your Mac", "See reporter setup and connection status", symbol: "desktopcomputer")
                    }.accessibilityIdentifier("otherPlayers.mac")
                    NavigationLink { HearingPage(accent: accent, services: $services) } label: {
                        alternative("The wall’s ears", "Recognize music through the microphone", symbol: "ear")
                    }.accessibilityIdentifier("otherPlayers.ears")
                }.buttonStyle(PressStyle(scale: 0.99))
            }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 40)
        }
        .background(Ink.ground.ignoresSafeArea()).scrollIndicators(.hidden)
        .navigationTitle("Other players").navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task(id: "\(wall.host)|\(wall.link.isLive)|\(scene == .active)") {
            guard scene == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(12)) } catch { break }
            }
        }
        .onChange(of: player) { _, _ in showNative = false }
    }

    private var playerPicker: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(GuidePlayer.allCases) { value in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { player = value }
                    } label: {
                        VStack(spacing: 9) {
                            ServiceMark(service: value.service, side: 42)
                            Text(value.name).font(.ui(11, .medium)).foregroundStyle(player == value ? Ink.ink : Ink.dim)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: typeSize.isAccessibilitySize ? 0 : 28)
                        }.frame(width: typeSize.isAccessibilitySize ? 128 : 76, alignment: .top).padding(.vertical, 14)
                            .background(player == value ? blue.opacity(0.12) : Ink.plaster, in: RoundedRectangle(cornerRadius: 17))
                            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(player == value ? blue.opacity(0.7) : .clear, lineWidth: 1))
                    }.buttonStyle(PressStyle(scale: 0.96))
                        .accessibilityLabel(value.name).accessibilityAddTraits(player == value ? .isSelected : [])
                        .accessibilityIdentifier("otherPlayers." + value.rawValue)
                }
            }.padding(.vertical, 2)
        }.scrollIndicators(.hidden).accessibilityLabel("Choose your music player")
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(player.name).font(.ui(23, .semibold)).foregroundStyle(Ink.ink)
                Spacer(minLength: 8)
                if !typeSize.isAccessibilitySize { Text("WEB PLAYER").font(.machine(8)).tracking(0.7).foregroundStyle(blue) }
            }
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 0) {
                    routeNode(player.name) { ServiceMark(service: player.service, side: 37) }
                    routeLine
                    routeNode(journal.rawValue) {
                        if journal == .lastfm { ServiceMark(service: .lastfm, side: 37) }
                        else { Image(systemName: "waveform").font(.system(size: 27, weight: .medium)).foregroundStyle(blue).frame(width: 37, height: 37) }
                    }
                    routeLine
                    routeNode("Your wall") { Image(systemName: "square.grid.3x3.fill").font(.system(size: 30, weight: .regular)).foregroundStyle(blue).frame(width: 37, height: 37) }
                }.accessibilityHidden(true)
            }
            Text("A listening report carries the song to your wall. Your music keeps playing where you chose it.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(20)
            .background(LinearGradient(colors: [Color(hex: 0x202C34), Ink.plaster], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(blue.opacity(0.15), lineWidth: 1))
    }
    private var routeLine: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(blue.opacity(0.65)).frame(maxWidth: .infinity).padding(.bottom, 24)
    }
    private func routeNode<C: View>(_ label: String, @ViewBuilder mark: () -> C) -> some View {
        VStack(spacing: 12) {
            mark().frame(width: 58, height: 58).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
            Text(label).font(.ui(10)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity)
    }
    private func step<C: View>(_ number: String, _ title: String, _ description: String, @ViewBuilder action: () -> C) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.machine(11)).foregroundStyle(blue).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text(description).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                action()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("At the wall", systemImage: "antenna.radiowaves.left.and.right").font(.ui(18, .semibold)).foregroundStyle(Ink.ink)
            Text(signalTitle).font(.ui(15, .medium)).foregroundStyle(available ? blue : Ink.dim).accessibilityIdentifier("otherPlayers.signal")
            Text("This checks the listening source. Another player may have priority on the wall.").font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Button { Task { await refresh(check: true) } } label: {
                HStack(spacing: 8) {
                    if refreshing { ProgressView().tint(blue) }
                    Text(refreshing ? "Checking" : "Check the signal").font(.ui(14, .semibold))
                }.frame(minHeight: 44)
            }.foregroundStyle(blue).disabled(refreshing).accessibilityIdentifier("otherPlayers.check")
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 20))
    }
    private var signalTitle: String {
        guard available else { return "Connect to the wall to check its listening sources." }
        if journal == .lastfm {
            guard let account = services?.lastfm, !account.user.isEmpty else { return "Add your Last.fm username to the wall." }
            if account.state == "playing", let song = account.current { return "Last.fm reports \(song.title) by \(song.artist)." }
            if account.state == "checking" { return "Last.fm is checking \(account.user)’s listening." }
            if account.state == "idle" { return "Last.fm is connected. No song is being reported right now." }
            return account.problem ?? "The Last.fm profile is saved. Check its listening report."
        }
        guard let account = services?.listenbrainz, !account.user.isEmpty else { return "Add your ListenBrainz username to the wall." }
        if account.read_state == "playing", let song = account.read_playing { return "ListenBrainz reports \(song.title) by \(song.artist)." }
        if account.read_state == "checking" { return "ListenBrainz is checking \(account.user)’s listening." }
        if account.read_state == "ready" { return "ListenBrainz is connected. No song is being reported right now." }
        return account.read_problem ?? "The ListenBrainz profile is saved. Check its listening report."
    }
    private var journalPicker: some View {
        Picker("Listening journal", selection: $journal) {
            ForEach(GuideJournal.allCases) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("otherPlayers.journal")
    }
    private func external(_ title: String, _ address: String, id: String) -> some View {
        Link(destination: URL(string: address)!) {
            Label(title, systemImage: "arrow.up.right").font(.ui(14, .semibold)).foregroundStyle(blue).frame(minHeight: 44)
        }.accessibilityIdentifier(id)
    }
    private func alternative(_ title: String, _ subtitle: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(blue).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                Text(subtitle).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0); Chevron()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 17))
    }
    private func refresh(check: Bool = false) async {
        guard !refreshing else { return }
        guard wall.link.isLive else { failed = true; return }
        let host = wall.host
        refreshing = true
        defer { refreshing = false }
        var result: WallServices?
        if check {
            result = journal == .lastfm ? await WallServices.retryLastfm(host: host) : await WallServices.retryListenBrainz(host: host)
        }
        if result == nil { result = await WallServices.read(host: host) }
        guard !Task.isCancelled, host == wall.host, wall.link.isLive else { return }
        checkedHost = host; failed = result == nil
        if let result { services = result }
    }
}

private enum GuideJournal: String, CaseIterable, Identifiable {
    case lastfm = "Last.fm", listenbrainz = "ListenBrainz"
    var id: String { rawValue }
}
private enum GuidePlayer: String, CaseIterable, Identifiable {
    case tidal, deezer, soundcloud, youtubeMusic, amazonMusic
    var id: String { rawValue }
    var service: Service {
        switch self {
        case .tidal: .tidal
        case .deezer: .deezer
        case .soundcloud: .soundcloud
        case .youtubeMusic: .youtubeMusic
        case .amazonMusic: .amazonMusic
        }
    }
    var name: String { service.name }
    var url: String {
        switch self {
        case .tidal: "https://listen.tidal.com/"
        case .deezer: "https://www.deezer.com/"
        case .soundcloud: "https://soundcloud.com/"
        case .youtubeMusic: "https://music.youtube.com/"
        case .amazonMusic: "https://music.amazon.com/"
        }
    }
    var nativeGuide: (detail: String, url: String)? {
        switch self {
        case .tidal:
            ("Tidal also offers a Last.fm connection in its supported desktop, web and iPhone settings. Follow its guide, then add that Last.fm username in Tessera. Availability and menu names depend on the player version.", "https://support.last.fm/t/tidal-scrobbling/181")
        case .deezer:
            ("Deezer’s Last.fm link is managed in Sharing preferences on its website. It may need desktop mode and may be unavailable for some Family or Duo accounts. Web Scrobbler is an alternative for browser playback.", "https://support.last.fm/t/deezer-scrobbling/177")
        default: nil
        }
    }
}
