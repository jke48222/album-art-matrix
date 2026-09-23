import SwiftUI

/// A routine changes the light around the artwork. Its diagram is a labelled
/// plan; the small live panel below it always uses the wall's received pixels.
struct SunPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @State private var location = OneShotSpot()
    @State private var daylight = 1.0
    @State private var night = 0.25
    @State private var saving = false
    @State private var problem: String?
    private let gold = Color(hex: 0xF2C684)
    private var ready: Bool { wall.link.isLive }
    private var located: Bool { wall.state.lat.isFinite && wall.state.lon.isFinite && abs(wall.state.lat) <= 90 && abs(wall.state.lon) <= 180 }
    private var enabled: Bool { wall.state.sun == "on" }
    private var phase: String {
        guard located else { return "Find your daylight" }
        guard enabled else { return "A daily rhythm" }
        switch wall.state.sunPhase {
        case "day", "polar_day": return "In the daylight"
        case "dawn": return "The room is waking"
        case "dusk": return "Easing into evening"
        case "night", "polar_night": return "An after-dark glow"
        default: return "Following the sun"
        }
    }

    var body: some View {
        RoutinePage(title: "Follow the sun", eyebrow: "LIGHT, IN RHYTHM", tint: gold, problem: problem) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 16) {
                    RoutineEyebrow(text: enabled ? (ready ? "SUNLIGHT PLAN · ACTIVE" : "LAST SUNLIGHT PLAN") : "SUNLIGHT PLAN", tint: gold)
                    Text(phase).font(typeSize.isAccessibilitySize ? .ui(20, .semibold) : .display(30)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    SunCourse(progress: course(at: ready ? context.date : wall.state.routineReceivedAt), enabled: enabled, tint: gold)
                        .frame(height: 144).accessibilityHidden(true)
                    metricsLayout {
                        RoutineMetric(label: "SUNRISE", value: time(wall.state.sunrise), symbol: "sunrise", tint: gold)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        RoutineMetric(label: "SUNSET", value: time(wall.state.sunset), symbol: "sunset", tint: Color(hex: 0xB9B5E6))
                    }
                    if wall.state.sunPhase == "polar_day" || wall.state.sunPhase == "polar_night" {
                        Text(wall.state.sunPhase == "polar_day" ? "The sun stays above the horizon today." : "The sun stays below the horizon today.")
                            .font(.ui(13)).foregroundStyle(Ink.dim)
                    }
                }.routineHero()
            }
            Toggle(isOn: Binding(get: { enabled }, set: { value in save(["sun": value ? "on" : "off"]) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Follow the sun").font(.ui(17, .semibold))
                    Text("Forty-minute transitions at dawn and dusk.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }.tint(gold).disabled(!ready || saving || !located)
            if !located {
                Text("Set the wall’s location to calculate sunrise and sunset. It keeps working without your phone.")
                    .font(.ui(14)).foregroundStyle(Ink.dim)
            }
            RoutineSection(title: "The light in your room", subtitle: "Daylight sets your wall brightness. After dark is a fraction of that level.") {
                RoutineLevel(title: "Daylight", symbol: "sun.max", value: $daylight, range: 0.05...1, tint: gold) {
                    save(["brightness": daylight])
                }
                Divider().overlay(Ink.hairline)
                RoutineLevel(title: "After dark", symbol: "moon", value: $night, range: 0.05...1, tint: Color(hex: 0xB9B5E6)) {
                    save(["sun_night": night])
                }
                Text("After dark: \(Int((daylight * night * 100).rounded()))% of full brightness")
                    .font(.ui(13)).foregroundStyle(Ink.dim)
            }.disabled(!ready || saving)
            RoutineSection(title: "The wall’s location", subtitle: "Read once when you choose. Also used by Weather.") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "location").foregroundStyle(gold).font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(located ? (wall.state.place.isEmpty ? "Location saved on the wall" : wall.state.place) : "No location saved")
                            .font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                        if located {
                            Text(String(format: "%.2f° %@ · %.2f° %@", abs(wall.state.lat), wall.state.lat < 0 ? "S" : "N", abs(wall.state.lon), wall.state.lon < 0 ? "W" : "E"))
                                .font(.ui(12)).foregroundStyle(Ink.dim)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let message = location.problem { RoutineProblem(message: message) }
                Button {
                    problem = nil
                    location.fetch { lat, lon in save(["lat": lat, "lon": lon, "place": ""]) }
                } label: {
                    HStack {
                        if location.busy { ProgressView().tint(gold) }
                        Text(location.busy ? "Finding this spot…" : located ? "Update to this location" : "Use this location")
                    }.font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered).tint(gold).disabled(!ready || saving || location.busy)
                if location.permissionDenied {
                    Button("Open Location Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }.quietLink().frame(minHeight: 44)
                }
            }
            RoutineWallReceipt(detail: sunReceipt, tint: gold)
        }
        .onAppear { daylight = wall.state.brightness; night = wall.state.sunNight }
        .onChange(of: wall.state.brightness) { _, value in if !saving { daylight = value } }
        .onChange(of: wall.state.sunNight) { _, value in if !saving { night = value } }
        .onDisappear { location.cancel() }
    }

    private var metricsLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
    private var sunReceipt: String {
        guard enabled else { return "Your selected brightness stays constant." }
        if let level = wall.state.effectiveBrightness { return "Output now · \(Int((level * 100).rounded()))% brightness" }
        return "Sunlight adjusts the brightness of your current face."
    }
    private func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return RoutineText.time(date, zone: wall.state.routineTimeZone, twentyFour: wall.state.clock24h)
    }
    private func course(at date: Date) -> Double? {
        guard let rise = wall.state.sunrise, let set = wall.state.sunset, set > rise,
              let now = wall.state.wallClock(at: date) else { return nil }
        guard now >= rise, now <= set else { return nil }
        return min(1, max(0, now.timeIntervalSince(rise) / set.timeIntervalSince(rise)))
    }
    private func save(_ patch: [String: Any]) {
        guard ready, !saving else { return }
        saving = true; problem = nil
        Task { @MainActor in
            let accepted = await wall.updateRoutine(patch)
            saving = false
            if accepted { Taps.commit() }
            else { problem = "The wall didn’t receive that change. Reconnect and try again."; daylight = wall.state.brightness; night = wall.state.sunNight }
        }
    }
}

