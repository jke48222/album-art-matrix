// AlbumWall v4 — sectioned. Four pages on a labeled tab bar, each owning
// one world: RECORD (the music), LAMP (the light), CREATE (your pixels),
// THE WALL (the machine). No sheets, no pull-to-refresh — the 5s poll and
// page structure do that work, so no gesture ever fights another.
import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    @AppStorage("appearance") private var appearanceRaw = Appearance.auto.rawValue
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var pusher: Pusher

    private var theme: Theme {
        Theme.resolve(Appearance(rawValue: appearanceRaw) ?? .auto, system: scheme)
    }

    var body: some View {
        Group {
            if pusher.authorized {
                RootView()
            } else {
                FirstRunView()
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(theme.isNight ? .dark : nil)
    }
}

// ---- chassis ------------------------------------------------------------
struct RootView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var wall: WallAPI
    @State private var tab: WallTab = .record
    @State private var autoOpenCreate: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    switch tab {
                    case .record: MusicView()
                    case .lamp: LampView()
                    case .create: CreateView(autoOpen: $autoOpenCreate)
                    case .wall: WallView()
                    }
                }
                .id(tab)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .animation(.easeOut(duration: 0.2), value: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PaperTabBar(selection: $tab)
            }
            .background(paperGround.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            wall.refresh()
            switch UserDefaults.standard.string(forKey: "devScreen") {
            case "record": tab = .record
            case "lamp": tab = .lamp
            case "create": tab = .create
            case "wall": tab = .wall
            case "doodle": tab = .create; autoOpenCreate = "doodle"
            case "photo": tab = .create; autoOpenCreate = "photo"
            case "ticker": tab = .create; autoOpenCreate = "ticker"
            case "video": tab = .create; autoOpenCreate = "video"
            default: break
            }
        }
    }

    private var paperGround: some View {
        ZStack {
            t.ground
            Image("papertex")
                .resizable(resizingMode: .tile)
                .opacity(t.isNight ? 0.35 : 0.8)
                .allowsHitTesting(false)
        }
    }
}

// A shared page scaffold: wide title, hairline, scrolling content.
struct PageScaffold<Content: View>: View {
    @Environment(\.theme) private var t
    let title: String
    var showStatus = true
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text(title)
                    .font(.displayWide(30))
                    .foregroundStyle(t.ink)
                    .padding(.top, 14)
                if showStatus { CompactStatus() }
                content
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 28)
        }
    }
}

