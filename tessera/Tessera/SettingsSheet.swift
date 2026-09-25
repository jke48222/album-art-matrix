import SwiftUI
import UIKit

struct SettingsSheet: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    var initialDestination: SettingsDestination? = nil
    @State private var path: [SettingsDestination] = []
    @State private var query = ""
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @State private var services: WallServices?
    @State private var showCalibrate = false
    @State private var vitals: Vitals?
    @FocusState private var searching: Bool
    @State private var openedInitialRoute = false

    private var warm: Color { Color(hex: 0xE5BE83) }
    private var results: [SettingsDestination] { SettingsDestination.results(for: query) }
    private var filtering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    masthead
                    searchField
                    if !filtering {
                        wallIdentity
                        ForEach(SettingsSection.allCases) { section in
                            sectionBlock(section)
                        }
                        HStack(spacing: 9) {
                            Image(systemName: "square.grid.3x3.fill").font(.system(size: 12))
                            Text("A small wall. A world of possibilities.").font(.ui(12))
                        }
                        .foregroundStyle(Ink.dim).padding(.top, 4)
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 40)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if wall.link.isLive && wall.state.timerRinging && !path.contains(.time) {
                    TimeCompletionEntry(accent: warm) { searching = false; path.append(.time) }
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Color(hex: 0x101212))
                }
            }
            #if DEBUG
            .defaultScrollAnchor(CommandLine.arguments.contains("-settings-bottom") ? .bottom : .top)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(Color(hex: 0x101212).ignoresSafeArea())
            .navigationDestination(for: SettingsDestination.self) { destination in
                destinationPage(destination)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.ink).frame(width: 44, height: 44)
                    }
                    .buttonStyle(PressStyle(scale: 0.94)).accessibilityLabel("Close settings")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(warm)
        .presentationBackground(Color(hex: 0x101212))
        .preferredColorScheme(.dark)
        .onAppear {
            musicConnected = Service.appleMusicAuthorized
            musicRefused = Service.appleMusicRefused
            guard !openedInitialRoute else { return }
            openedInitialRoute = true
            if let initialDestination { path = [initialDestination] }
            #if DEBUG
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "-settings-query"), args.indices.contains(i + 1) { query = args[i + 1] }
            if let i = args.firstIndex(of: "-settings-page") ?? args.firstIndex(of: "-routine-page"), args.indices.contains(i + 1),
               let route = SettingsDestination(rawValue: args[i + 1]) { path = [route] }
            #endif
        }
        .task(id: "\(wall.host)|\(wall.link.isLive)") {
            guard wall.link.isLive else { services = nil; vitals = nil; return }
            let host = wall.host
            async let readServices = WallServices.seeded(host: host)
            async let readVitals = Vitals.read(host: host)
            let (freshServices, freshVitals) = await (readServices, readVitals)
            guard !Task.isCancelled, wall.host == host, wall.link.isLive else { return }
            services = freshServices; vitals = freshVitals
        }
        .fullScreenCover(isPresented: $showCalibrate) {
            CalibrateScreen(accent: accent).environment(wall)
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !typeSize.isAccessibilitySize {
                Text("TESSERA / YOUR WALL, YOUR WAY")
                    .font(.machine(9)).tracking(1.2).foregroundStyle(warm)
            }
            Text("Settings").font(typeSize.isAccessibilitySize ? .ui(23, .semibold) : .display(46))
                .foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Ink.dim)
            TextField(text: $query, prompt: Text("Find a setting or feature").foregroundStyle(Ink.dim)) { Text("Search settings") }
                .font(.ui(16)).foregroundStyle(Ink.ink).focused($searching)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search).onSubmit { searching = false }
                .accessibilityLabel("Search settings and features").accessibilityIdentifier("settings.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Ink.dim)
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 17).padding(.trailing, query.isEmpty ? 17 : 4)
        .frame(minHeight: 54)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(searching ? warm.opacity(0.65) : .white.opacity(0.09), lineWidth: 1))
    }

    private var wallIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: SettingsDestination.addresses) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { identityWords; Spacer(minLength: 4); if !typeSize.isAccessibilitySize { identityImage } }
                    VStack(alignment: .leading, spacing: 18) { identityWords }
                }
                .padding(20).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.99))
            .accessibilityHint("Opens the wall’s connection settings")
            if let suggestion {
                Rectangle().fill(warm.opacity(0.15)).frame(height: 1).padding(.horizontal, 20)
                Button {
                    if !wall.link.isLive && !wall.link.isStandIn { wall.lookForWallAgain() }
                    else { path.append(suggestion.route) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.symbol).font(.system(size: 14))
                        Text(suggestion.title).font(.ui(13, .medium)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(warm).padding(.horizontal, 20).padding(.vertical, 16).frame(minHeight: 48)
                    .contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.99))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 25).fill(
                LinearGradient(colors: [Color(hex: 0x2D302C), Color(hex: 0x1A201E)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(warm.opacity(0.18), lineWidth: 1))
        .accessibilityIdentifier("settings.wall")
    }

    private var identityWords: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusWord.uppercased()).font(.machine(8)).tracking(0.5).foregroundStyle(Ink.ink)
            }
            Text("Your wall").font(typeSize.isAccessibilitySize ? .ui(19, .semibold) : .displayMid(26)).foregroundStyle(Ink.ink)
            Text(wall.link.isLive ? "\(Panel.side) × \(Panel.side) · \(wall.state.mode == "off" ? "Lights out" : "\(Int(wall.state.brightness * 100))% light")" : "\(wall.link.isStandIn ? "On this phone" : "Last frame, saved here")")
                .font(.ui(12)).foregroundStyle(Color(hex: 0xB8BBAF))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identityImage: some View {
        WallThumb(frame: wall.frame, live: wall.link.isLive)
            .padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .rotationEffect(.degrees(-3))
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
            .accessibilityHidden(true)
    }

    private func sectionBlock(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title).font(typeSize.isAccessibilitySize ? .ui(19, .semibold) : .displayMid(25)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Text(section.caption).font(.machine(8)).tracking(0.7).foregroundStyle(Ink.dim) }
            }
            .padding(.top, 5)
            routeList(section.entries)
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                .font(.ui(14)).foregroundStyle(Ink.dim).accessibilityAddTraits(.updatesFrequently)
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(warm)
                    Text("Nothing here yet.").font(.displayMid(25)).foregroundStyle(Ink.ink)
                    Text("Try a feature, like “timer”, or something you want to change, like “brightness”.")
                        .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    Button("Browse all settings") { query = ""; searching = false }
                        .font(.ui(15, .semibold)).foregroundStyle(warm).frame(minHeight: 44)
                }.padding(.vertical, 20)
            } else { routeList(results) }
        }.accessibilityIdentifier("settings.results")
    }

    private func routeList(_ entries: [SettingsDestination]) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { item in
                NavigationLink(value: item) {
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: item.symbol).font(.system(size: 19, weight: .regular))
                            .foregroundStyle(tint(item.section)).frame(width: 38, height: 40)
                            .background(tint(item.section).opacity(0.085), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                            Text(detail(item)).font(.ui(12)).foregroundStyle(Ink.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.dim)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 14).frame(minHeight: 74)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.99)).accessibilityIdentifier("settings.route.\(item.rawValue)")
                if item != entries.last {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 66)
                }
            }
        }
        .background(Color(hex: 0x191C1C), in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.055), lineWidth: 1))
    }

    private func tint(_ section: SettingsSection) -> Color {
        switch section {
        case .rhythm: warm
        case .music: Color(hex: 0xB6AEDC)
        case .explore: Color(hex: 0x9DCAC1)
        case .home: Color(hex: 0xB4C493)
        case .care: Color(hex: 0xACBDD0)
        }
    }

    @ViewBuilder private func destinationPage(_ route: SettingsDestination) -> some View {
        switch route {
        case .light: LightPage(accent: accent)
        case .time:
            ScrollView { TimeWorkbench(accent: accent).padding(22).padding(.bottom, 30) }
                .background(Ink.ground).navigationTitle("Time & alarms").navigationBarTitleDisplayMode(.inline)
        case .sun: SunPage(accent: accent)
        case .sleep: SleepPage(accent: accent)
        case .wake: WakePage(accent: accent)
        case .idle: IdlePage(accent: accent)
        case .services: ServicesPage(accent: accent, services: $services, musicConnected: $musicConnected, musicRefused: $musicRefused)
        case .voice: VoicePage(accent: accent)
        case .hearing: HearingPage(accent: accent, services: $services)
        case .shelf: ShelfPage(accent: accent)
        case .teach: TeachPage(accent: accent)
        case .ask: AskPage(accent: accent)
        case .note: NotePage(accent: accent)
        case .show: ShowPage(accent: accent)
        case .earworm: EarwormPage(accent: accent)
        case .imagine: ImaginePage(accent: accent)
        case .weather: WeatherPage(accent: accent)
        case .games: GamesPageWrapper(accent: accent)
        case .lockScreen: LockScreenPage(accent: accent)
        case .homeKit: HomeKitPage(accent: accent)
        case .guests: GuestsPage(accent: accent)
        case .colour: ColourPage(accent: accent, showCalibrate: $showCalibrate)
        case .panel: PanelPage(accent: accent)
        case .health: HealthPage(accent: accent, vitals: $vitals)
        case .addresses: AddressesPage(accent: accent, onChange: {})
        case .about: AboutPage(accent: accent)
        }
    }

    private var statusWord: String {
        switch wall.link {
        case .live: wall.state.mode == "off" ? "Connected · off" : "Connected"
        case .searching: "Finding the wall"
        case .offline: "Offline"
        case .standIn: "Phone preview"
        }
    }
    private var statusColor: Color {
        switch wall.link { case .live: Ink.moss; case .searching: warm; case .offline: Ink.signal; case .standIn: Ink.dim }
    }
    private var corrected: Bool { wall.state.wbR < 0.995 || wall.state.wbG < 0.995 || wall.state.wbB < 0.995 }
    private var suggestion: (title: String, symbol: String, route: SettingsDestination)? {
        if !wall.link.isLive && !wall.link.isStandIn { return ("Look for your wall again", "arrow.clockwise", .addresses) }
        if !musicConnected && !musicRefused { return ("Connect Apple Music", "music.note", .services) }
        if let services, !services.spotify.linked, services.lastfm.user.isEmpty { return ("Connect your music services", "music.note", .services) }
        if wall.link.isLive && !corrected { return ("Find your panel’s true colour", "camera.aperture", .colour) }
        return nil
    }
    private func detail(_ item: SettingsDestination) -> String {
        guard wall.link.isLive || wall.link.isStandIn else { return item.detail }
        switch item {
        case .light: return "\(Int(wall.state.brightness * 100))% brightness"
        case .time:
            if wall.state.timerRinging { return wall.state.timerKind == "alarm" ? "Your alarm is ringing" : "Timer complete" }
            if let left = wall.state.timerSeconds() { return "Timer · \(TimeInput.clock(left)) remaining" }
            return item.detail
        case .sun: return wall.state.sun == "on" ? "On · \(Int(wall.state.sunNight * 100))% after dark" : item.detail
        case .sleep:
            if let left = wall.state.sleepSeconds(), left > 0 { return "Fading · \(max(1, (left + 59) / 60)) min remaining" }
            return item.detail
        case .wake: return wall.state.wakeEnabled ? "Every day · \(TimeInput.timeLabel(wall.state.wakeTime, twentyFour: wall.state.clock24h))" : item.detail
        case .idle:
            let names = ["black": "Go dark", "hold": "Hold the sleeve", "dim": "Dim the sleeve", "ambient": "Drift", "weather": "Show the weather"]
            return "\(names[wall.state.idle] ?? "Go dark") · \(wall.state.away == "off" ? "Off when away" : "Stay on when away")"
        case .services:
            var connected: [String] = []
            if musicConnected { connected.append("Apple Music") }
            if services?.spotify.linked == true { connected.append("Spotify") }
            if let user = services?.lastfm.user, !user.isEmpty { connected.append("Last.fm") }
            if let user = services?.listenbrainz?.user, !user.isEmpty { connected.append("ListenBrainz") }
            return connected.isEmpty ? item.detail : connected.joined(separator: " · ")
        case .weather: return wall.state.place.isEmpty ? item.detail : wall.state.place
        case .lockScreen: return wall.live.enabled ? "Live Activity is on" : item.detail
        case .colour: return corrected ? "Your panel is calibrated" : item.detail
        case .health:
            if let vitals, vitals.throttled?.now == true { return "Thermal throttling · open details" }
            if let temperature = vitals?.tempC { return String(format: "%.0f°C · diagnostics", temperature) }
            return item.detail
        default: return item.detail
        }
    }
}