struct SleepPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var minutes = 30.0
    @State private var saving = false
    @State private var problem: String?
    private let moon = Color(hex: 0xC5C6EF)
    private var ready: Bool { wall.link.isLive }
    private var fading: Bool { wall.state.sleepStatus == "fading" || (wall.state.sleepRemaining ?? 0) > 0 }

    var body: some View {
        RoutinePage(title: "Sleep", eyebrow: "LET THE ROOM REST", tint: moon, problem: problem) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = wall.state.sleepSeconds(at: ready ? context.date : wall.state.routineReceivedAt)
                let fraction = fading ? 1 - Double(remaining ?? 0) / Double(max(1, wall.state.sleepTotal ?? Int(minutes * 60))) : 0
                VStack(alignment: .leading, spacing: 14) {
                    RoutineEyebrow(text: fading ? (ready ? "FADING TO BLACK" : "LAST FADE STATUS") : wall.state.sleepStatus == "completed" ? "THE WALL IS RESTING" : "SLEEP PLAN", tint: moon)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fading ? RoutineText.countdown(remaining ?? 0) : "\(Int(minutes))")
                            .font(.display(64)).foregroundStyle(Ink.ink).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                        if !fading { Text("min").font(.ui(20)).foregroundStyle(moon) }
                    }
                    Text(fading ? "A little less light, every moment." : wall.state.sleepStatus == "completed" ? "The fade finished. Rest easy." : "A soft landing at the end of the day.")
                        .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    RoutineEnvelope(rising: false, progress: fading ? fraction : nil, tint: moon)
                        .frame(height: 110).accessibilityHidden(true)
                    HStack {
                        Text(fading ? "Fading now" : "Your current light")
                        Spacer()
                        Text(fading ? endTime : "Off in \(Int(minutes)) min")
                    }.font(.ui(12)).foregroundStyle(moon)
                }.routineHero()
            }
            if fading {
                Button { command(0) } label: {
                    Label(saving ? "Stopping…" : "Cancel the fade", systemImage: "stop.circle")
                        .font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(.bordered).tint(moon).disabled(!ready || saving)
                Text("Cancel restores your selected brightness. The wall keeps its current face.")
                    .font(.ui(14)).foregroundStyle(Ink.dim)
            } else {
                RoutineSection(title: "Time to unwind", subtitle: "Keep your current artwork, then switch the wall off.") {
                    RoutineDurations(value: $minutes, values: [15, 30, 45, 60], tint: moon)
                    Slider(value: $minutes, in: 5...120, step: 5).tint(moon)
                        .accessibilityLabel("Sleep fade duration").accessibilityValue("\(Int(minutes)) minutes")
                    HStack { Text("5 min"); Spacer(); Text("\(Int(minutes)) minutes").foregroundStyle(Ink.ink); Spacer(); Text("2 hours") }
                        .font(.ui(12)).foregroundStyle(Ink.dim)
                }
                RoutineAction(title: saving ? "Starting the fade…" : "Fade to sleep", symbol: "moon.zzz", tint: moon, busy: saving, enabled: ready && !saving && wall.state.mode != "off") { command(minutes) }
                if wall.state.mode == "off" {
                    Text("The wall is already off. Choose a face in Your wall before starting a fade.")
                        .font(.ui(14)).foregroundStyle(Ink.dim)
                }
            }
            RoutineWallReceipt(detail: fading ? "The current face fades in place." : "Sleep fades the light; your artwork stays yours.", tint: moon)
        }
    }
    private var endTime: String {
        guard let date = wall.state.sleepEndsAt else { return "Then off" }
        return "Off at " + RoutineText.time(date, zone: wall.state.routineTimeZone, twentyFour: wall.state.clock24h)
    }
    private func command(_ duration: Double) {
        guard ready, !saving else { return }
        saving = true; problem = nil
        Task { @MainActor in
            let accepted = await wall.updateRoutine(["sleep_fade_min": duration])
            saving = false
            if accepted { Taps.commit() } else { problem = "The wall didn’t receive that change. Your fade status will refresh when it reconnects." }
        }
    }
}