// ---- RECORD -------------------------------------------------------------
struct MusicView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var pusher: Pusher
    @EnvironmentObject var wall: WallAPI

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Music")
                        .font(.displayWide(30))
                        .foregroundStyle(t.ink)
                    Spacer()
                    Circle()
                        .fill(wall.reachable ? t.ink : Theme.signal)
                        .frame(width: 6, height: 6)
                    MonoTag(wall.reachable ? "LINK OK" : "NO LINK",
                            color: wall.reachable ? nil : Theme.signal)
                }
                .padding(.top, 14)

                VStack(spacing: 8) {
                    WallPanel(captionLeft: "ON THE WALL",
                              captionRight: panelCaption,
                              captionRightColor: wall.reachable ? nil : Theme.signal) {
                        ZStack {
                            PanelContent(source: panelSource)
                                .id(panelKey)                    // crossfade
                                .transition(.opacity)
                        }
                        .animation(.easeInOut(duration: 0.4), value: panelKey)
                        .overlay(Color.black.opacity(dimAlpha))
                    }
                    MonoTag("ALBUMWALL P2.5, 64x64, REV A")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14)

                nowPlayingBox

                if wall.reachable {
                    StripControl(options: [
                        (id: "art", label: "ART"), (id: "cd", label: "SPIN"),
                    ], selection: Binding(
                        get: { wall.state.mode == "cd" ? "cd" : "art" },
                        set: { wall.state.mode = $0; wall.send(["mode": $0]) }),
                        height: 44)

                    if wall.state.mode == "cd" {
                        VStack(spacing: 12) {
                            SliderRow(label: "SPEED",
                                      valueText: String(format: "%.1f rpm", wall.state.rpm),
                                      value: $wall.state.rpm, range: 0.5...45,
                                      onLive: { wall.send(["rpm": $0], debounce: true) }) {
                                wall.send(["rpm": $0])
                            }
                            HStack {
                                StripControl(options: [
                                    (id: 7.5, label: "7.5"), (id: 33.3, label: "33⅓"),
                                    (id: 45.0, label: "45"),
                                ], selection: Binding(
                                    get: { nearestPreset },
                                    set: { wall.state.rpm = $0
                                           wall.send(["rpm": $0]) }),
                                    height: 38)
                                .frame(width: 210)
                                Spacer()
                            }
                        }
                    }
                } else {
                    offlineNote
                }

                JournalSection()
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 28)
            .animation(.easeOut(duration: 0.22), value: wall.state.mode)
        }
    }

    private var panelSource: PanelSource {
        guard wall.reachable else { return .dark }
        let s = wall.state
        switch s.mode {
        case "cd": return .spin(pusher.artwork ?? wall.wallFrame, rpm: s.rpm)
        case "ambient":
            let matched = s.match_art ? s.art_colors : nil
            return .ambient(effect: s.effect,
                            c1: Color(hex: matched?.first ?? s.color),
                            c2: Color(hex: matched?.last ?? s.color2),
                            speed: s.speed)
        case "off": return .dark
        case "frame": return .frame(wall.lastSentFrame ?? wall.wallFrame)
        case "clock":
            return .clock(rgb: clockRGB, twentyFour: s.clock_24h)
        case "ticker", "clip":
            return .frame(wall.wallFrame)
        default:
            return .art(wall.state.finish == "clean"
                        ? (pusher.artwork ?? wall.wallFrame)
                        : (wall.wallFrame ?? pusher.artwork))
        }
    }

    /// A change in this string crossfades the panel.
    private var panelKey: String {
        "\(wall.state.mode)|\(pusher.trackTitle)|\(wall.state.finish)|\(wall.reachable)"
    }

    private var panelCaption: String {
        guard wall.reachable else { return "NO SIGNAL" }
        switch wall.state.mode {
        case "cd": return "SPINNING"
        case "ambient": return "LAMP"
        case "off": return "PANELS OFF"
        case "frame": return "YOURS"
        case "ticker": return "TICKER"
        case "clock": return "CLOCK"
        case "clip": return "PLAYING"
        default: return "LIVE"
        }
    }

    private var clockRGB: (UInt8, UInt8, UInt8) { wall.state.inkRGB }

    private var dimAlpha: Double {
        !wall.reachable || wall.state.mode == "off" ? 0
            : min(0.95, 1 - pow(wall.state.brightness, 0.6))
    }

    private var nearestPreset: Double {
        let presets = [7.5, 33.3, 45.0]
        let hit = presets.min { abs($0 - wall.state.rpm) < abs($1 - wall.state.rpm) }!
        return abs(hit - wall.state.rpm) < 0.6 ? hit : -1
    }

    private var nowPlayingBox: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nowTitle)
                        .font(.display(16, .bold))
                        .foregroundStyle(t.ink)
                        .lineLimit(1)
                    Text(nowArtist)
                        .font(.display(13, .medium))
                        .foregroundStyle(t.ink55)
                        .lineLimit(1)
                }
                Spacer()
                if pusher.durationMs > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(clock(liveProgressMs)) / \(clock(pusher.durationMs))")
                            .font(.mono(11))
                            .foregroundStyle(t.ink55)
                    }
                }
            }
            .padding(14)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(t.hairlineSoft)
                        Rectangle().fill(t.ink)
                            .frame(width: geo.size.width * progressFraction)
                    }
                }
                .frame(height: 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var nowTitle: String {
        pusher.trackTitle == "-"
            ? (wall.state.now_showing?["title"] ?? "Nothing playing")
            : pusher.trackTitle
    }

    private var nowArtist: String {
        pusher.trackTitle == "-"
            ? (wall.state.now_showing?["artist"] ?? "Play something in Apple Music")
            : pusher.artist
    }

    private var liveProgressMs: Int {
        guard pusher.durationMs > 0 else { return 0 }
        let advance = pusher.isPlaying
            ? Int(Date().timeIntervalSince(pusher.progressDate) * 1000) : 0
        return min(pusher.durationMs, pusher.progressMs + advance)
    }

    private var progressFraction: CGFloat {
        pusher.durationMs > 0
            ? CGFloat(liveProgressMs) / CGFloat(pusher.durationMs) : 0
    }

    private func clock(_ ms: Int) -> String {
        let s = ms / 1000
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private var offlineNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't reach the wall.")
                .font(.display(18, .bold)).foregroundStyle(t.ink)
            (Text("No answer from ").foregroundStyle(t.ink55)
             + Text(wall.wallHost).font(.mono(12)).foregroundStyle(t.ink70)
             + Text(". Music keeps playing on the phone. Hosts are on the Wall page.")
                .foregroundStyle(t.ink55))
                .font(.display(14, .medium))
                .lineSpacing(3)
            HStack {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    wall.refresh()
                } label: {
                    Text("Retry")
                        .font(.display(14, .bold))
                        .foregroundStyle(Color(hex: 0xF4F1EA))
                        .padding(.horizontal, 26)
                        .frame(height: 42)
                        .background(Theme.signal)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// ---- journal, inline on the Record page ---------------------------------
struct JournalSection: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var wall: WallAPI
    @EnvironmentObject var pusher: Pusher
    @State private var sentTs: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MicroLabel(text: "HISTORY")
                Spacer()
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    wall.fetchJournal()
                } label: {
                    MonoTag("REFRESH")
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)

            if wall.journal.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(t.hairline).frame(height: 1)
                    Text(emptyText)
                        .font(.display(14, .medium))
                        .foregroundStyle(t.ink55)
                        .padding(.top, 10)
                }
            } else {
                ForEach(grouped, id: \.day) { group in
                    if group.day != "TODAY" {
                        MicroLabel(text: group.day)
                            .padding(.vertical, 10)
                    }
                    ForEach(group.entries) { e in row(e) }
                }
            }
        }
        .onAppear { wall.fetchJournal() }
    }

    private var emptyText: String {
        if !wall.reachable {
            return "History lives on the wall, and the wall isn't answering."
        }
        if pusher.lastPush == "never" || pusher.lastPush == "unreachable" {
            return "Nothing here yet. Start the Mac reporter and play a song."
        }
        return "Nothing yet today."
    }

    private struct DayGroup {
        let day: String
        let entries: [JournalEntry]
    }

    private var grouped: [DayGroup] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM"
        var out: [DayGroup] = []
        for e in wall.journal {
            let d = Date(timeIntervalSince1970: TimeInterval(e.ts))
            let day = cal.isDateInToday(d) ? "TODAY"
                : cal.isDateInYesterday(d) ? "YESTERDAY"
                : fmt.string(from: d).uppercased()
            if out.last?.day == day {
                out[out.count - 1] = DayGroup(day: day,
                                              entries: out.last!.entries + [e])
            } else {
                out.append(DayGroup(day: day, entries: [e]))
            }
        }
        return out
    }

    private func row(_ e: JournalEntry) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            wall.replay(e)
            withAnimation(.easeOut(duration: 0.15)) { sentTs = e.ts }
            // pull the wall's new pixels once the replay lands
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                wall.refresh()
            }
        } label: {
            VStack(spacing: 0) {
                Rectangle().fill(t.hairlineSoft).frame(height: 1)
                HStack(spacing: 13) {
                    thumb(e)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                            .font(.display(14, .semibold))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text(e.artist)
                            .font(.display(12, .medium))
                            .foregroundStyle(t.ink55)
                            .lineLimit(1)
                    }
                    Spacer()
                    if sentTs == e.ts {
                        Text("SHOWING")
                            .font(.mono(10, .medium))
                            .foregroundStyle(Theme.signal)
                    } else {
                        Text(timeText(e.ts))
                            .font(.mono(10))
                            .foregroundStyle(t.ink45)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(Pressable())
    }

    private func thumb(_ e: JournalEntry) -> some View {
        Group {
            if let urlStr = e.art_url, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                    } else { Theme.panel }
                }
            } else { Theme.panel }
        }
        .frame(width: 38, height: 38)
        .clipped()
    }

    private func timeText(_ ts: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// ---- LAMP ---------------------------------------------------------------
struct LampView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var wall: WallAPI
    @State private var facet = "glow"       // glow | clock
    @State private var editingWell = 1

    private let presets = ["#e8631a", "#5e1a1e", "#d9a028", "#4c6b4f"]
    private var glowActive: Bool { wall.state.mode == "ambient" }
    private var clockActive: Bool { wall.state.mode == "clock" }

    var body: some View {
        PageScaffold(title: "Lamp") {
            StripControl(options: [
                (id: "glow", label: "GLOW"), (id: "clock", label: "CLOCK"),
            ], selection: $facet, height: 44)

            if facet == "glow" { glowSection } else { clockSection }
        }
        .onAppear { if clockActive { facet = "clock" } }
        .animation(.easeOut(duration: 0.22), value: facet)
        .animation(.easeOut(duration: 0.22), value: wall.state.mode)
        .animation(.easeOut(duration: 0.22), value: wall.state.effect)
        .animation(.easeOut(duration: 0.22), value: wall.state.match_art)
    }

    // ---- glow (ambient) -------------------------------------------------
    @ViewBuilder private var glowSection: some View {
        WallPanel(captionLeft: glowActive ? "ON THE WALL" : "PREVIEW",
                  captionRight: wall.state.effect.uppercased()) {
            PanelContent(source: .ambient(
                effect: wall.state.effect,
                c1: Color(hex: matchedColors?.first ?? wall.state.color),
                c2: Color(hex: matchedColors?.last ?? wall.state.color2),
                speed: wall.state.speed))
            .overlay(Color.black.opacity(glowActive ? dimAlpha : 0))
        }
        .padding(.horizontal, 14)
        if !glowActive {
            PrimaryButton(label: "Light the wall",
                          enabled: wall.reachable) {
                wall.state.mode = "ambient"
                wall.send(["mode": "ambient"])
            }
        }

        StripControl(options: [
            (id: "solid", label: "SOLID"), (id: "breathe", label: "BREATHE"),
            (id: "pulse", label: "PULSE"), (id: "rainbow", label: "RAINBOW"),
            (id: "gradient", label: "GRAD"),
        ], selection: Binding(
            get: { wall.state.effect },
            set: { wall.state.effect = $0
                   wall.send(glowPatch(["effect": $0])) }),
            enabled: wall.reachable, height: 40,
            fontSize: 10.5, kern: 0.8)

        matchRow

        if !wall.state.match_art && wall.state.effect != "rainbow" {
            colorsRow
        }

        if wall.state.effect != "solid" {
            SliderRow(label: "MOTION",
                      valueText: String(format: "%.1fx", wall.state.speed),
                      value: $wall.state.speed, range: 0.1...3.0,
                      onLive: { wall.send(glowPatch(["speed": $0]), debounce: true) }) {
                wall.send(glowPatch(["speed": $0]))
            }
        }
    }

    // ---- clock ----------------------------------------------------------
    @ViewBuilder private var clockSection: some View {
        WallPanel(captionLeft: clockActive ? "ON THE WALL" : "PREVIEW",
                  captionRight: "CLOCK") {
            PanelContent(source: .clock(rgb: inkRGB,
                                        twentyFour: wall.state.clock_24h))
            .overlay(Color.black.opacity(clockActive ? dimAlpha : 0))
        }
        .padding(.horizontal, 14)
        if !clockActive {
            PrimaryButton(label: "Show the clock",
                          enabled: wall.reachable) {
                wall.state.mode = "clock"
                wall.send(["mode": "clock"])
            }
        }

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("24-hour").font(.display(15, .semibold))
                    .foregroundStyle(t.ink)
                Text(wall.state.clock_24h ? "18:42" : "6:42 PM")
                    .font(.display(12, .medium)).foregroundStyle(t.ink45)
            }
            Spacer()
            MechanicalToggle(isOn: Binding(
                get: { wall.state.clock_24h },
                set: { wall.state.clock_24h = $0
                       wall.send(clockPatch(["clock_24h": $0])) }))
        }

        matchRow

        if !wall.state.match_art {
            colorsRow
        }
    }

    // ---- shared pieces --------------------------------------------------
    private var matchRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Match the album").font(.display(15, .semibold))
                    .foregroundStyle(t.ink)
                Text("Colors from the current cover")
                    .font(.display(12, .medium)).foregroundStyle(t.ink45)
            }
            Spacer()
            MechanicalToggle(isOn: Binding(
                get: { wall.state.match_art },
                set: { wall.state.match_art = $0
                       wall.send(["match_art": $0]) }))
        }
    }

    private var colorsRow: some View {
        HStack(spacing: 10) {
            MicroLabel(text: "COLORS").frame(width: 66, alignment: .leading)
            well("A", hex: wall.state.color, active: editingWell == 1)
                .onTapGesture { editingWell = 1 }
            if facet == "glow" && wall.state.effect == "gradient" {
                well("B", hex: wall.state.color2, active: editingWell == 2)
                    .onTapGesture { editingWell = 2 }
            }
            Rectangle().fill(t.hairline).frame(width: 1, height: 22)
            ForEach(presets, id: \.self) { hex in
                Circle().fill(Color(hex: hex))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(t.hairline, lineWidth: 1))
                    .onTapGesture { setColor(Color(hex: hex)) }
            }
            Spacer(minLength: 0)
            ColorPicker("", selection: Binding(
                get: { Color(hex: editingWell == 1 ? wall.state.color
                                                   : wall.state.color2) },
                set: { setColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
        }
    }

    private func glowPatch(_ p: [String: Any]) -> [String: Any] {
        var p = p
        if !glowActive { p["mode"] = "ambient"; wall.state.mode = "ambient" }
        return p
    }

    private func clockPatch(_ p: [String: Any]) -> [String: Any] {
        var p = p
        if !clockActive { p["mode"] = "clock"; wall.state.mode = "clock" }
        return p
    }

    private var matchedColors: [String]? {
        wall.state.match_art ? wall.state.art_colors : nil
    }

    private var inkRGB: (UInt8, UInt8, UInt8) { wall.state.inkRGB }

    private var dimAlpha: Double {
        min(0.95, 1 - pow(wall.state.brightness, 0.6))
    }

    private func well(_ letter: String, hex: String, active: Bool) -> some View {
        ZStack {
            Circle().fill(Color(hex: hex))
            Text(letter).font(.display(12, .heavy))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: 38, height: 38)
        .overlay(Circle().stroke(active ? t.ink : t.hairline,
                                 lineWidth: active ? 2 : 1))
    }

    private func setColor(_ c: Color) {
        let hex = c.hexString
        if editingWell == 1 || facet == "clock"
            || wall.state.effect != "gradient" {
            wall.state.color = hex
            wall.send(facet == "clock" ? clockPatch(["color": hex])
                                       : glowPatch(["color": hex]),
                      debounce: true)
        } else {
            wall.state.color2 = hex
            wall.send(glowPatch(["color2": hex]), debounce: true)
        }
    }
}

// ---- CREATE -------------------------------------------------------------
struct CreateView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var wall: WallAPI
    @EnvironmentObject var creations: CreationStore
    @Binding var autoOpen: String?
    @State private var showDoodle = false
    @State private var showPhoto = false
    @State private var showTicker = false
    @State private var showVideo = false
    @State private var sentTs: Int? = nil

    var body: some View {
        PageScaffold(title: "Create") {
            card(icon: .create, title: "Doodle",
                 sub: "Draw on the wall, pixel by pixel") { showDoodle = true }
            card(icon: .wall, title: "A photo",
                 sub: "Crop a picture down to 64x64") { showPhoto = true }
            card(icon: .lamp, title: "Ticker",
                 sub: "Scroll a message across the room") { showTicker = true }
            card(icon: .record, title: "A video",
                 sub: "Twelve seconds, 4,096 LEDs") { showVideo = true }

            if !creations.creations.isEmpty {
                MicroLabel(text: "HISTORY")
                    .padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: 3), spacing: 10) {
                    ForEach(creations.creations) { c in
                        creationCell(c)
                    }
                }
                MonoTag("TAP TO SEND, HOLD TO DELETE")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .navigationDestination(isPresented: $showDoodle) { DoodleView() }
        .navigationDestination(isPresented: $showPhoto) { PhotoPushView() }
        .navigationDestination(isPresented: $showTicker) { TickerView() }
        .navigationDestination(isPresented: $showVideo) { VideoPushView() }
        .onAppear {
            if autoOpen == "doodle" { showDoodle = true }
            if autoOpen == "photo" { showPhoto = true }
            if autoOpen == "ticker" { showTicker = true }
            if autoOpen == "video" { showVideo = true }
            autoOpen = nil
        }
    }

    private func creationCell(_ c: Creation) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if c.isClip {
                let f = creations.frames(c)
                guard !f.isEmpty else { return }
                wall.sendClip(f, fps: c.fps, preview: creations.image(c))
            } else {
                guard let data = creations.pixels(c) else { return }
                wall.sendFrame(data, preview: creations.image(c))
            }
            withAnimation(.easeOut(duration: 0.15)) { sentTs = c.ts }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let img = creations.image(c) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Theme.panel.aspectRatio(1, contentMode: .fit)
                }
                if c.isClip {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7))
                        Text("\(c.frameCount)")
                            .font(.mono(8, .medium))
                    }
                    .foregroundStyle(Color(hex: 0xF4F1EA))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                }
                if sentTs == c.ts {
                    Text("SHOWING")
                        .font(.mono(8, .medium))
                        .foregroundStyle(Color(hex: 0xF4F1EA))
                        .padding(3)
                        .background(Theme.signal)
                }
            }
            .overlay(Rectangle().stroke(t.hairline, lineWidth: 1))
        }
        .buttonStyle(Pressable())
        .contextMenu {
            Button(role: .destructive) {
                creations.remove(c)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func card(icon: WallTab, title: String, sub: String,
                      action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 16) {
                TabIcon(tab: icon, color: t.ink)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.display(17, .bold)).foregroundStyle(t.ink)
                    Text(sub).font(.display(13, .medium)).foregroundStyle(t.ink45)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(t.ink45)
            }
            .padding(18)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hairline, lineWidth: 1))
        }
        .buttonStyle(Pressable())
    }
}