// MARK: - The list, the row, the card

/// Rows with a hairline between each, edge to edge, the way IKEA draws them.
struct SettingsList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .background(Glass(radius: 26))
    }
}

/// Frosted glass with a hairline, the surface everything in Setup sits on.
struct Glass: View {
    var radius: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.ink.opacity(0.10), lineWidth: 1))
    }
}

/// A line drawing, what it is, where it stands, and a chevron.
struct IconRow: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(Ink.ink.opacity(0.12), lineWidth: 1)
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Ink.ink)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Chevron()
            }
            .padding(.vertical, 14)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 56)
        }
    }
}

// MARK: - Services: see Services.swift (the hub and one page per service)

struct LightPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var brightness: Double = 1

    var body: some View {
        SetupPage("Light", blurb: "The same control as the wheel, for when a slider is easier.") {
            SetupGroup("Brightness", note: nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Brightness").font(.ui(16)).foregroundStyle(Ink.ink)
                        Spacer()
                        Text("\(Int(brightness * 100))%")
                            .font(.machine(13)).foregroundStyle(Ink.dim)
                            .contentTransition(.numericText())
                    }
                    Slider(value: $brightness, in: 0.05...1.0, step: 0.05) { editing in
                        if !editing { wall.send(["brightness": brightness]) }
                    }
                    .tint(accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .padding(.top, -12)

        }
        .onAppear { brightness = wall.state.brightness }
    }
}