struct WakePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @State private var saving = false
    @State private var problem: String?
    @State private var fade = 20.0
    @State private var draftTime = "07:00"
    @State private var draftEnabled = false
    @State private var loaded = false
    private let dawn = Color(hex: 0xF4BC86)
    private var ready: Bool { wall.link.isLive }
    private var zone: TimeZone { wall.state.routineTimeZone ?? .gmt }
    private var clockReady: Bool { wall.state.routineTimeZone != nil }
    private var dirty: Bool { loaded && (draftTime != wall.state.wakeTime || draftEnabled != wall.state.wakeEnabled || abs(fade - wall.state.wakeFade) > 0.01) }
    private var timeLabel: String { TimeInput.timeLabel(draftTime, twentyFour: wall.state.clock24h) }

    var body: some View {
        RoutinePage(title: "Wake up", eyebrow: "A GENTLER BEGINNING", tint: dawn, problem: problem) {
            VStack(alignment: .leading, spacing: 14) {
                RoutineEyebrow(text: dirty ? "UNSAVED WAKE-UP PLAN" : wall.state.wakeActive ? "LIGHT IS RISING" : draftEnabled ? "YOUR DAILY SUNRISE" : "WAKE-UP PLAN", tint: dawn)
                Text(timeLabel)
                    .font(.display(typeSize.isAccessibilitySize ? 32 : 60)).foregroundStyle(Ink.ink).minimumScaleFactor(0.65).lineLimit(1)
                Text(wall.state.wakeActive && !dirty ? "The day arrives in warm colour." : "Let the light arrive before the rush.")
                    .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                RoutineEnvelope(rising: true, progress: wall.state.wakeActive && !dirty ? wall.state.wakeProgress : nil, tint: dawn)
                    .frame(height: 110).accessibilityHidden(true)
                metricsLayout {
                    RoutineMetric(label: "FADE STARTS", value: timeLabel, symbol: "sunrise", tint: dawn)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    RoutineMetric(label: "FULL LIGHT", value: fullLight, symbol: "sun.max", tint: dawn)
                }
            }.routineHero()
            Toggle(isOn: $draftEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wake with light").font(.ui(17, .semibold))
                    Text("Every day, on the wall’s clock.").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }.tint(dawn).disabled(saving || !clockReady)
            RoutineSection(title: "Start the morning", subtitle: clockReady ? "Wall time · \(wall.state.wallTimeZone ?? zone.identifier)" : "Connect to read the wall’s time zone before setting a schedule.") {
                DatePicker("Fade starts", selection: Binding(get: {
                    TimeInput.date(draftTime)
                }, set: { draftTime = TimeInput.civilTime($0) }), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .environment(\.timeZone, TimeInput.editorZone).environment(\.calendar, TimeInput.editorCalendar)
                    .frame(maxWidth: .infinity).frame(height: 150).clipped().tint(dawn)
                    .accessibilityLabel("Daily wake fade start time on the wall")
                    .disabled(saving || !clockReady)
            }
            RoutineSection(title: "How slowly the light arrives", subtitle: "Warm first, then clear. A longer fade makes a quieter entrance.") {
                RoutineDurations(value: $fade, values: [10, 20, 30, 45], tint: dawn)
            }.disabled(saving)
            if dirty {
                RoutineAction(title: saving ? "Saving schedule…" : "Save schedule", symbol: "checkmark", tint: dawn, busy: saving, enabled: ready && !saving && clockReady) { save() }
                if !ready { Text("Your edits are kept here. Reconnect to save them to the wall.").font(.ui(14)).foregroundStyle(Ink.dim) }
            }
            VStack(alignment: .leading, spacing: 12) {
                Label(schedule, systemImage: wall.state.wakeEnabled ? "calendar" : "calendar.badge.minus")
                    .font(.ui(15, .medium)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Text("Wake up lifts a wall that is off. A wall already showing something keeps its current light. This routine makes no sound.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            RoutineWallReceipt(detail: wall.state.wakeActive ? "Your artwork is coming up with the light." : "The wall keeps this schedule when your phone is away.", tint: dawn)
        }
        .onAppear {
            guard !loaded else { return }
            fade = wall.state.wakeFade; draftTime = wall.state.wakeTime; draftEnabled = wall.state.wakeEnabled; loaded = true
        }
        .onChange(of: wall.state.wakeFade) { old, value in if abs(fade - old) < 0.01 { fade = value } }
        .onChange(of: wall.state.wakeTime) { old, value in if draftTime == old { draftTime = value } }
        .onChange(of: wall.state.wakeEnabled) { old, value in if draftEnabled == old { draftEnabled = value } }
    }
    private var metricsLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
    private var fullLight: String {
        if !dirty, let end = wall.state.wakeNextEnd {
            return RoutineText.time(end, zone: wall.state.routineTimeZone, twentyFour: wall.state.clock24h)
        }
        let civil = TimeInput.civilTime(TimeInput.date(draftTime).addingTimeInterval(fade * 60))
        return TimeInput.timeLabel(civil, twentyFour: wall.state.clock24h)
    }
    private var schedule: String {
        if dirty { return "Changes are ready to save" }
        guard wall.state.wakeEnabled else { return "Schedule saved · currently off" }
        guard let date = wall.state.wakeNextStart else { return "Every day at \(timeLabel)" }
        let formatter = DateFormatter(); formatter.timeZone = zone; formatter.dateFormat = "EEE, MMM d"
        return "Next · \(formatter.string(from: date)) at \(RoutineText.time(date, zone: zone, twentyFour: wall.state.clock24h))"
    }
    private func save() {
        guard ready, !saving, clockReady else { return }
        saving = true; problem = nil
        let patch: [String: Any] = ["wake_enabled": draftEnabled, "wake_time": draftTime, "wake_fade_min": fade]
        Task { @MainActor in
            let accepted = await wall.updateRoutine(patch)
            saving = false
            if accepted { Taps.commit() }
            else { problem = "The wall didn’t receive that schedule change. Your edits are still here. Reconnect and try again." }
        }
    }
}

private enum RoutineText {
    static func time(_ date: Date, zone: TimeZone?, twentyFour: Bool) -> String {
        guard let zone else { return "—" }
        let formatter = DateFormatter(); formatter.timeZone = zone
        formatter.dateFormat = twentyFour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }
    static func countdown(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct RoutinePage<Content: View>: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let eyebrow: String
    let tint: Color
    let problem: String?
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    if !typeSize.isAccessibilitySize { RoutineEyebrow(text: eyebrow, tint: tint) }
                    Text(title).font(.display(typeSize.isAccessibilitySize ? 27 : 38)).foregroundStyle(Ink.ink)
                }.padding(.top, 10)
                if !wall.link.isLive {
                    Label(wall.link.isStandIn ? "Preview on this phone · connect to control the wall" : "Wall offline · showing the last received state", systemImage: "wifi.slash")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { RoutineProblem(message: problem) }
                content
            }.padding(.horizontal, 22).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(Ink.ground).tint(tint)
            .navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct RoutineEyebrow: View {
    let text: String
    let tint: Color
    var body: some View { Text(text).font(.machine(10)).tracking(0.8).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true) }
}

private struct RoutineMetric: View {
    let label: String
    let value: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(label, systemImage: symbol).font(.ui(11, .medium)).foregroundStyle(tint)
            Text(value).font(.ui(19, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct RoutineSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct RoutineLevel: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let commit: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.machine(17)).foregroundStyle(tint)
            }
            Slider(value: $value, in: range, step: 0.05, onEditingChanged: { editing in if !editing { commit() } })
                .tint(tint).accessibilityLabel(title + " brightness").accessibilityValue("\(Int((value * 100).rounded())) percent")
        }
    }
}

private struct RoutineDurations: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var value: Double
    let values: [Double]
    let tint: Color
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
            ForEach(values, id: \.self) { item in
                Button { value = item; Taps.detent(intensity: 0.4) } label: {
                    Text("\(Int(item)) min").font(.ui(14, .semibold))
                        .foregroundStyle(value == item ? Ink.ground : Ink.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(value == item ? tint : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(value == item ? .clear : Ink.hairline))
                }.buttonStyle(PressStyle(scale: 0.98)).accessibilityAddTraits(value == item ? [.isSelected] : [])
            }
        }
    }
}