// ---- THE WALL -----------------------------------------------------------
struct WallView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var pusher: Pusher
    @EnvironmentObject var wall: WallAPI
    @AppStorage("appearance") private var appearanceRaw = Appearance.auto.rawValue
    @AppStorage("liveActivity") private var liveActivity = false
    @AppStorage("linkAlerts") private var linkAlerts = false

    var body: some View {
        PageScaffold(title: "The Wall") {
            SettingsSection(title: "POWER") {
                StripControl(options: [
                    (id: "on", label: "AWAKE"), (id: "off", label: "ASLEEP"),
                ], selection: Binding(
                    get: { wall.state.mode == "off" ? "off" : "on" },
                    set: { let m = $0 == "off" ? "off" : "art"
                           wall.state.mode = m
                           wall.send(["mode": m]) }),
                    enabled: wall.reachable, height: 44)
                if wall.state.mode != "off" {
                    SliderRow(label: "BRIGHTNESS",
                              valueText: "\(Int(wall.state.brightness * 100))%",
                              value: $wall.state.brightness, range: 0.05...1.0,
                              onLive: { wall.send(["brightness": $0], debounce: true) }) {
                        wall.send(["brightness": $0])
                    }
                    .padding(.top, 6)
                }
            }

            SettingsSection(title: "PICTURE") {
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel("Finish", note: "How album art maps to the LEDs")
                    StripControl(options: [
                        (id: "clean", label: "CLEAN"),
                        (id: "dither", label: "DITHER"),
                        (id: "poster", label: "POSTER"),
                    ], selection: Binding(
                        get: { wall.state.finish },
                        set: { wall.state.finish = $0
                               wall.send(["finish": $0]) }),
                        enabled: wall.reachable, height: 40)
                }
                .padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        rowLabel("Sleep fade", note: "Fade out, then off")
                        Spacer()
                        if let s = wall.state.sleep_remaining_s, s > 0 {
                            Text("\(s / 60 + 1) MIN LEFT")
                                .font(.mono(11, .medium))
                                .foregroundStyle(Theme.signal)
                        }
                    }
                    StripControl(options: [
                        (id: 0, label: "OFF"), (id: 15, label: "15"),
                        (id: 30, label: "30"), (id: 60, label: "60"),
                    ], selection: Binding(
                        get: { sleepSelection },
                        set: { wall.send(["sleep_fade_min": $0]) }),
                        enabled: wall.reachable, height: 40)
                }
            }

            SettingsSection(title: "LINK") {
                hostRow(name: "Wall (Raspberry Pi)",
                        host: $wall.wallHost, ok: wall.reachable)
                hostRow(name: "Reporter (Mac)",
                        host: $pusher.reporterHost,
                        ok: pusher.lastPush != "unreachable"
                            && pusher.lastPush != "never")
            }

            SettingsSection(title: "PUSH") {
                toggleRow("Background keepalive",
                          note: "Keep pushing while the phone is locked",
                          isOn: $pusher.backgroundPush)
                toggleRow("Lock-screen activity",
                          note: "Show the track on your lock screen",
                          isOn: Binding(
                            get: { liveActivity },
                            set: { on in
                                liveActivity = on
                                if !on { LiveActivityManager.endAll() }
                            }))
                toggleRow("Alert when the wall drops",
                          note: "Notify if the wall goes offline",
                          isOn: Binding(
                            get: { linkAlerts },
                            set: { on in
                                linkAlerts = on
                                if on {
                                    UNUserNotificationCenter.current()
                                        .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                                }
                            }))
                HStack {
                    rowLabel("Last push", note: nil)
                    Spacer()
                    Text(pusher.lastPush.uppercased())
                        .font(.mono(11)).foregroundStyle(t.ink70)
                }
            }

            SettingsSection(title: "APPEARANCE") {
                HStack(spacing: 12) {
                    appearanceCard(.paper)
                    appearanceCard(.night)
                    appearanceCard(.auto)
                }
            }

            SettingsSection(title: "PRIVACY") {
                HStack {
                    rowLabel("Apple Music access", note: nil)
                    Spacer()
                    Text(pusher.authorized ? "GRANTED" : "NOT YET")
                        .font(.mono(11, .medium))
                        .foregroundStyle(pusher.authorized ? t.ink70 : Theme.signal)
                }
            }

            HStack {
                Spacer()
                MonoTag("ALBUMWALL 0.3, 4096 LEDS, BITSLIP6")
                Spacer()
            }
            .padding(.top, 12)
        }
    }

    private var sleepSelection: Int {
        guard let s = wall.state.sleep_remaining_s, s > 0 else { return 0 }
        let m = Double(s) / 60
        return [15, 30, 60].min { abs(Double($0) - m) < abs(Double($1) - m) } ?? 0
    }

    private func rowLabel(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.display(15, .semibold)).foregroundStyle(t.ink)
            if let note {
                Text(note).font(.display(12, .medium)).foregroundStyle(t.ink45)
            }
        }
    }

    private func toggleRow(_ title: String, note: String?,
                           isOn: Binding<Bool>) -> some View {
        HStack {
            rowLabel(title, note: note)
            Spacer()
            MechanicalToggle(isOn: isOn)
        }
        .padding(.bottom, 6)
    }

    private func hostRow(name: String, host: Binding<String>, ok: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.display(15, .semibold)).foregroundStyle(t.ink)
                TextField("host:port", text: host)
                    .font(.mono(12))
                    .foregroundStyle(t.ink70)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            Spacer()
            Circle().fill(ok ? t.ink : Theme.signal).frame(width: 6, height: 6)
            Text(ok ? "OK" : "DOWN")
                .font(.mono(11, .medium))
                .foregroundStyle(ok ? t.ink70 : Theme.signal)
        }
        .padding(.bottom, 8)
    }

    private func appearanceCard(_ a: Appearance) -> some View {
        let selected = appearanceRaw == a.rawValue
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            appearanceRaw = a.rawValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    switch a {
                    case .paper: miniPage(Theme.paper)
                    case .night: miniPage(Theme.night)
                    case .auto:
                        HStack(spacing: 0) {
                            miniPage(Theme.paper)
                            miniPage(Theme.night)
                        }
                    }
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? t.ink : t.hairline,
                            lineWidth: selected ? 2 : 1))
                Text(a.label)
                    .font(.display(12, selected ? .bold : .medium))
                    .foregroundStyle(selected ? t.ink : t.ink55)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func miniPage(_ theme: Theme) -> some View {
        ZStack {
            theme.ground
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.panel).frame(width: 24, height: 24)
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ink).frame(width: 32, height: 4)
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ink.opacity(0.4)).frame(width: 20, height: 3)
            }
        }
    }
}

