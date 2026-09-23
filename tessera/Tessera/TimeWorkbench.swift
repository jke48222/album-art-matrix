import SwiftUI

/// Clock, timer and alarm share one destination and one acknowledged control
/// surface. The artwork is the production wall frame, never a second face.
struct TimeWorkbench: View {
    enum Tab: String, CaseIterable, Identifiable {
        case clock = "Clock", timer = "Timer", alarm = "Alarm"
        var id: String { rawValue }
        var symbol: String { switch self { case .clock: "clock"; case .timer: "timer"; case .alarm: "alarm" } }
    }

    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let accent: Color
    var showsPreview = true
    var initialTab: Tab? = nil
    @State private var tab: Tab = .clock
    @State private var minutes = "10"
    @State private var seconds = "00"
    @State private var alarmDate = TimeInput.date("07:00")
    @State private var alarmEnabled = false
    @State private var alarmEditing = false
    @State private var clockInk = Ink.ink
    @State private var inkEditing = false
    @State private var busy = false
    @State private var receipt: String?
    @State private var problem: String?
    @State private var preview: UIImage?
    @State private var previewFailed = false
    @State private var initialized = false
    @FocusState private var durationFocused: Bool

    private var ink: Color { accent.toned(forDark: true) }
    private var ready: Bool { wall.link.isLive }
    private var activeTimer: Bool { wall.state.mode == "timer" && wall.state.timerRemaining != nil }
    private var ringing: Bool { wall.state.timerStatus == "ringing" }
    private var draftSeconds: Int? { TimeInput.seconds(minutes: minutes, seconds: seconds) }
    private var alarmDirty: Bool { alarmEnabled != wall.state.alarmEnabled || TimeInput.civilTime(alarmDate) != wall.state.alarmTime }
    private var previewFace: String { tab == .timer && !activeTimer ? "timer" : "clock" }
    private var useLiveFrame: Bool { (wall.state.mode == "clock" && previewFace == "clock") || activeTimer }
    private var previewKey: String { "\(wall.host)|\(tab)|\(draftSeconds ?? 0)|\(wall.state.mode)|\(wall.state.clock24h)|\(wall.state.color)|\(ready)|\(scenePhase)|\(initialized)" }
    private var zone: TimeZone? { TimeInput.timeZone(identifier: wall.state.wallTimeZone, offset: wall.state.wallUTCOffset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if typeSize.isAccessibilitySize {
                Text("Time & alarms").font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ringing ? "A MOMENT, MADE VISIBLE" : "THE ROOM HAS ITS OWN RHYTHM").font(.machine(8)).tracking(0.8).foregroundStyle(ink)
                    Text(ringing ? (wall.state.timerKind == "alarm" ? "Your daily cue." : "Time, completed.") : "Time, in light.")
                        .font(.display(34)).foregroundStyle(Ink.ink)
                }
            }
            tabs
            if showsPreview { wallPreview }
            Group {
                switch tab {
                case .clock: clockControls
                case .timer: timerControls
                case .alarm: alarmControls
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.ui(13)).foregroundStyle(Ink.signal)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("time.error")
            }
            if let receipt {
                Label(receipt, systemImage: "checkmark.circle.fill").font(.ui(13)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("time.receipt")
            }
            if !ready {
                Label("Wall offline. Your edits stay here until you reconnect and save.", systemImage: "wifi.slash")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            tab = initialTab ?? (activeTimer ? .timer : .clock)
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "-time-tab"), CommandLine.arguments.indices.contains(index + 1),
               let choice = Tab.allCases.first(where: { $0.rawValue.lowercased() == CommandLine.arguments[index + 1] }) { tab = choice }
            #endif
            syncAlarm(); clockInk = Color.wall(hex: wall.state.color)
        }
        .onChange(of: minutes) { _, _ in receipt = nil; problem = nil }
        .onChange(of: seconds) { _, _ in receipt = nil; problem = nil }
        .onChange(of: wall.state.alarmTime) { _, _ in if !alarmEditing { syncAlarm() } }
        .onChange(of: wall.state.alarmEnabled) { _, _ in if !alarmEditing { syncAlarm() } }
        .onChange(of: wall.state.color) { _, color in if !inkEditing { clockInk = Color.wall(hex: color) } }
        .onChange(of: wall.host) { _, _ in alarmEditing = false; inkEditing = false; syncAlarm(); clockInk = Color.wall(hex: wall.state.color); receipt = nil; problem = nil }
        .onChange(of: wall.state.timerStatus) { _, status in
            if status == "ringing" {
                tab = .timer
                Taps.commit()
                UIAccessibility.post(notification: .announcement,
                                     argument: wall.state.timerKind == "alarm" ? "Your alarm is ringing. Stop or snooze for five minutes." : "Timer complete. Done or repeat the same duration.")
            }
        }
        .task(id: previewKey) { await watchPreview() }
        .toolbar {
            if durationFocused {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { durationFocused = false } }
            }
        }
    }

    private var tabs: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            ForEach(Tab.allCases) { item in
                Button {
                    durationFocused = false; tab = item; receipt = nil; problem = nil; Taps.detent()
                } label: {
                    Label(item.rawValue, systemImage: item.symbol).font(.ui(14, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(tab == item ? Ink.ground : Ink.dim)
                        .background(tab == item ? ink : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(PressStyle()).accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("time.tab.\(item.rawValue.lowercased())").disabled(busy)
            }
        }.padding(5).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 17))
    }

    private var wallPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(hex: 0x080C10)
                if let bitmap = useLiveFrame ? wall.frame.flatMap({ FinishSwatch.bitmap([UInt8]($0)) }) : preview {
                    Image(uiImage: bitmap).resizable().interpolation(.none).scaledToFit()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: tab.symbol).font(.system(size: 38, weight: .ultraLight))
                        Text(!ready ? "Reconnect for the wall’s view" : previewFace == "timer" && draftSeconds == nil ? "Enter a valid duration" : previewFailed ? "Preview unavailable" : "Preparing the wall’s view")
                            .font(.ui(13)).multilineTextAlignment(.center)
                        if ready && !previewFailed && (previewFace != "timer" || draftSeconds != nil) { ProgressView().tint(ink) }
                    }.foregroundStyle(Ink.dim).padding(24)
                }
            }.aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 160 : (ringing ? 248 : tab == .clock ? 280 : tab == .alarm ? 156 : 196))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(useLiveFrame ? "The wall’s actual \(activeTimer ? "timer" : "clock") pixels" : "\(previewFace.capitalized) preview rendered by the wall")
            HStack(alignment: .firstTextBaseline) {
                Label(useLiveFrame ? (wall.link.isStandIn ? "PHONE PREVIEW" : wall.link.isLive ? "ON THE WALL" : "LAST WALL FRAME") : "\(previewFace.uppercased()) PREVIEW", systemImage: useLiveFrame && ready ? "circle.fill" : "square.dashed")
                    .font(.machine(typeSize.isAccessibilitySize ? 9 : 8))
                Spacer(minLength: 8)
                if !typeSize.isAccessibilitySize {
                    Text("\(Panel.side) × \(Panel.side)").font(.machine(8))
                }
            }.foregroundStyle(Ink.dim)
            if !useLiveFrame {
                Text(previewFace == "timer" ? "The countdown begins when you press Start." : "Choose Show clock to put this view on the wall.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clockControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("How you tell time", subtitle: "The same face, on your phone and your wall.")
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                clockFormat("12 hour", example: "8:24 PM", value: false)
                clockFormat("24 hour", example: "20:24", value: true)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Light colour").font(.ui(15, .semibold))
                    Text("An ink for the hours.").font(.ui(12)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 8)
                ColorPicker("Clock light colour", selection: Binding(get: { clockInk }, set: { clockInk = $0; inkEditing = true; receipt = nil }), supportsOpacity: false)
                    .labelsHidden().frame(width: 48, height: 48).disabled(busy)
            }.foregroundStyle(Ink.ink)
            if inkEditing && clockInk.wallHex.lowercased() != wall.state.color.lowercased() {
                action("Save light colour", symbol: "checkmark") {
                    submit(["color": clockInk.wallHex, "match_art": false], receipt: "Clock colour saved.") { inkEditing = false }
                }
            }
            if wall.state.mode != "clock" {
                action(activeTimer ? "End timer & show clock" : "Show clock", symbol: "clock") {
                    submit(activeTimer ? ["timer_min": 0.0, "mode": "clock"] : ["mode": "clock"], receipt: "Clock is on the wall.")
                }
            }
            wallZoneCaption
        }
    }

    private func clockFormat(_ title: String, example: String, value: Bool) -> some View {
        Button { submit(["clock_24h": value], receipt: "\(title) clock saved.") } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(title).font(.ui(14, .medium)); Spacer(minLength: 6)
                    Image(systemName: wall.state.clock24h == value ? "checkmark.circle.fill" : "circle")
                }
                Text(example).font(.machine(typeSize.isAccessibilitySize ? 13 : 16)).monospacedDigit()
            }.foregroundStyle(wall.state.clock24h == value ? ink : Ink.dim)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.sunk, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(wall.state.clock24h == value ? ink.opacity(0.6) : Ink.hairline, lineWidth: 1))
        }.buttonStyle(PressStyle()).disabled(busy || !ready).accessibilityAddTraits(wall.state.clock24h == value ? .isSelected : [])
    }

    @ViewBuilder private var timerControls: some View {
        if activeTimer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = wall.state.timerSeconds(at: ready ? context.date : wall.state.routineReceivedAt) ?? 0
                VStack(alignment: .leading, spacing: 18) {
                    if ringing {
                        completionControls
                    } else {
                        sectionTitle(wall.state.timerSnoozed ? "Five more minutes." : "A little time, set aside.",
                                     subtitle: wall.state.timerSnoozed ? "Your alarm will return when the light reaches zero." : "Keeps counting while you leave the app.")
                        Text(TimeInput.clock(remaining)).font(.display(typeSize.isAccessibilitySize ? 26 : 46)).monospacedDigit().foregroundStyle(ink)
                            .contentTransition(.numericText(countsDown: true))
                            .accessibilityLabel(TimeInput.duration(remaining) + " remaining")
                        action(wall.state.timerSnoozed ? "Cancel snooze" : "Cancel timer", symbol: "stop.fill") {
                            stopTimer(receipt: wall.state.timerSnoozed ? "Snooze cancelled. Your daily schedule is unchanged." : "Timer cancelled.")
                        }
                        if let total = wall.state.timerTotal, total > 0 {
                            ProgressView(value: Double(remaining), total: Double(total)).tint(ink)
                                .accessibilityLabel("Timer remaining").accessibilityValue(TimeInput.duration(remaining))
                            if ready, let end = wall.state.timerEndsAt, let zone {
                                Text("\(wall.state.timerSnoozed ? "Alarm returns" : "Finishes") at \(wallDate(end, zone: zone, includeDay: false))")
                                    .font(.ui(13)).foregroundStyle(Ink.dim)
                            }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("Set a little time aside.", subtitle: "A countdown, followed by a light on the wall.")
                let durationLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                durationLayout {
                    durationField("Minutes", text: $minutes)
                    if !typeSize.isAccessibilitySize { Text(":").font(.display(34)).padding(.top, 10).foregroundStyle(Ink.dim) }
                    durationField("Seconds", text: $seconds)
                }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach([5, 10, 25, 45], id: \.self) { value in
                        Button { minutes = String(value); seconds = "00"; durationFocused = false; receipt = nil; Taps.detent() } label: {
                            Text("\(value) min").font(.ui(13, .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(draftSeconds == value * 60 ? Ink.ground : Ink.ink)
                                .background(draftSeconds == value * 60 ? ink : Ink.sunk, in: RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(PressStyle()).accessibilityAddTraits(draftSeconds == value * 60 ? .isSelected : [])
                    }
                }
                if draftSeconds == nil {
                    Text("Choose 6 seconds to 180 minutes. Seconds run from 00 to 59.").font(.ui(12)).foregroundStyle(Ink.signal)
                }
                action("Start timer", symbol: "play.fill", enabled: draftSeconds != nil) {
                    guard let duration = draftSeconds else { return }; durationFocused = false
                    submit(["timer_min": Double(duration) / 60], receipt: "Timer started on the wall.")
                }
            }
        }
    }

    private var completionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(wall.state.timerKind == "alarm" ? "Your alarm is here." : "\(TimeInput.duration(wall.state.timerTotal ?? 0)), all yours.")
                    .font(.ui(typeSize.isAccessibilitySize ? 16 : 18, .semibold)).foregroundStyle(Ink.ink)
                Text(wall.state.timerKind == "alarm" ? "Take five more minutes, or return to your wall." : "Go again, or let the wall return to what it was showing.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            action(wall.state.timerKind == "alarm" ? "Stop alarm" : "Done", symbol: "checkmark") {
                stopTimer(receipt: wall.state.timerKind == "alarm" ? "Alarm stopped. Your daily schedule is unchanged." : "Timer complete. Your wall is back.")
            }
            if wall.state.timerEventID != nil {
                let alarm = wall.state.timerKind == "alarm"
                secondaryAction(alarm ? "Snooze for 5 minutes" : "Repeat \(TimeInput.duration(wall.state.timerTotal ?? 0))", symbol: alarm ? "zzz" : "arrow.counterclockwise") {
                    guard let event = wall.state.timerEventID else { return }
                    submit(["timer_action": alarm ? "snooze" : "repeat", "timer_id": event],
                           receipt: alarm ? "Alarm snoozed for 5 minutes." : "A fresh timer, with the same duration.")
                }
            }
            Text("The light settles after 3 minutes if left alone.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("time.completion")
    }

    private func stopTimer(receipt: String) {
        let patch: [String: Any] = wall.state.timerEventID.map { ["timer_action": "stop", "timer_id": $0] } ?? ["timer_min": 0.0]
        submit(patch, receipt: receipt)
    }

    private func secondaryAction(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.ui(15, .semibold))
                .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(ink).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.35), lineWidth: 1))
        }.buttonStyle(PressStyle()).disabled(busy || !ready).opacity(!ready ? 0.5 : 1)
    }

    private func durationField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(label, text: text).keyboardType(.numberPad).focused($durationFocused)
                .font(.machine(typeSize.isAccessibilitySize ? 22 : 30)).monospacedDigit()
                .foregroundStyle(Ink.ink).padding(.horizontal, 16).frame(minHeight: 64)
                .background(Ink.sunk, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
                .accessibilityLabel("Timer \(label.lowercased())").disabled(busy)
            Text(label).font(.ui(12)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity)
    }

    private var alarmControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("A light for your daily cue.", subtitle: "A visual alarm on the wall, every day at the time you choose.")
            Toggle(isOn: Binding(get: { alarmEnabled }, set: { alarmEnabled = $0; alarmEditing = true; receipt = nil })) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Daily alarm").font(.ui(16, .semibold))
                    Text(alarmEnabled ? "Enabled" : "Off").font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }.tint(ink).foregroundStyle(Ink.ink).frame(minHeight: 48).disabled(busy)
            DatePicker("Alarm time on the wall", selection: Binding(get: { alarmDate }, set: { alarmDate = $0; alarmEditing = true; receipt = nil }), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden()
                .environment(\.timeZone, TimeInput.editorZone)
                .environment(\.locale, Locale(identifier: wall.state.clock24h ? "en_GB" : "en_US"))
                .frame(maxWidth: .infinity).tint(ink)
                .background(Ink.sunk, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Alarm time on the wall").disabled(busy)
            wallZoneCaption
            if alarmDirty {
                Text("Your changes are ready to save.").font(.ui(13)).foregroundStyle(Ink.dim)
                action("Save alarm", symbol: "checkmark") {
                    submit(["alarm_time": TimeInput.civilTime(alarmDate), "alarm_enabled": alarmEnabled],
                           receipt: alarmEnabled ? "Daily alarm saved for \(TimeInput.timeLabel(TimeInput.civilTime(alarmDate), twentyFour: wall.state.clock24h))." : "Alarm turned off.") { alarmEditing = false }
                }
            } else if wall.state.alarmEnabled {
                Label("Every day at \(TimeInput.timeLabel(wall.state.alarmTime, twentyFour: wall.state.clock24h))", systemImage: "repeat")
                    .font(.ui(14, .medium)).foregroundStyle(ink)
                if let next = wall.state.alarmNext, let zone {
                    Text("Next: \(wallDate(next, zone: zone, includeDay: true))")
                        .font(.ui(13)).foregroundStyle(Ink.dim)
                }
            }
        }
    }

    private var wallZoneCaption: some View {
        Label(zone.map { "Wall time · \($0.identifier.replacingOccurrences(of: "_", with: " "))" } ?? "Uses the wall’s local time.", systemImage: "globe")
            .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.displayMid(typeSize.isAccessibilitySize ? 18 : 22)).foregroundStyle(Ink.ink)
            Text(subtitle).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func action(_ title: String, symbol: String, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(Ink.ground) }
                else { Image(systemName: symbol) }
                Text(busy ? "Saving to the wall…" : title).font(.ui(16, .semibold))
            }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(Ink.ground).background(ink, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(PressStyle()).disabled(!enabled || busy || !ready).opacity(!enabled || !ready ? 0.5 : 1)
    }

    private func submit(_ patch: [String: Any], receipt message: String, accepted: @escaping () -> Void = {}) {
        guard !busy, ready else { return }
        busy = true; problem = nil; receipt = nil
        let host = wall.host
        Task { @MainActor in
            let saved = await wall.updateRoutine(patch)
            busy = false
            guard wall.host == host else { return }
            if saved { accepted(); receipt = message; Taps.commit() }
            else { problem = "The wall didn’t confirm this change. Your edits are still here; try saving again."; Taps.error() }
        }
    }

    private func wallDate(_ date: Date, zone: TimeZone, includeDay: Bool) -> String {
        var format = Date.FormatStyle().hour().minute()
        if includeDay { format = format.weekday(.wide) }
        format.timeZone = zone
        return date.formatted(format)
    }

    private func syncAlarm() {
        alarmDate = TimeInput.date(wall.state.alarmTime); alarmEnabled = wall.state.alarmEnabled
    }

    private func watchPreview() async {
        preview = nil; previewFailed = false
        guard initialized, showsPreview, !useLiveFrame, ready, scenePhase == .active, previewFace != "timer" || draftSeconds != nil else { return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let key = previewKey
        repeat {
            let duration = draftSeconds.map(Double.init)
            let data = await wall.routinePreview(face: previewFace, twentyFour: wall.state.clock24h,
                                                remaining: previewFace == "timer" ? duration : nil,
                                                total: previewFace == "timer" ? duration : nil)
            guard !Task.isCancelled, key == previewKey else { return }
            preview = data.flatMap { FinishSwatch.bitmap([UInt8]($0)) }
            previewFailed = preview == nil
            if previewFace == "timer" { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        } while !Task.isCancelled
    }
}

/// The iPod's compact wheel links here once; it does not maintain a second set
/// of timer presets or a separate format menu with different capabilities.
struct TimePage: View {
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    var initialTab: TimeWorkbench.Tab? = nil
    var body: some View {
        NavigationStack {
            ScrollView { TimeWorkbench(accent: accent, initialTab: initialTab).padding(24) }
                .background(Ink.ground).navigationTitle("Time & alarms").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
    }
}