private struct RoutineAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let busy: Bool
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) } else { Image(systemName: symbol) }
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Ink.ground).background(tint, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(PressStyle()).disabled(!enabled).opacity(enabled || busy ? 1 : 0.45)
    }
}

private struct RoutineProblem: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Color(hex: 0xF3BE96))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
    }
}

private struct RoutineWallReceipt: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let detail: String
    let tint: Color
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 15)) : AnyLayout(HStackLayout(alignment: .center, spacing: 15))
        layout {
            ZStack {
                Color.black
                if wall.state.mode != "off", let data = wall.frame, let bitmap = FinishSwatch.bitmap([UInt8](data)) {
                    Image(uiImage: bitmap).resizable().interpolation(.none).scaledToFit()
                } else if wall.state.mode != "off" {
                    Image(systemName: "square.grid.3x3").font(.system(size: 25, weight: .light)).foregroundStyle(Ink.dim)
                }
            }.frame(width: 74, height: 74).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(wall.state.mode == "off" ? "Wall off" : "Current wall frame")
            VStack(alignment: .leading, spacing: 6) {
                Text(wall.link.isLive ? "LIVE WALL" : wall.link.isStandIn ? "PHONE PREVIEW" : "LAST RECEIVED WALL")
                    .font(.machine(9)).foregroundStyle(tint)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }.padding(.top, 20).overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }
}