struct LockScreenPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color

    var body: some View {
        SetupPage("Lock screen", blurb: "A small copy of the wall on the lock screen and in the Dynamic Island. It ends when the wall goes dark.") {
            SetupGroup("", note: nil) {
                ToggleRow(title: "Show the wall on my lock screen", subtitle: nil,
                          isOn: Binding(get: { wall.live.enabled },
                                        set: { wall.live.enabled = $0; Taps.detent(intensity: 0.5) }),
                          accent: accent)
            }
            .padding(.top, -12)
        }
    }
}

// MARK: - The wall, small

/// The wall as it is right now, at thumbnail size, with the unlit emitters
/// still there. Nothing in Setup is more reassuring than this.
struct WallThumb: View {
    let frame: Data?
    let live: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Round.control, style: .continuous)
                .fill(Ink.sunk)
            if let frame, let img = EmitterTile.render([UInt8](frame), cell: 3) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)
                    .clipShape(RoundedRectangle(cornerRadius: Round.control, style: .continuous))
            }
        }
        .frame(width: 88, height: 88)
        .overlay {
            RoundedRectangle(cornerRadius: Round.control, style: .continuous)
                .strokeBorder(Ink.hairline, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(live ? Ink.moss : Ink.faint)
                .frame(width: 8, height: 8)
                .padding(7)
        }
        .accessibilityLabel(live ? "Your wall, live" : "Your wall, not reachable")
    }
}

