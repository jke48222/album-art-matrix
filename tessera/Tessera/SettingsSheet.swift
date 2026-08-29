// Settings. A place you visit, not a place you live: the wall's address,
// the sleep fade, the panel check, and the accessible copy of the brightness
// control that lives on the panel everywhere else.

import SwiftUI

struct SettingsSheet: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    let accent: Color

    @State private var host: String = ""
    @State private var sleepMinutes: Double = 30
    @State private var brightness: Double = 1
    @State private var reporter: String = ""
    @State private var wakeAt: Date = Calendar.current.date(
        bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var showCalibrate = false
    @State private var vitals: Vitals? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(spacing: 10) {
                        TesseraMark(accent: accent, lit: 0.8, side: 16)
                        Text("SETUP")
                            .font(.display(17))
                            .kerning(2.8)
                            .foregroundStyle(Ink.ink)
                    }
                    .padding(.bottom, -8)

                    theWall
                    telling
                    if wall.link.isStandIn { music }
                    whenItStops
                    whenImGone
                    waking
                    lockScreen
                    sleep
                    light
                    trueColour
                    panelCheck
                    if wall.link.isLive { health }
                    about
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.ui(15, .medium))
                        .foregroundStyle(accent)
                }
            }
        }
        .presentationBackground(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            host = wall.host
            reporter = wall.push.host
            brightness = wall.state.brightness
            let bits = wall.state.wakeTime.split(separator: ":")
            if bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]) {
                wakeAt = Calendar.current.date(
                    bySettingHour: h, minute: m, second: 0, of: Date()) ?? wakeAt
            }
        }
        .fullScreenCover(isPresented: $showCalibrate) {
            CalibrateScreen(accent: accent).environment(wall)
        }
        .task {
            if wall.link.isLive { vitals = await Vitals.read(host: wall.host) }
        }
    }

    // MARK: - Sections

    private var theWall: some View {
        Section("the wall", note: wall.link.isStandIn
                ? "No wall is answering, so Tessera is running one on this phone. Everything works; nothing is lit in the room. Enter an address and look again when the wall is up."
                : "Where Tessera looks for it. The wall answers on port 8788.") {
            TextField("album-matrix.local:8788", text: $host)
                .font(.machine(13))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Ink.sunk)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }
                .onSubmit { commitHost() }

            HStack(spacing: 16) {
                Button("Use this address") { commitHost() }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .font(.ui(13, .medium))
                    .foregroundStyle(accent)
                Button("Look again") {
                    Taps.detent()
                    wall.lookForWallAgain()
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .font(.ui(13, .medium))
                .foregroundStyle(Ink.dim)
                Spacer()
                LinkChip(link: wall.link)
            }
            .padding(.top, 10)
        }
    }

    /// The reason a phone app exists: it can see what is playing, and the
    /// Mac cannot see it in time.
    private var telling: some View {
        Section("telling the wall what is playing",
                note: "Your phone knows what is playing the moment it changes. The Mac finds out about a track late, so without this the wall changes late too. Tessera posts to the reporter on your Mac, which answers on port 8787.") {
            TextField("your-mac.local:8787", text: $reporter)
                .font(.machine(13))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(Ink.sunk)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }
                .onSubmit { commitReporter() }

            HStack(spacing: 16) {
                Button("Start telling it") { commitReporter() }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .font(.ui(13, .medium))
                    .foregroundStyle(accent)
                Spacer()
                if let sent = wall.push.lastSent {
                    Text("sent \(sent.formatted(date: .omitted, time: .shortened))")
                        .font(.machine(10))
                        .foregroundStyle(Ink.moss)
                }
            }
            .padding(.top, 8)

            Toggle(isOn: Binding(
                get: { wall.push.keepAlive },
                set: { wall.push.keepAlive = $0; wall.push.restart() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep telling it in my pocket").font(.ui(15)).foregroundStyle(Ink.ink)
                    Text("Holds a silent audio session so iOS does not suspend the app. Costs a little battery and never interrupts Music.")
                        .font(.ui(12)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(accent)
            .padding(.top, 6)
        }
    }

    /// Whether an empty house keeps a lit wall.
    private var whenImGone: some View {
        Section("when my phone leaves",
                note: "Your phone talking to the reporter, or this app talking to the wall, is how it knows someone is home. Both quiet for fifteen minutes with nothing playing, and the wall can put itself out. It comes back on its own when your phone does.") {
            PillRow(
                label: "",
                options: [("leave it on", "stay"), ("turn it off", "off")],
                selected: wall.state.away,
                accent: accent
            ) { wall.send(["away": $0]) }
        }
    }

    /// The mirror of the sleep fade: mornings.
    private var waking: some View {
        Section("waking up",
                note: "At the set time the wall comes up from black, warm first, like a sky. It only lifts a wall that is off.") {
            Toggle(isOn: Binding(
                get: { wall.state.wakeEnabled },
                set: { wall.send(["wake_enabled": $0]); Taps.detent(intensity: 0.4) }
            )) {
                Text("Fade the wall up in the morning")
                    .font(.ui(15)).foregroundStyle(Ink.ink)
            }
            .tint(accent)

            if wall.state.wakeEnabled {
                HStack(spacing: 14) {
                    DatePicker("", selection: $wakeAt, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(accent)
                        .onChange(of: wakeAt) { _, d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            wall.send(["wake_time": String(format: "%02d:%02d",
                                                           c.hour ?? 7, c.minute ?? 0)])
                        }
                    Spacer()
                }
                .padding(.top, 10)

                PillRow(
                    label: "over",
                    options: [("10 min", 10.0), ("20 min", 20.0),
                              ("30 min", 30.0), ("45 min", 45.0)],
                    selected: wall.state.wakeFade,
                    accent: accent
                ) { wall.send(["wake_fade_min": $0]) }
                .padding(.top, 12)
            }
        }
    }

    /// The camera teaching the panel what white is.
    private var trueColour: some View {
        Section("true colour",
                note: "LED panels ship green-heavy. Point your camera at the wall and Tessera reads the cast and writes the correction. Run it twice if the first pass leaves a tint; each pass refines the last.") {
            HStack {
                Button("Calibrate with the camera") {
                    Taps.commit()
                    showCalibrate = true
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .font(.ui(15, .medium))
                .foregroundStyle(accent)
                Spacer()
                if wall.state.wbR < 0.995 || wall.state.wbG < 0.995 || wall.state.wbB < 0.995 {
                    Text(String(format: "%.2f/%.2f/%.2f",
                                wall.state.wbR, wall.state.wbG, wall.state.wbB))
                        .font(.machine(10))
                        .foregroundStyle(Ink.moss)
                }
            }
        }
    }

    /// The Pi lives sealed behind panels; this is its pulse.
    private var health: some View {
        Section("how the wall is doing", note: nil) {
            if let v = vitals {
                VStack(alignment: .leading, spacing: 9) {
                    vitalRow("holding", v.fps > 0 ? String(format: "%.0f fps", v.fps) : "idle")
                    if let t = v.tempC {
                        vitalRow("running at", String(format: "%.0f°C", t),
                                 warn: t >= 70)
                    }
                    if let th = v.throttled {
                        vitalRow("thermals", th.now ? "throttling now"
                                 : th.ever ? "throttled since boot" : "never throttled",
                                 warn: th.now)
                    }
                    vitalRow("awake for", v.uptime)
                }
            } else {
                Text("Asking the wall.")
                    .font(.ui(13)).foregroundStyle(Ink.faint)
            }
            Button("Check again") {
                Taps.detent(intensity: 0.3)
                Task { vitals = await Vitals.read(host: wall.host) }
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .font(.ui(13))
            .foregroundStyle(accent)
            .padding(.top, 10)
        }
    }

    private func vitalRow(_ name: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(name).font(.ui(13)).foregroundStyle(Ink.dim)
            Spacer()
            Text(value).font(.machine(12))
                .foregroundStyle(warn ? Ink.signal : Ink.ink)
        }
    }

    /// The lock-screen presence, which is off until asked for.
    private var lockScreen: some View {
        Section("on the lock screen", note: nil) {
            Toggle(isOn: Binding(
                get: { wall.live.enabled },
                set: { wall.live.enabled = $0; Taps.detent(intensity: 0.5) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the wall while it is on").font(.ui(15)).foregroundStyle(Ink.ink)
                    Text("A twelve by twelve version of what it is showing, on the lock screen and in the Dynamic Island. It ends itself when the wall goes dark.")
                        .font(.ui(12)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(accent)
        }
    }

    /// What the wall does when the music stops.
    private var whenItStops: some View {
        Section("when nothing is playing", note: nil) {
            PillRow(
                label: "",
                options: [("go dark", "black"), ("hold it", "hold"),
                          ("dim it", "dim"), ("drift", "ambient")],
                selected: wall.state.idle,
                accent: accent
            ) { wall.send(["idle": $0]) }
        }
    }

    private var sleep: some View {
        Section("sleep", note: "Fade the wall down over time, then let it go dark. Zero cancels a fade in progress.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sleepMinutes < 1 ? "off" : "\(Int(sleepMinutes))")
                    .font(.machine(26))
                    .foregroundStyle(sleepMinutes < 1 ? Ink.faint : accent)
                    .contentTransition(.numericText())
                if sleepMinutes >= 1 {
                    Text("min").font(.machine(10)).foregroundStyle(Ink.faint)
                }
            }
            Slider(value: $sleepMinutes, in: 0...120, step: 5)
                .tint(accent)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button("Start the fade") {
                    Taps.commit()
                    wall.send(["sleep_fade_min": sleepMinutes])
                }
                .buttonStyle(.plain)
                .font(.ui(13, .medium))
                .foregroundStyle(sleepMinutes < 1 ? Ink.faint : accent)
                .disabled(sleepMinutes < 1)

                if let left = wall.state.sleepRemaining, left > 0 {
                    Spacer()
                    Text("\(left / 60)m \(left % 60)s left")
                        .font(.machine(10))
                        .foregroundStyle(Ink.dim)
                }
            }
            .padding(.top, 8)
        }
    }

    private var light: some View {
        Section("light", note: "The same control that lives on the panel. It is here so it is reachable without a drag.") {
            HStack {
                Text("\(Int(brightness * 100))%")
                    .font(.machine(15))
                    .foregroundStyle(Ink.ink)
                Spacer()
            }
            Slider(value: $brightness, in: 0.05...1.0, step: 0.05) { editing in
                if !editing { wall.send(["brightness": brightness]) }
            }
            .tint(accent)
        }
    }

    private var panelCheck: some View {
        Section("panel check", note: "Puts a flat field on the wall so a dead emitter or a colour cast has nowhere to hide. The wall keeps showing it until you pick a mode again.") {
            let patterns: [(String, (UInt8, UInt8, UInt8))] = [
                ("white", (255, 255, 255)),
                ("red", (255, 0, 0)),
                ("green", (0, 255, 0)),
                ("blue", (0, 0, 255)),
            ]
            HStack(spacing: 10) {
                ForEach(patterns, id: \.0) { (name, rgb) in
                    Button {
                        Taps.commit()
                        wall.pushFlat(r: rgb.0, g: rgb.1, b: rgb.2)
                    } label: {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color(red: Double(rgb.0) / 255,
                                            green: Double(rgb.1) / 255,
                                            blue: Double(rgb.2) / 255))
                                .frame(height: 44)
                                .overlay { Circle().strokeBorder(Ink.hairline, lineWidth: 1) }
                            Text(name)
                                .font(.machine(9))
                                .textCase(.uppercase)
                                .foregroundStyle(Ink.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show full \(name) on the wall")
                }
            }
            Button("Back to the album") {
                Taps.commit()
                wall.send(["mode": "art"])
            }
            .buttonStyle(.plain)
            .font(.ui(13, .medium))
            .foregroundStyle(accent)
            .padding(.top, 14)
        }
    }

    private var music: some View {
        Section("what is playing", note: "With no wall yet, Tessera shows whatever is playing on this phone so there is something real to look at. It reads the now-playing track only, and nothing leaves the device.") {
            Button("Use my music") {
                Taps.detent()
                StandIn.requestMusicAccess()
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .font(.ui(13, .medium))
            .foregroundStyle(accent)
        }
    }

    private var about: some View {
        Section("about", note: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tessera")
                    .font(.display(17))
                    .kerning(1.4)
                    .foregroundStyle(Ink.ink)
                Text("A remote for a wall of 4,096 emitters. Nothing leaves your network: the app talks to the wall directly and keeps no account.")
                    .font(.ui(13))
                    .foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitReporter() {
        let trimmed = reporter.trimmingCharacters(in: .whitespaces)
        wall.push.host = trimmed
        Taps.commit()
        // restart() bails while access is .notDetermined, so it has to run in
        // the grant's completion: firing it immediately left the push dead
        // until a second tap, with nothing on screen saying why.
        StandIn.requestMusicAccess { [weak wall] in wall?.push.restart() }
    }

    private func commitHost() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        wall.host = trimmed
        Taps.commit()
        Task { await wall.pollState() }
    }
}

/// A settings block: label, controls, and one honest sentence about what the
/// thing does. Not a card, not a grouped list row.
private struct Section<Content: View>: View {
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