private extension View {
    func routineHero() -> some View {
        padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x14151A), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(0.065)))
    }
}

/// A day arc is a plan for light, not an invented astronomical position.
private struct SunCourse: View {
    let progress: Double?
    let enabled: Bool
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let baseline = size.height - 16
            let left: CGFloat = 10, right = size.width - 10
            let width = right - left
            func point(_ fraction: Double) -> CGPoint {
                CGPoint(x: left + width * fraction, y: baseline - sin(fraction * .pi) * (baseline - 16))
            }
            var arc = Path(); arc.move(to: point(0))
            for step in 1...100 { arc.addLine(to: point(Double(step) / 100)) }
            var fill = arc; fill.addLine(to: CGPoint(x: right, y: baseline)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.18), tint.opacity(0)]), startPoint: CGPoint(x: size.width / 2, y: 0), endPoint: CGPoint(x: size.width / 2, y: baseline)))
            for index in 0...24 {
                let x = left + width * Double(index) / 24
                var tick = Path(); tick.move(to: CGPoint(x: x, y: baseline + 5)); tick.addLine(to: CGPoint(x: x, y: baseline + (index % 6 == 0 ? 13 : 9)))
                context.stroke(tick, with: .color(tint.opacity(index % 6 == 0 ? 0.55 : 0.18)), lineWidth: 1)
            }
            context.stroke(arc, with: .color(tint.opacity(enabled ? 0.75 : 0.3)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if let progress, enabled {
                let spot = point(progress)
                for radius in stride(from: 24.0, through: 10, by: -3) {
                    context.fill(Path(ellipseIn: CGRect(x: spot.x - radius, y: spot.y - radius, width: radius * 2, height: radius * 2)), with: .color(tint.opacity(0.018)))
                }
                context.fill(Path(ellipseIn: CGRect(x: spot.x - 6, y: spot.y - 6, width: 12, height: 12)), with: .color(tint))
                context.stroke(Path(ellipseIn: CGRect(x: spot.x - 10, y: spot.y - 10, width: 20, height: 20)), with: .color(tint.opacity(0.45)), lineWidth: 1)
            }
        }
    }
}