// MARK: - The bones of a Setup page

/// A heading in the wall's own voice, then one block of rows. The note, when
/// there is one, sits under the block in the quiet type: it is there for the
/// first visit and invisible on the tenth.
struct SetupGroup<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.displayMid(19))
                .foregroundStyle(Ink.ink)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(Glass(radius: 22))
                .clipShape(RoundedRectangle(cornerRadius: Round.hero, style: .continuous))
            if let note {
                Text(note)
                    .font(.ui(12))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row: what it is, one line on what it does, and one thing at the end.
struct SetupRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(title: String, subtitle: String?,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.ui(16))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.ui(12))
                        .foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension SetupRow where Leading == EmptyView {
    init(title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    let isOn: Binding<Bool>
    let accent: Color

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(16)).foregroundStyle(Ink.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.ui(12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 56)
    }
}

/// The line between rows, inset so it reads as a rule and not a box edge.
/// A hairline between rows.
///
/// The inset is a list convention: the rule starts where the row's words
/// start, so the eye reads a column rather than a ladder. It is only right
/// when the rows above and below are themselves inset by that much. On a
/// screen whose content runs to the group's edge it is just a rule that
/// starts in the wrong place and ends flush, which is how it looked on the
/// brightness step: content at 24pt, rule at 40. Those pass `inset: 0`.
struct Rule: View {
    var inset: CGFloat = Space.gap
    var body: some View {
        Rectangle()
            .fill(Ink.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.faint)
    }
}