// ---- first run ----------------------------------------------------------
struct FirstRunView: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var pusher: Pusher

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALBUMWALL")
                .font(.display(15, .heavy)).kerning(1.5)
                .foregroundStyle(t.ink)
                .padding(.top, 14)
            Spacer()
            WallPanel(captionLeft: "ON THE WALL",
                      captionRight: "WAITING FOR MUSIC") {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color(hex: 0xF4F1EA))
                        .frame(width: max(2, geo.size.width / 64),
                               height: max(2, geo.size.width / 64))
                        .position(x: geo.size.width * 0.48,
                                  y: geo.size.height * 0.33)
                }
            }
            .padding(.horizontal, 20)
            Spacer()
            Text("Your music,\non the wall.")
                .font(.displayWide(30))
                .foregroundStyle(t.ink)
                .lineSpacing(2)
            Text("Whatever plays in Apple Music lights up 4,096 LEDs across the room. iOS will ask to read your library. Nothing ever leaves your network.")
                .font(.display(15, .medium))
                .foregroundStyle(t.ink55)
                .lineSpacing(3)
                .padding(.top, 12)
            Spacer()
            PrimaryButton(label: "Allow access") { pusher.requestAccess() }
            HStack {
                Spacer()
                MonoTag("P2.5, 4096 LEDS")
                Spacer()
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .background(t.ground.ignoresSafeArea())
    }
}