/// The same monotonic linear fade used by the wall, with vertical illuminance
/// marks. No ambient animation or simulated live pixels.
private struct RoutineEnvelope: View {
    let rising: Bool
    let progress: Double?
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 12, bottom = size.height - 8
            func point(_ fraction: Double) -> CGPoint {
                CGPoint(x: size.width * fraction, y: rising ? bottom - (bottom - top) * fraction : top + (bottom - top) * fraction)
            }
            for step in 0...42 {
                let fraction = Double(step) / 42
                let spot = point(fraction)
                var bar = Path(); bar.move(to: spot); bar.addLine(to: CGPoint(x: spot.x, y: bottom))
                context.stroke(bar, with: .color(tint.opacity(0.11 + (rising ? fraction : 1 - fraction) * 0.28)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            var path = Path(); path.move(to: point(0)); path.addLine(to: point(1))
            context.stroke(path, with: .color(tint.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            if let progress {
                let fraction = min(1, max(0, progress)), spot = point(fraction)
                var stem = Path(); stem.move(to: CGPoint(x: spot.x, y: 0)); stem.addLine(to: CGPoint(x: spot.x, y: size.height))
                context.stroke(stem, with: .color(tint.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                context.fill(Path(ellipseIn: CGRect(x: spot.x - 5, y: spot.y - 5, width: 10, height: 10)), with: .color(tint))
            }
        }
    }
}
