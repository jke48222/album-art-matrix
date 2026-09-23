import SwiftUI

/// The single home for automatic quiet-room behaviour. Its diagram is a plan;
/// the separate wall receipt displays received RGB pixels, never a mock scene.
struct IdlePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    @State private var saving: String?
    @State private var problem: String?
    private let sage = Color(hex: 0xCDD4B4)
    private var selected: IdlePolicy { .current(wall.state.idle) }
    private var ready: Bool { wall.link.isLive && saving == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("THE QUIETER MOMENTS").font(.machine(10)).tracking(1.1).foregroundStyle(sage)
                    Text("Between songs.").font(.display(typeSize.isAccessibilitySize ? 28 : 38)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Give the room its own rhythm, even when the music stops.")
                        .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
                if !wall.link.isLive {
                    Label(wall.link.isStandIn ? "Phone preview · connect a wall to save changes" : "Wall offline · showing the last received settings", systemImage: "wifi.slash")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.ui(14)).foregroundStyle(Color(hex: 0xF0BB98)).fixedSize(horizontal: false, vertical: true)
                }
                behaviorPlan
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("After the music").font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
                        Spacer(minLength: 6)
                        if saving == "idle" { ProgressView().tint(sage) }
                    }
                    Text("After one minute of quiet on Cover or Spin. The next song brings your music face back.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        ForEach(IdlePolicy.allCases) { policy in policyRow(policy) }
                    }
                    if selected == .weather && !hasLocation {
                        Label("Set a location in Weather or Follow the sun. Until weather is available, the wall keeps the last cover.", systemImage: "location")
                            .font(.ui(13)).foregroundStyle(sage).fixedSize(horizontal: false, vertical: true)
                    }
                }
                awaySection
                WallRestWorkbench(accent: sage)
                RestWallReceipt(tint: sage)
            }.padding(.horizontal, 22).padding(.bottom, 40)
        }.scrollIndicators(.hidden).background(Ink.ground).tint(sage)
            .navigationTitle("Quiet moments").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var hasLocation: Bool {
        wall.state.lat.isFinite && wall.state.lon.isFinite && abs(wall.state.lat) <= 90 && abs(wall.state.lon) <= 180
    }

    private var behaviorPlan: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("YOUR QUIET-ROOM PLAN").font(.machine(9)).tracking(0.7)
                Spacer()
                Image(systemName: "waveform.path").font(.system(size: 15))
            }.foregroundStyle(sage)
            QuietContour().frame(height: 72).foregroundStyle(sage).accessibilityHidden(true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                planStep("01", "Music stops", "Cover or Spin")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                planStep("02", "A minute passes", "A little breathing room")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                planStep("03", selected.shortTitle, "Your chosen ending")
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x191D19), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(sage.opacity(0.13)))
            .accessibilityElement(children: .combine)
    }

    private func planStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number).font(.machine(10)).foregroundStyle(sage.opacity(0.65))
            Text(title).font(.ui(13, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.ui(11)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func policyRow(_ policy: IdlePolicy) -> some View {
        let active = selected == policy
        return Button { save("idle", value: policy.rawValue) } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: policy.symbol).font(.system(size: 22, weight: .light))
                    .foregroundStyle(active ? sage : Ink.dim)
                    .frame(width: 48, height: 52)
                    .background(active ? sage.opacity(0.10) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(policy.title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Text(policy.detail).font(.ui(13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(active ? sage : Ink.faint)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? sage.opacity(0.065) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(active ? sage.opacity(0.6) : Color.white.opacity(0.055)))
        }.buttonStyle(PressStyle(scale: 0.99)).disabled(!ready)
            .accessibilityElement(children: .combine).accessibilityAddTraits(active ? [.isSelected] : [])
            .accessibilityHint(active ? "Current quiet-room behavior" : "Use after one minute without music")
    }

    private var awaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "door.left.hand.open").font(.system(size: 20, weight: .light)).foregroundStyle(sage)
                Text("When you’re away").font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                if saving == "away" { ProgressView().tint(sage) }
            }
            Text("If the app and phone reporter are quiet for 15 minutes, with no music playing.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                awayRow("Keep the wall on", detail: "Continue your chosen face and quiet-room plan.", key: "stay")
                Divider().overlay(Ink.hairline).padding(.horizontal, 16)
                awayRow("Let the wall rest", detail: "Go dark, then resume when your phone or music returns.", key: "off")
            }.background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18))
            Text("Presence uses contact with your phone, not location tracking. Active timers, Sleep and Wake up keep running.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 6)
    }

    private func awayRow(_ title: String, detail: String, key: String) -> some View {
        let active = wall.state.away == key
        return Button { save("away", value: key) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text(detail).font(.ui(13)).foregroundStyle(Ink.dim)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(active ? sage : Ink.faint)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(PressStyle(scale: 0.99)).disabled(!ready)
            .accessibilityElement(children: .combine).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func save(_ key: String, value: String) {
        guard ready else { return }
        saving = key; problem = nil
        Task { @MainActor in
            let accepted = await wall.updateRoutine([key: value])
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { saving = nil }
            if accepted { Taps.commit() }
            else { problem = "That change didn’t reach the wall. Your saved plan is still shown. Reconnect and try again." }
        }
    }
}

/// Shared explicit-Off control, inline in Settings and the Off workspace.
/// A song resuming alone never reverses this command; schedules still can.
struct WallRestWorkbench: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    var ink: GlassInk = .dark
    @State private var saving = false
    @State private var problem: String?
    private var off: Bool { wall.state.mode == "off" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: off ? "moon.zzz" : "power").font(.system(size: 22, weight: .light)).foregroundStyle(accent)
                Text(off ? "The wall is resting" : "A moment of darkness").font(.ui(18, .semibold)).foregroundStyle(ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(off ? "Music won’t turn it on by itself. Choose a face, or let your next Alarm or Wake up begin." : "Switch off now. It stays off until you choose a face or a scheduled Alarm or Wake up begins.")
                .font(.ui(14)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
            Button { setPower() } label: {
                HStack(spacing: 9) {
                    if saving { ProgressView().tint(ink.ink) }
                    else { Image(systemName: off ? "play.fill" : "power") }
                    Text(saving ? "Sending…" : off ? "Return to music" : "Turn the wall off")
                        .font(.ui(15, .semibold)).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(ink.ink).padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(accent.opacity(0.35)))
            }.buttonStyle(PressStyle()).disabled(!wall.link.isLive || saving)
                .opacity(wall.link.isLive ? 1 : 0.5)
            if let problem { Text(problem).font(.ui(13)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 8)
    }

    private func setPower() {
        guard wall.link.isLive, !saving else { return }
        let waking = off
        saving = true; problem = nil
        Task { @MainActor in
            let accepted = await wall.updateRoutine(waking ? ["mode": "art", "resume_music": true] : ["mode": "off"])
            saving = false
            if accepted { Taps.commit() }
            else { problem = "The wall didn’t receive that command. Reconnect and try again." }
        }
    }
}

private struct QuietContour: View {
    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            for index in 0..<63 {
                let x = size.width * CGFloat(index) / 62
                let phase = Double(index) / 62
                let envelope = pow(max(0, 1 - phase), 1.7)
                let amplitude = (5 + abs(sin(Double(index) * 1.7)) * 25) * envelope
                var path = Path()
                path.move(to: CGPoint(x: x, y: center - amplitude))
                path.addLine(to: CGPoint(x: x, y: center + amplitude))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}

private struct RestWallReceipt: View {
    @Environment(WallSession.self) private var wall
    let tint: Color
    private var detail: String {
        if wall.state.mode == "off" { return "Off by choice. Your schedules are still saved." }
        if wall.state.awayActive { return "Resting while your phone is away." }
        if let raw = wall.state.idleActive, let policy = IdlePolicy(rawValue: raw) { return policy.title + " · your quiet-room plan is active." }
        return "Your current face is on the wall. The plan waits for a quiet moment."
    }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Color.black
                if wall.state.mode != "off", wall.state.displayedMode != "off",
                   let data = wall.frame, let bitmap = FinishSwatch.bitmap([UInt8](data)) {
                    Image(uiImage: bitmap).resizable().interpolation(.none).scaledToFit()
                }
            }.frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(wall.link.isLive ? "LIVE WALL" : wall.link.isStandIn ? "PHONE PREVIEW" : "LAST RECEIVED WALL")
                    .font(.machine(9)).tracking(0.7).foregroundStyle(tint)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.top, 22).overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }
}
