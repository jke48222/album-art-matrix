// Settings. A place you visit, not a place you live.
//
// Built the way the good hardware apps build theirs. The page opens like
// IKEA Home smart: the word Settings, one line saying whether the wall is
// connected, and a card for the one thing worth doing next. Then a list of
// rows, each with a small line drawing, what it is, and where it stands,
// with a hairline between them. Every row opens a page laid out like the
// Sonos app: a title, a paragraph, and grouped rows with the control on the
// right. A choice is a set of cards with a Save button, as IKEA does it.
// Addresses and the numbers behind a correction live on the last page.

import SwiftUI
import UIKit

struct SettingsSheet: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    let accent: Color

    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @State private var services: WallServices? = nil
    @State private var showCalibrate = false
    @State private var vitals: Vitals? = nil
    @State private var cardDismissed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    if let step = nextStep, !cardDismissed {
                        NextStepCard(step: step, frame: wall.frame, accent: accent,
                                     dismiss: { cardDismissed = true })
                            .padding(.top, 22)
                    }
                    SettingsList {
                        row("music.note", "Services", servicesLine) { ServicesPage(accent: accent, services: $services, musicConnected: $musicConnected, musicRefused: $musicRefused) }
                        row("sun.max", "Light", "\(Int(wall.state.brightness * 100))%") { LightPage(accent: accent) }
                        row("sunset", "Follow the sun", wall.state.sun == "on" ? "On, \(Int(wall.state.sunNight * 100))% after dark" : "Off") { SunPage(accent: accent) }
                        row("moon.zzz", "Sleep", sleepValue) { SleepPage(accent: accent) }
                        row("sunrise", "Wake up", wall.state.wakeEnabled ? wakeValue : "Off") { WakePage(accent: accent) }
                        row("pause.circle", "Nothing playing", idleName) { idlePage }
                        row("lock.iphone", "Lock screen", wall.live.enabled ? "Showing the wall" : "Off") { LockScreenPage(accent: accent) }
                    }
                    .padding(.top, 26)

                    Text("What the wall can do")
                        .font(.displayMid(20))
                        .foregroundStyle(Ink.ink)
                        .padding(.top, 34)

                    SettingsList {
                        row("text.bubble", "Ask the wall", "A question, answered on the panel") { AskPage(accent: accent) }
                        row("note.text", "Notes", "Words on the panel for a while") { NotePage(accent: accent) }
                        row("photo.on.rectangle", "Show me", "A cover or a video, by name") { ShowPage(accent: accent) }
                        row("ear.badge.waveform", "Earworm", "Name a song from the words you remember") { EarwormPage(accent: accent) }
                        row("paintbrush.pointed", "Imagine", "A picture from words") { ImaginePage(accent: accent) }
                        row("cloud.sun", "Weather", wall.state.place.isEmpty ? "No place yet" : wall.state.place) { WeatherPage(accent: accent) }
                        row("dice", "Games", "Nineteen, on the wall and the phone") { GamesPageWrapper(accent: accent) }
                        row("waveform", "Voice", "The wake word, and what it heard") { VoicePage(accent: accent) }
                        row("homekit", "HomeKit", "The wall in the Home app") { HomeKitPage(accent: accent) }
                        row("opticaldisc", "The shelf", "Your records, from Discogs") { ShelfPage(accent: accent) }
                        row("music.mic", "Teach the wall", "Its own song library") { TeachPage(accent: accent) }
                    }
                    .padding(.top, 14)

                    Text("Other settings")
                        .font(.displayMid(20))
                        .foregroundStyle(Ink.ink)
                        .padding(.top, 34)

                    SettingsList {
                        row("camera.aperture", "True colour", corrected ? "Corrected" : "Not corrected yet") { ColourPage(accent: accent, showCalibrate: $showCalibrate) }
                        row("checkerboard.rectangle", "Panel check", "Flat colours for a dead light") { PanelPage(accent: accent) }
                        row("qrcode", "Guests", "Your wifi on the wall, as a code") { GuestsPage(accent: accent) }
                        if wall.link.isLive {
                            row("waveform.path.ecg", "How it's doing", healthValue) { HealthPage(accent: accent, vitals: $vitals) }
                        }
                        row("network", "Addresses", "The wall, and a Mac if you use one") { AddressesPage(accent: accent, onChange: {}) }
                        row("info.circle", "About Tessera", nil) { AboutPage(accent: accent) }
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack {
                    Ink.ground
                    // a little of the wall's light, so the glass has something to frost
                    RadialGradient(colors: [accent.opacity(0.28), accent.opacity(0.06), .clear],
                                   center: .init(x: 0.5, y: 0.12), startRadius: 0, endRadius: 520)
                }
                .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Ink.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().strokeBorder(Ink.ink.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(scale: 0.94))
                    .accessibilityLabel("Close settings")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(accent)
        .presentationBackground(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            musicConnected = Service.appleMusicAuthorized
            musicRefused = Service.appleMusicRefused
        }
        .task { services = await WallServices.seeded(host: wall.host) }
        .task {
            if wall.link.isLive { vitals = await Vitals.read(host: wall.host) }
        }
        .fullScreenCover(isPresented: $showCalibrate) {
            CalibrateScreen(accent: accent).environment(wall)
        }
    }

    // MARK: - Title and status, as IKEA opens it

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
            HStack(spacing: 8) {
                Text(statusWord)
                    .font(.ui(15))
                    .foregroundStyle(Ink.dim)
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.top, 6)
    }

    private var statusWord: String {
        switch wall.link {
        case .live: "Connected"
        case .searching: "Looking for the wall"
        case .offline: "Not connected"
        case .standIn: "Running on this phone"
        }
    }

    private var statusColor: Color {
        switch wall.link {
        case .live: Ink.moss
        case .searching: Ink.tile
        case .offline: Ink.signal
        case .standIn: Ink.faint
        }
    }

    // MARK: - The one thing worth doing next

    private var nextStep: NextStep? {
        if !wall.link.isLive && !wall.link.isStandIn {
            return NextStep(title: "Find your wall",
                            body: "Tessera looks for it on your network. If it is on, one more look usually does it.",
                            button: "Look again", go: .look)
        }
        if !musicConnected && !musicRefused {
            return NextStep(title: "Connect Apple Music",
                            body: "So the wall shows what you play.",
                            button: "Connect", go: .music)
        }
        if let sv = services, sv.spotify.client_id.isEmpty, !sv.spotify.linked {
            return NextStep(title: "Connect Spotify",
                            body: "A couple of minutes, all on this phone. The wall then follows what you play on any device.",
                            button: "Set up", go: .music)
        }
        if let sv = services, !sv.spotify.client_id.isEmpty, !sv.spotify.linked,
           sv.lastfm.user.isEmpty {
            return NextStep(title: "Connect Spotify",
                            body: "Premium: sign in once. Free: link Spotify to Last.fm and give the wall your Last.fm name. Services shows both.",
                            button: "Open", go: .music)
        }
        if wall.link.isLive && !corrected {
            return NextStep(title: "Calibrate the colour",
                            body: "Panels lean green out of the box. Your camera reads the wall and Tessera corrects it.",
                            button: "Calibrate", go: .colour)
        }
        return nil
    }

    // MARK: - Rows

    private func row<Page: View>(_ symbol: String, _ title: String, _ subtitle: String?,
                                 @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink { page() } label: {
            IconRow(symbol: symbol, title: title, subtitle: subtitle)
        }
        .buttonStyle(PressStyle(scale: 0.99))
    }

    private var idlePage: some View {
        ChoicePage(title: "Nothing playing",
                   blurb: "What the wall does between songs, or when the music stops for the night.",
                   accent: accent,
                   options: [
                    ("moon", "Go dark", "Lights off until the next song.", "black"),
                    ("photo", "Hold the last sleeve", "Keeps the cover up at full light.", "hold"),
                    ("sun.min", "Dim it", "Keeps the cover up, turned down.", "dim"),
                    ("wind", "Drift", "Slow colour and no picture.", "ambient"),
                    ("cloud.sun", "The weather", "The forecast, drawn, with the temperature.", "weather"),
                   ],
                   selected: wall.state.idle) { wall.send(["idle": $0]) }
    }

    // MARK: - Words for the rows

    private var servicesLine: String {
        var on: [String] = []
        if musicConnected { on.append("Apple Music") }
        if services?.spotify.linked == true { on.append("Spotify") }
        if let u = services?.lastfm.user, !u.isEmpty { on.append("Last.fm") }
        if let u = services?.listenbrainz?.user, !u.isEmpty { on.append("ListenBrainz") }
        return on.isEmpty ? "Nothing connected yet" : on.joined(separator: " · ")
    }

    private var sleepValue: String {
        if let left = wall.state.sleepRemaining, left > 0 { return "\(max(1, left / 60)) min left" }
        return "Off"
    }

    private var wakeValue: String {
        let bits = wall.state.wakeTime.split(separator: ":")
        guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]),
              let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())
        else { return wall.state.wakeTime }
        return d.formatted(date: .omitted, time: .shortened)
    }

    private var idleName: String {
        switch wall.state.idle {
        case "hold": "Hold the last sleeve"
        case "dim": "Dim it"
        case "ambient": "Drift"
        case "weather": "The weather"
        default: "Go dark"
        }
    }

    private var corrected: Bool {
        wall.state.wbR < 0.995 || wall.state.wbG < 0.995 || wall.state.wbB < 0.995
    }

    private var healthValue: String {
        guard let v = vitals else { return "Asking the wall" }
        if let th = v.throttled, th.now { return "Running hot" }
        if let t = v.tempC { return String(format: "%.0f°C, fine", t) }
        return v.fps > 0 ? "Fine" : "Idle"
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

struct NextStep {
    enum Go { case look, music, colour }
    let title: String
    let body: String
    let button: String
    let go: Go
}

/// The card above the list for the one setup step still open, with the
/// wall itself where an illustration would go.
struct NextStepCard: View {
    @Environment(WallSession.self) private var wall
    let step: NextStep
    let frame: Data?
    let accent: Color
    var dismiss: () -> Void

    @State private var openMusic = false
    @State private var openColour = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                WallThumb(frame: frame, live: wall.link.isLive)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.dim)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Ink.sunk))
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .accessibilityLabel("Dismiss")
            }
            Text(step.title)
                .font(.displayMid(21))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.body)
                .font(.ui(14))
                .foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                switch step.go {
                case .look: wall.lookForWallAgain()
                case .music: openMusic = true
                case .colour: openColour = true
                }
            } label: {
                Text(step.button)
                    .font(.ui(16, .semibold))
                    .foregroundStyle(Ink.ground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(Ink.ink))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .padding(.top, 4)
        }
        .padding(20)
        .background(Glass(radius: 24))
        .navigationDestination(isPresented: $openMusic) {
            ServicesPage(accent: accent, services: .constant(nil),
                         musicConnected: .constant(Service.appleMusicAuthorized),
                         musicRefused: .constant(Service.appleMusicRefused))
        }
        .navigationDestination(isPresented: $openColour) {
            ColourPage(accent: accent, showCalibrate: .constant(false))
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
            SetupGroup("When I leave", note: "After fifteen quiet minutes with your phone off the network, the wall turns off. It comes back when you do.") {
                ToggleRow(title: "Turn off when I leave", subtitle: nil,
                          isOn: Binding(get: { wall.state.away == "off" },
                                        set: { wall.send(["away": $0 ? "off" : "stay"]); Taps.detent(intensity: 0.4) }),
                          accent: accent)
            }
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Ink.sunk)
            if let frame, let img = EmitterTile.render([UInt8](frame), cell: 3) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(width: 88, height: 88)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Ink.hairline)
            .frame(height: 1)
            .padding(.leading, 16)
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
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(on ? accent : .clear, lineWidth: 2)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