/// A value at the end of a row that leads somewhere.
struct Value: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.ui(14)).foregroundStyle(Ink.dim).lineLimit(1)
            Chevron()
        }
    }
}

/// Something finished, said in the confirmed colour.
struct Done: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text(text).font(.ui(13, .medium))
        }
        .foregroundStyle(Ink.moss)
    }
}

/// The one big button a page can have. Filled with the live accent, like the
/// chosen pill everywhere else in the app, so "this is the thing" reads the
/// same on every page.
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(16, .semibold))
                .foregroundStyle(enabled ? Ink.ground : Ink.faint)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background { Capsule().fill(enabled ? accent : Ink.plaster) }
                .overlay { Capsule().strokeBorder(enabled ? .clear : Ink.hairline, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .disabled(!enabled)
    }
}

/// A page one level down: the title big, one paragraph, then the controls.
struct SetupPage<Content: View>: View {
    let title: String
    let blurb: String?
    @ViewBuilder let content: Content

    init(_ title: String, blurb: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.blurb = blurb
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.display(28))
                        .foregroundStyle(Ink.ink)
                    if let blurb {
                        Text(blurb)
                            .font(.ui(15))
                            .foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                Ink.ground
                RadialGradient(colors: [Ink.tile.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.1), startRadius: 0, endRadius: 460)
            }
            .ignoresSafeArea()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One of a few, with a ring that fills. Choosing should be reading a short
/// sentence, not decoding a label.
struct ChoiceRow<T: Hashable>: View {
    let title: String
    let subtitle: String?
    let value: T
    let selected: T
    let accent: Color
    var onPick: (T) -> Void

