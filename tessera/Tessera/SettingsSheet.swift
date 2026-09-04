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
                        row("info.circle", "About Tessera", nil) { AboutPage() }
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
    @AppStorage("design") private var design = Design.ipod.rawValue
    @AppStorage("onboarding.again") private var onboardingAgain = false
    @AppStorage("intro.replay") private var replay = false

    var body: some View {
        SetupPage("Tessera",
                  blurb: "A remote for a wall of 4,096 lights. The app talks to the wall directly. There is no account and nothing leaves your network.") {
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
                SetupRow(title: "Play the opening", subtitle: "The iPod or room opening, again.") {
                    ActionPill(title: "Play") { replay = true }
                }
            }
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