struct SunPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var where0 = OneShotSpot()

    var body: some View {
        SetupPage("Follow the sun",
                  blurb: "The wall dims after sunset and comes back at sunrise, over forty minutes. It works out sunset from your location, read once and kept on the wall.") {
            SetupGroup("", note: nil) {
                ToggleRow(title: "Follow the sun", subtitle: nil,
                          isOn: Binding(get: { wall.state.sun == "on" },
                                        set: { wall.send(["sun": $0 ? "on" : "off"]); Taps.detent(intensity: 0.4) }),
                          accent: accent)
            }
            .padding(.top, -12)
            if wall.state.sun == "on" {
                SetupGroup("After dark", note: "How much light stays on after dark.") {
                    ChoiceRow(title: "A glow", subtitle: "One tenth.", value: 0.10,
                              selected: wall.state.sunNight, accent: accent) { wall.send(["sun_night": $0]) }
                    Rule()
                    ChoiceRow(title: "Low", subtitle: "A quarter.", value: 0.25,
                              selected: wall.state.sunNight, accent: accent) { wall.send(["sun_night": $0]) }
                    Rule()
                    ChoiceRow(title: "Half", subtitle: nil, value: 0.50,
                              selected: wall.state.sunNight, accent: accent) { wall.send(["sun_night": $0]) }
                }
                SetupGroup("Where you are", note: nil) {
                    SetupRow(title: abs(wall.state.lat) <= 90 ? "Location set" : "No location yet",
                             subtitle: "Read once, for sunset.") {
                        if abs(wall.state.lat) <= 90 && !where0.busy {
                            Done(text: "Set")
                        } else {
                            ActionPill(title: where0.busy ? "Finding" : "Use this spot") {
                                where0.fetch { lat, lon in wall.send(["lat": lat, "lon": lon]) }
                            }
                            .disabled(where0.busy)
                        }
                    }
                }
            }
        }
    }
}