    var body: some View {
        let on = value == selected
        Button {
            guard !on else { return }
            onPick(value)
            Taps.detent(intensity: 0.4)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(on ? accent : Ink.hairline, lineWidth: on ? 6 : 1.5)
                        .frame(width: 20, height: 20)
                }
                .animation(Motion.settle, value: on)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(16)).foregroundStyle(Ink.ink)
                    if let subtitle {
                        Text(subtitle).font(.ui(12)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A choice made the way IKEA makes one: every option is a card that says
/// what it does, the chosen one wears the accent edge, and nothing changes
/// until Save. Choosing and committing are two acts, and the second is the
/// one the wall sees.
struct ChoicePage<T: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let blurb: String?
    let accent: Color
    let options: [(String, String, String, T)]      // symbol, title, description, value
    let selected: T
    var onSave: (T) -> Void

    @State private var picked: T?

    var body: some View {
        SetupPage(title, blurb: blurb) {
            VStack(spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    let on = (picked ?? selected) == o.3
                    Button {
                        picked = o.3
                        Taps.detent(intensity: 0.4)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle().fill(on ? accent.opacity(0.9) : Color.white.opacity(0.08))
                                Image(systemName: o.0)
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundStyle(on ? Ink.ground : Ink.ink)
                            }
                            .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(o.1).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                                Text(o.2).font(.ui(13)).foregroundStyle(Ink.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Glass(radius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: Round.sheet, style: .continuous)
                                .strokeBorder(on ? accent : .clear, lineWidth: 2)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
                    }
                    .buttonStyle(PressStyle(scale: 0.99))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
                PrimaryButton(title: "Save", enabled: picked != nil && picked != selected, accent: accent) {
                    if let p = picked { onSave(p) }
                    Taps.commit()
                    dismiss()
                }
                .padding(.top, 8)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - The pages

struct ColourPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @Binding var showCalibrate: Bool

    private var corrected: Bool {
        wall.state.wbR < 0.995 || wall.state.wbG < 0.995 || wall.state.wbB < 0.995
    }

    var body: some View {
        SetupPage("True colour",
                  blurb: "LED panels lean green. Point your camera at the wall and Tessera measures the cast and corrects it. Run it again if a tint is left.") {
            VStack(alignment: .leading, spacing: 16) {
                PrimaryButton(title: corrected ? "Calibrate again" : "Calibrate with the camera",
                              accent: accent) { showCalibrate = true }
                HStack(spacing: 8) {
                    if corrected {
                        Done(text: "Corrected")
                    } else {
                        Text("Not corrected yet").font(.ui(13)).foregroundStyle(Ink.dim)
                    }
                    Spacer()
                }
            }
            .padding(.top, 6)
        }
    }
}

struct PanelPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color

    private let patterns: [(String, (UInt8, UInt8, UInt8))] = [
        ("White", (255, 255, 255)), ("Red", (255, 0, 0)),
        ("Green", (0, 255, 0)), ("Blue", (0, 0, 255)),
    ]

    var body: some View {
        SetupPage("Panel check",
                  blurb: "Fills the wall with one colour, so a dead light or a colour cast shows. It stays until you pick a mode.") {
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(patterns, id: \.0) { (name, rgb) in
                        Button {
                            wall.pushFlat(r: rgb.0, g: rgb.1, b: rgb.2)
                            Taps.commit()
                        } label: {
                            VStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: Round.card, style: .continuous)
                                    .fill(Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255))
                                    .frame(height: 76)
                                    .overlay { RoundedRectangle(cornerRadius: Round.card, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1) }
                                Text(name).font(.ui(14, .medium)).foregroundStyle(Ink.ink)
                            }
                            .padding(12)
                            .background(Ink.plaster)
                            .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .accessibilityLabel("Show full \(name) on the wall")
                    }
                }
                PrimaryButton(title: "Back to the album", accent: accent) {
                    wall.send(["mode": "art"])
                }
            }
            .padding(.top, 6)
        }
    }
}

struct GuestsPage: View {
    let accent: Color
    var body: some View {
        SetupPage("Guests", blurb: nil) {
            GuestsSection(accent: accent)
        }
    }
}

struct HealthPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @Binding var vitals: Vitals?