/// The weather face: where, in what units, and what it says right now.
struct WeatherPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var query = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var report: WallWeather?

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isF: Bool { wall.state.weatherUnits == "f" }

    var body: some View {
        SetupPage("Weather",
                  blurb: "A face that is the weather: the sky the colour of the hour, the sun crossing where the real sun is, the moon with tonight's phase, clouds that drift, rain that falls with the forecast. From Open-Meteo, free, for a place you name once.") {
            if let now = report?.now {
                hero(now)
            }
            SetupGroup("Where", note: wall.state.place.isEmpty ? "Name a town or a city." : "The wall follows this place.") {
                KeyField(placeholder: wall.state.place.isEmpty ? "A town or a city" : wall.state.place, text: $query)
                Rule()
                SaveLine(title: "Use this place", enabled: !typed.isEmpty && !busy, busy: busy,
                         done: (typed.isEmpty && !wall.state.place.isEmpty) ? wall.state.place : nil,
                         accent: accent) { setPlace() }
            }
            .padding(.top, report?.now == nil ? -12 : 0)
            Problem(text: problem ?? report?.problem)

            if let hours = report?.hours, !hours.isEmpty {
                SetupGroup("The next hours", note: nil) {
                    HStack(spacing: 0) {
                        ForEach(Array(hours.prefix(6).enumerated()), id: \.offset) { _, h in
                            VStack(spacing: 6) {
                                Text(hourLabel(h.t)).font(.machine(11)).foregroundStyle(Ink.dim)
                                Image(systemName: symbol(code: h.code, day: h.is_day ?? true))
                                    .font(.system(size: 18)).foregroundStyle(Ink.ink)
                                    .frame(height: 24)
                                Text(h.temp.map { degrees($0) } ?? "").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 14)
                }
            }

            SetupGroup("Degrees", note: nil) {
                ChoiceRow(title: "Fahrenheit", subtitle: nil, value: "f", selected: wall.state.weatherUnits,
                          accent: accent) { wall.send(["weather_units": $0]); Taps.detent(intensity: 0.4) }
                Rule()
                ChoiceRow(title: "Celsius", subtitle: nil, value: "c", selected: wall.state.weatherUnits,
                          accent: accent) { wall.send(["weather_units": $0]); Taps.detent(intensity: 0.4) }
            }

            SetupGroup("On the wall", note: report?.now == nil ? (wall.state.place.isEmpty ? "Name a place above." : "Give the wall a moment to fetch it.") : "As the wall has it, \(report?.age_s ?? 0) s old. It is also a choice under Nothing playing.") {
                SetupRow(title: "Put it on the wall", subtitle: "The weather face, now.") {
                    ActionPill(title: wall.state.mode == "weather" ? "Showing" : "Show", filled: wall.state.mode != "weather") {
                        wall.send(["mode": "weather"]); Taps.commit()
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let r = await WallWeather.read(host: wall.host) { report = r }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The weather as a card: the wall's own frame, the temperature large,
    /// the words for the sky, the day's range, and the small facts.
    private func hero(_ now: WallWeather.Now) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(wall.state.place.isEmpty ? "Here" : wall.state.place).font(.ui(12, .semibold)).foregroundStyle(accent)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(now.temp.map { degrees($0, sign: false) } ?? "--").font(.display(44)).foregroundStyle(Ink.ink)
                        Text("°").font(.display(30)).foregroundStyle(Ink.dim).baselineOffset(14)
                    }
                    Text(sceneWords(report?.scene, day: now.is_day ?? true)).font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                    if let h = now.high, let l = now.low {
                        Text("High \(degrees(h))  ·  Low \(degrees(l))").font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                fact("thermometer.medium", "Feels", now.feels.map { degrees($0) } ?? "--")
                fact("wind", "Wind", now.wind_kmh.map { "\(Int($0.rounded())) km/h" } ?? "--")
                fact("sunrise", "Sunrise", now.sunrise.map { clock($0) } ?? "--")
                fact("sunset", "Sunset", now.sunset.map { clock($0) } ?? "--")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.plaster))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private func fact(_ symbol: String, _ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Ink.dim)
            Text(value).font(.ui(13, .semibold)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.machine(10)).foregroundStyle(Ink.faint)
        }
        .frame(maxWidth: .infinity)
    }

    private func degrees(_ c: Double, sign: Bool = true) -> String {
        let v = isF ? c * 9 / 5 + 32 : c
        return "\(Int(v.rounded()))" + (sign ? "°" : "")
    }

    private func clock(_ unix: Double) -> String {
        let d = Date(timeIntervalSince1970: unix)
        let f = DateFormatter(); f.dateFormat = "h:mm"
        return f.string(from: d)
    }

    private func hourLabel(_ unix: Double?) -> String {
        guard let unix else { return "" }
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: Date(timeIntervalSince1970: unix)).lowercased()
    }

    private func sceneWords(_ scene: String?, day: Bool) -> String {
        switch scene {
        case "clear": return day ? "Clear sky" : "Clear night"
        case "mostly_clear": return "Mostly clear"
        case "partly_cloudy": return "Partly cloudy"
        case "overcast": return "Overcast"
        case "fog": return "Fog"
        case "drizzle": return "Drizzle"
        case "rain": return "Rain"
        case "freezing": return "Freezing rain"
        case "snow": return "Snow"
        case "showers": return "Showers"
        case "thunder": return "Thunderstorms"
        default: return ""
        }
    }

    private func symbol(code: Int?, day: Bool) -> String {
        switch code ?? 0 {
        case 0: return day ? "sun.max" : "moon.stars"
        case 1, 2: return day ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55: return "cloud.drizzle"
        case 56, 57, 66, 67: return "cloud.sleet"
        case 61, 63, 65: return "cloud.rain"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 80, 81, 82: return "cloud.heavyrain"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    private func setPlace() {
        guard !typed.isEmpty, !busy else { return }
        busy = true
        let h = wall.host, q = typed
        Task {
            let (ok, why) = await WallWeather.setPlace(host: h, query: q)
            problem = why
            if ok { query = ""; Taps.commit() }
            busy = false
        }
    }
}

/// What GET /weather says.
struct WallWeather: Decodable {
    struct Now: Decodable {
        var temp: Double?
        var feels: Double?
        var code: Int?
        var is_day: Bool?
        var wind_kmh: Double?
        var high: Double?
        var low: Double?
        var sunrise: Double?
        var sunset: Double?
    }
    struct Hour: Decodable {
        var t: Double?
        var temp: Double?
        var code: Int?
        var is_day: Bool?
    }
    var place: String?
    var units: String?
    var age_s: Int?
    var stale: Bool?
    var scene: String?
    var problem: String?
    var now: Now?
    var hours: [Hour]?

    static func read(host: String) async -> WallWeather? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/weather") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WallWeather.self, from: data)
    }

    static func setPlace(host: String, query: String) async -> (Bool, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/weather/place") else { return (false, "The wall is not answering.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (false, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (true, nil) }
        if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = d["error"] as? String { return (false, e) }
        return (false, "The wall could not find that place.")
    }
}

struct SleepPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var minutes: Double = 30

    var body: some View {
        SetupPage("Sleep",
                  blurb: "Fade the wall down over a set time, then turn it off.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(minutes))")
                        .font(.display(56))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                    Text("minutes").font(.ui(16)).foregroundStyle(Ink.dim)
                }
                Slider(value: $minutes, in: 5...120, step: 5).tint(accent)
                PrimaryButton(title: "Start the fade", accent: accent) {
                    wall.send(["sleep_fade_min": minutes])
                    Taps.commit()
                }
                if let left = wall.state.sleepRemaining, left > 0 {
                    HStack {
                        Text("Fading, \(left / 60) min \(left % 60) s left")
                            .font(.ui(13)).foregroundStyle(Ink.moss)
                        Spacer()
                        Button("Cancel") { wall.send(["sleep_fade_min": 0.0]) }
                            .buttonStyle(PressStyle(scale: 0.97))
                            .font(.ui(13, .medium))
                            .foregroundStyle(Ink.dim)
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

struct WakePage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var at: Date = Date()

    var body: some View {
        SetupPage("Wake up",
                  blurb: "The wall fades up from black at the set time. It only lifts a wall that is off.") {
            SetupGroup("", note: nil) {
                ToggleRow(title: "Fade up in the morning", subtitle: nil,
                          isOn: Binding(get: { wall.state.wakeEnabled },
                                        set: { wall.send(["wake_enabled": $0]); Taps.detent(intensity: 0.4) }),
                          accent: accent)
                if wall.state.wakeEnabled {
                    Rule()
                    HStack {
                        Text("At").font(.ui(16)).foregroundStyle(Ink.ink)
                        Spacer()
                        DatePicker("", selection: $at, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(accent)
                            .onChange(of: at) { _, d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                wall.send(["wake_time": String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 0)])
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                }
            }
            .padding(.top, -12)
            if wall.state.wakeEnabled {
                SetupGroup("Over", note: "How long the fade takes.") {
                    ForEach([10.0, 20.0, 30.0, 45.0], id: \.self) { m in
                        if m != 10 { Rule() }
                        ChoiceRow(title: "\(Int(m)) minutes", subtitle: nil, value: m,
                                  selected: wall.state.wakeFade, accent: accent) { wall.send(["wake_fade_min": $0]) }
                    }
                }
            }
        }
        .onAppear {
            let bits = wall.state.wakeTime.split(separator: ":")
            if bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]) {
                at = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? at
            }
        }
    }
}

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
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255))
                                    .frame(height: 76)
                                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1) }
                                Text(name).font(.ui(14, .medium)).foregroundStyle(Ink.ink)
                            }
                            .padding(12)
                            .background(Ink.plaster)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @ObservationIgnored private var manager: CLLocationManager? = nil
    @ObservationIgnored private var handler: ((Double, Double) -> Void)? = nil

    func fetch(_ done: @escaping (Double, Double) -> Void) {
        handler = done
        busy = true
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer   // a sundial, not a courier
        manager = m
        if m.authorizationStatus == .notDetermined {
            m.requestWhenInUseAuthorization()
        } else {
            m.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.busy else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager?.requestLocation()
            case .denied, .restricted: self.finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let c = locations.first?.coordinate
        Task { @MainActor in self.finish(c.map { ($0.latitude, $0.longitude) }) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func finish(_ spot: (Double, Double)?) {
        busy = false
        if let spot { handler?(spot.0, spot.1); Taps.commit() }
        handler = nil
        manager = nil
    }
}


// MARK: - Imagine: a picture from words, and the ones drawn so far

struct ImaginePage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var prompt = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var said: String?
    @State private var gallery: WallImagined?
    @State private var showing: String?

    private var typed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { gallery?.ready == true }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }

    private var liveLine: String {
        guard let l = gallery?.live else { return "" }
        switch l.stage {
        case "waiting": return "Thinking about it, \(Int(l.elapsed ?? 0)) s."
        case "partial": return "Drawing: \(l.partials ?? 0) of \(l.of ?? 3) passes, \(Int(l.elapsed ?? 0)) s."
        case "done": return "Done" + ((l.done_ago ?? 0) < 600 ? ", on the wall." : ".")
        case "failed": return l.problem ?? "Could not draw."
        default: return ""
        }
    }

    var body: some View {
        SetupPage("Imagine",
                  blurb: "Describe a picture and the wall draws it: a purple elephant, a lighthouse at night, a bowl of ramen. Claude writes the words out for a panel this size, an image model draws it while the wall shows it forming, and it stays up for ten minutes. By voice, \"create\" or \"draw\" does the same.") {
            if let l = gallery?.live, l.stage != "idle", !liveLine.isEmpty {
                HStack(spacing: 12) {
                    PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l.stage == "done" ? "On the wall" : "Drawing").font(.ui(11, .semibold)).foregroundStyle(accent)
                        Text(l.prompt ?? "").font(.ui(14, .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                        Text(liveLine).font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.plaster))
            }
            SetupGroup("The words", note: ready ? "One picture every ten seconds. The wall shows it being drawn." : "Set up a drawer and its key under Services, Images, first.") {
                KeyField(placeholder: "a purple elephant", text: $prompt)
                Rule()
                SaveLine(title: busy ? "Drawing" : "Draw it", enabled: ready && !typed.isEmpty && !busy, busy: busy,
                         done: said, accent: accent) { draw() }
            }
            .padding(.top, -12)
            Problem(text: problem ?? gallery?.problem)

            SetupGroup("Drawn so far", note: (gallery?.images.isEmpty ?? true) ? "Nothing yet." : "Tap one to put it back on the wall.") {
                if let items = gallery?.images, !items.isEmpty {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items, id: \.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                AsyncImage(url: URL(string: "http://\(wall.host)/imagine/\(item.id).png")) { phase in
                                    if let image = phase.image {
                                        image.resizable().interpolation(.medium).aspectRatio(1, contentMode: .fill)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10).fill(Ink.plaster)
                                            .aspectRatio(1, contentMode: .fit)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(showing == item.id ? accent : .clear, lineWidth: 2))
                                Text(item.prompt).font(.ui(11)).foregroundStyle(Ink.dim).lineLimit(2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { show(item.id) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    SetupRow(title: "Nothing yet", subtitle: "The first one lands here.") { EmptyView() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let g = await WallImagined.read(host: wall.host) { gallery = g }
                let drawing = gallery?.live?.stage == "waiting" || gallery?.live?.stage == "partial"
                try? await Task.sleep(for: .seconds(busy || drawing ? 1 : 6))
            }
        }
    }

    private func draw() {
        guard ready, !typed.isEmpty, !busy else { return }
        busy = true
        said = nil
        let h = wall.host, p = typed
        Task {
            let (ok, why, id) = await WallImagined.draw(host: h, prompt: p)
            problem = why
            if ok {
                prompt = ""
                said = "Drawn"
                showing = id
                Taps.commit()
                if let g = await WallImagined.read(host: h) { gallery = g }
            }
            busy = false
        }
    }

    private func show(_ id: String) {
        let h = wall.host
        showing = id
        Task {
            _ = await WallImagined.show(host: h, id: id)
            Taps.detent(intensity: 0.4)
        }
    }
}

/// What GET /imagine says: the drawer's state and every picture kept.
struct WallImagined: Decodable {
    struct Item: Decodable {
        var id: String
        var prompt: String
        var expanded: String?
        var provider: String?
        var ts: Int?
        var usd: Double?
    }
    struct Live: Decodable {
        var stage: String
        var prompt: String?
        var partials: Int?
        var of: Int?
        var elapsed: Double?
        var problem: String?
        var done_ago: Double?
    }
    var ready: Bool?
    var provider: String?
    var images: [Item]
    var problem: String?
    var live: Live?

    static func read(host: String) async -> WallImagined? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/imagine") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WallImagined.self, from: data)
    }

    static func draw(host: String, prompt: String) async -> (Bool, String?, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/imagine") else { return (false, "No wall.", nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": prompt])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (false, "The wall is not answering.", nil) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (true, nil, json["id"] as? String) }
        return (false, json["error"] as? String ?? "The wall could not draw that.", nil)
    }

    static func show(host: String, id: String) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/imagine/show") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
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