    var body: some View {
        SetupPage("How it's doing",
                  blurb: "The computer sits behind the panels. This is how it is doing.") {
            SetupGroup("", note: nil) {
                if let v = vitals {
                    row("Drawing", v.fps > 0 ? String(format: "%.0f frames a second", v.fps) : "Idle")
                    if let t = v.tempC {
                        Rule()
                        row("Temperature", String(format: "%.0f°C", t), warn: t >= 70)
                    }
                    if let th = v.throttled {
                        Rule()
                        row("Heat", th.now ? "Slowing itself down now"
                            : th.ever ? "Ran hot once since it came on" : "Never ran hot", warn: th.now)
                    }
                    Rule()
                    row("Awake for", v.uptime)
                } else {
                    SetupRow(title: "Asking the wall", subtitle: nil) { EmptyView() }
                }
            }
            .padding(.top, -12)
            Button("Check again") {
                Task { vitals = await Vitals.read(host: wall.host) }
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .font(.ui(14, .medium))
            .foregroundStyle(accent)
        }
    }

    private func row(_ name: String, _ value: String, warn: Bool = false) -> some View {
        SetupRow(title: name, subtitle: nil) {
            Text(value).font(.ui(14)).foregroundStyle(warn ? Ink.signal : Ink.dim)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct AddressesPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    var onChange: () -> Void

    @State private var host = ""
    @State private var reporter = ""

    var body: some View {
        SetupPage("Addresses",
                  blurb: "Tessera finds the wall by name on your network. Change this only if the name changed. A Mac is optional: it can pass along what the Mac itself is playing.") {
            SetupGroup("The wall", note: "Answers on port 8788.") {
                field("album-matrix.local:8788", text: $host, commit: commitHost)
                Rule()
                HStack(spacing: 16) {
                    Button("Use this address") { commitHost() }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .font(.ui(13, .semibold))
                        .foregroundStyle(accent)
                    Button("Look again") { wall.lookForWallAgain() }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .font(.ui(13, .medium))
                        .foregroundStyle(Ink.dim)
                    Spacer()
                    LinkChip(link: wall.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .padding(.top, -12)
            SetupGroup("A Mac, if you use one", note: "Optional. A Mac running the reporter can pass along what the Mac is playing.") {
                field("your-mac.local:8787", text: $reporter, commit: commitReporter)
                Rule()
                HStack {
                    Button("Use this address") { commitReporter() }
                        .buttonStyle(PressStyle(scale: 0.97))
                        .font(.ui(13, .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    if let sent = wall.push.lastSent {
                        Text("sent \(sent.formatted(date: .omitted, time: .shortened))")
                            .font(.ui(12)).foregroundStyle(Ink.moss)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            host = wall.host
            reporter = wall.push.host
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text)
            .font(.machine(13))
            .foregroundStyle(Ink.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .onSubmit { commit() }
    }

    private func commitHost() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        wall.host = trimmed
        Taps.commit()
        Task { await wall.pollState() }
    }

    private func commitReporter() {
        wall.push.host = reporter.trimmingCharacters(in: .whitespaces)
        Taps.commit()
        wall.push.restart()
        onChange()
    }
}

struct AboutPage: View {
    /// The room's own colour, so the tuning page's controls are lit the same
    /// as everything else. Defaulted, because About is opened without it.
    var accent: Color = Ink.moss
    @AppStorage("design") private var design = Design.room.rawValue
    @AppStorage("onboarding.again") private var onboardingAgain = false
    @AppStorage("intro.replay") private var replay = false
    /// Found once, open from then on. See the tap target at the foot of
    /// this page.
    @AppStorage("tuning.unlocked") private var tuningUnlocked = false
    @AppStorage("intro.style") private var introStyle = "sting"

    var body: some View {
        SetupPage("Tessera",
                  blurb: "A remote for a wall of \(Panel.lights) lights. The app talks to the wall directly. There is no account and nothing leaves your network.") {
            SetupGroup("Design", note: "Three ways of showing the same room. Pick one.") {
                ForEach(Array(Design.allCases.enumerated()), id: \.offset) { i, d in
                    if i > 0 { Rule() }
                    ChoiceRow(title: d.name,
                              subtitle: d == .classic ? "The panel, full width, drag to dim."
                                      : d == .ipod ? "Everything in an iPod, with a click wheel."
                                      : "The room in 3D, lit by the wall.",
                              value: d.rawValue, selected: design, accent: Ink.tile) { design = $0 }
                }
            }
            .padding(.top, -12)
            SetupGroup("Developer", note: "For trying the first run and the openings again.") {
                SetupRow(title: "Show the first run", subtitle: "The setup steps, from the top.") {
                    ActionPill(title: "Show") { onboardingAgain = true }
                }
                Rule()
                SetupRow(title: "Play the opening", subtitle: "The opening, again.") {
                    ActionPill(title: "Play") { replay = true }
                }
                Rule()
                SetupRow(title: "Opening", subtitle: introStyle == "mark" ? "The mark builds on the wall and becomes the panel."
                         : introStyle == "sting" ? "The Record sting, on black."
                         : introStyle == "sting-room" ? "The Record sting in the room's light; then the app glitches in."
                         : "The iPod or room film: the cover, the badge, the pull back.") {
                    HStack(spacing: 6) {
                        ActionPill(title: "Sting", filled: introStyle == "sting") { introStyle = "sting" }
                        ActionPill(title: "In room", filled: introStyle == "sting-room") { introStyle = "sting-room" }
                        ActionPill(title: "Film", filled: !["mark", "sting", "sting-room"].contains(introStyle)) { introStyle = "film" }
                        ActionPill(title: "Mark", filled: introStyle == "mark") { introStyle = "mark" }
                    }
                }
                if tuningUnlocked {
                    Rule()
                    NavigationLink {
                        PanelTuningPage(accent: accent)
                    } label: {
                        SetupRow(title: "Panel tuning",
                                 subtitle: "Every number that decides what the LEDs do.") {
                            Value("Open")
                        }
                    }
                    .buttonStyle(PressStyle(scale: 0.99))
                }
            }

            // The way in to the tuning. Not a setting: these are the panel's
            // own physics, and a wrong one makes the wall worse in ways that
            // are hard to undo by eye. Five taps here opens it, and it stays
            // open once it has been found.
            Color.clear
                .frame(height: 56)
                .contentShape(Rectangle())
                .onTapGesture(count: 5) {
                    tuningUnlocked = true
                    Taps.found()
                }
                .accessibilityHidden(true)
        }
    }
}

/// A settings block: label, controls, and one honest sentence about what the
/// thing does. Not a card, not a grouped list row.
struct Section<Content: View>: View {
    let label: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ label: String, note: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.machine(10))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(Ink.faint)
            content
            if let note {
                Text(note)
                    .font(.ui(12))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - Vitals

/// One reading of /health. Absent numbers stay absent: a Mac-hosted brain has
/// no thermometer and the row simply does not appear.
struct Vitals {
    let fps: Double
    let tempC: Double?
    let throttled: (now: Bool, ever: Bool)?
    let uptime: String

    static func read(host: String) async -> Vitals? {
        guard let url = URL(string: "http://\(host)/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var th: (Bool, Bool)? = nil
        if let t = json["throttled"] as? [String: Any] {
            th = (t["now"] as? Bool ?? false, t["ever"] as? Bool ?? false)
        }
        let up = json["uptime_s"] as? Double ?? 0
        let text: String = up >= 86400
            ? String(format: "%.0fd %.0fh", up / 86400, up.truncatingRemainder(dividingBy: 86400) / 3600)
            : up >= 3600 ? String(format: "%.0fh %.0fm", up / 3600, up.truncatingRemainder(dividingBy: 3600) / 60)
            : String(format: "%.0f min", up / 60)
        return Vitals(fps: json["fps"] as? Double ?? 0,
                      tempC: json["temp_c"] as? Double,
                      throttled: th,
                      uptime: text)
    }
}


// MARK: - One location, once

/// Asks for the phone's position exactly once, hands back two numbers, and
/// holds nothing. The wall needs a latitude the way a sundial does; it does
/// not need to know where you had lunch.
import CoreLocation

@MainActor
@Observable
final class OneShotSpot: NSObject, CLLocationManagerDelegate {
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var permissionDenied = false
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var handler: ((Double, Double) -> Void)?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var requested = false

    func fetch(_ done: @escaping (Double, Double) -> Void) {
        guard !busy else { return }
        problem = nil; permissionDenied = false; requested = false
        handler = done; busy = true
        let location = CLLocationManager()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = location
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: requestLocation()
        case .denied, .restricted:
            permissionDenied = true
            finish(nil, error: "Location access is off. Allow Tessera to use your location in Settings, then try again.")
        @unknown default: finish(nil, error: "Location is unavailable on this phone.")
        }
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil
        manager = nil; handler = nil; busy = false; requested = false
    }

    private func requestLocation() {
        guard busy, !requested else { return }
        requested = true
        manager?.requestLocation()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.finish(nil, error: "Your location took too long to arrive. Move near a window and try again.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.busy, self.manager === manager else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.requestLocation()
            case .denied, .restricted:
                self.permissionDenied = true
                self.finish(nil, error: "Location access is off. Allow Tessera to use your location in Settings, then try again.")
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let spot = locations.last { location in
            location.horizontalAccuracy >= 0 && abs(location.timestamp.timeIntervalSinceNow) < 120
                && CLLocationCoordinate2DIsValid(location.coordinate)
        }?.coordinate
        Task { @MainActor in
            guard self.busy, self.manager === manager else { return }
            self.finish(spot.map { ($0.latitude, $0.longitude) }, error: spot == nil ? "The phone couldn’t find a recent location. Try again." : nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            guard self.busy, self.manager === manager else { return }
            self.finish(nil, error: "The phone couldn’t find your location. Check Location Services and try again.")
        }
    }

    private func finish(_ spot: (Double, Double)?, error: String? = nil) {
        let callback = handler
        cancel()
        problem = error
        if let spot { callback?(spot.0, spot.1) }
    }
}


/// The Games sheet, reached from Settings as a page rather than from the
/// faces as a sheet: the same list, the same screens.
struct GamesPageWrapper: View {
    let accent: Color
    var body: some View {
        GamesSheetBody(accent: accent)
    }
}
