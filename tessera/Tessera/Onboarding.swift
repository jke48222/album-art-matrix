// The first run, and the dev switch that plays it again.
//
// One question per screen, the wall shown before anything is asked, every
// step skippable and every answer changeable later in Settings. The steps
// are real: finding the wall is the wall's own discovery, the glow really
// puts white on the panels, the connections are the same calls Settings
// makes. Nothing is invented for the tour.

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, find, found, glow, noWall, services, light, done
}

struct OnboardingFlow: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false

    @State private var step: OnboardingStep = .welcome
    @State private var searching = false
    @State private var searchedFor: Int = 0
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var services: WallServices? = nil
    @State private var musicRefused = Service.appleMusicRefused
    @State private var showServices = false
    @State private var brightness: Double = 0.8
    @State private var sun = false
    @State private var where0 = OneShotSpot()

    private let accent = Ink.tile

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                if step != .welcome && step != .done { progress }
                content
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                    .id(step)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .animation(Motion.scene, value: step)
        .task { services = await WallServices.seeded(host: wall.host) }
        .sheet(isPresented: $showServices, onDismiss: {
            Task { services = await WallServices.read(host: wall.host) }
        }) {
            NavigationStack {
                ServicesPage(accent: accent, services: $services,
                             musicConnected: $musicConnected, musicRefused: $musicRefused)
            }
            .environment(wall)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .find: find
        case .found: found
        case .glow: glow
        case .noWall: noWall
        case .services: servicesStep
        case .light: lightStep
        case .done: finish
        }
    }

    private var stepIndex: (Int, String) {
        switch step {
        case .find, .found, .glow, .noWall: (1, "The wall")
        case .services: (2, "Music")
        case .light: (3, "Light")
        default: (4, "Done")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("STEP \(stepIndex.0) OF 4 · \(stepIndex.1.uppercased())")
                    .font(.machine(10)).kerning(1.2).foregroundStyle(Ink.dim)
                Spacer()
                if step != .find && step != .glow {
                    Button("Skip") { advance(skip: true) }
                        .buttonStyle(PressStyle(scale: 0.96))
                        .font(.ui(14, .semibold)).foregroundStyle(Ink.dim)
                }
            }
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i <= stepIndex.0 ? Ink.ink : Ink.hairline)
                        .frame(height: 3)
                }
            }
        }
        .padding(.top, 6)
    }

    private func headline(_ h: String, _ p: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(h).font(.display(30)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(p).font(.ui(16)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
    }

    private var wallPicture: some View {
        PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 1
    private var welcome: some View {
        VStack(spacing: 0) {
            HStack { Text("TESSERA").font(.display(13)).kerning(3).foregroundStyle(Ink.dim); Spacer() }
                .padding(.top, 8)
            Spacer()
            wallPicture.frame(width: 300, height: 300)
            Spacer()
            headline("Your music, on the wall.", "A wall of 4,096 lights that shows the sleeve of whatever you are playing.")
                .padding(.top, 0)
            PrimaryButton(title: "Get started", accent: accent) { step = .find; startSearch() }
                .padding(.top, 28)
            Text("No account. Nothing leaves your home network.")
                .font(.ui(12)).foregroundStyle(Ink.faint).padding(.top, 12)
        }
    }

    // 2
    private var find: some View {
        VStack(spacing: 0) {
            headline("Looking for your wall", "Plug it in and stay on your home wifi. Tessera finds it by name, usually within a few seconds.")
            Spacer()
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle().strokeBorder(Ink.ink.opacity(0.5 - 0.14 * Double(i)), lineWidth: 1.5)
                        .frame(width: 108 + CGFloat(i) * 72, height: 108 + CGFloat(i) * 72)
                        .scaleEffect(searching ? 1.06 : 0.94)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: searching)
                }
                PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 0.35).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 300)
            Spacer()
            if searchedFor >= 8 {
                Button("I don't have a wall yet") { step = .noWall }
                    .buttonStyle(PressStyle(scale: 0.97)).font(.ui(15, .semibold)).foregroundStyle(Ink.dim)
                    .frame(height: 46)
            } else {
                Text("Looking").font(.ui(15, .semibold)).foregroundStyle(Ink.faint).frame(height: 46)
            }
        }
        .onChange(of: wall.link.isLive) { _, live in if live { step = .found } }
        .task {
            searchedFor = 0
            while step == .find && searchedFor < 60 {
                try? await Task.sleep(for: .seconds(1))
                searchedFor += 1
                if wall.link.isLive { step = .found; break }
            }
        }
    }

    private func startSearch() {
        searching = true
        wall.lookForWallAgain()
    }

    // 3
    private var found: some View {
        VStack(spacing: 0) {
            headline("Found it", "One wall is answering on your network.")
            Spacer()
            VStack(spacing: 16) {
                wallPicture.frame(width: 200, height: 200)
                VStack(spacing: 6) {
                    Text("Album wall").font(.display(22)).foregroundStyle(Ink.ink)
                    HStack(spacing: 8) {
                        Circle().fill(Ink.moss).frame(width: 8, height: 8)
                        Text("\(wall.host) · answering").font(.ui(13)).foregroundStyle(Ink.dim)
                    }
                }
            }
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(Ink.plaster)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
            PrimaryButton(title: "This is it", accent: accent) {
                wall.pushFlat(r: 255, g: 255, b: 255)
                step = .glow
            }
            Button("Not this one, look again") { step = .find; startSearch() }
                .buttonStyle(PressStyle(scale: 0.97)).font(.ui(15, .semibold)).foregroundStyle(Ink.dim)
                .frame(height: 46)
        }
    }

    // 4
    private var glow: some View {
        VStack(spacing: 0) {
            headline("Did the wall just glow?", "It is showing a soft white for five seconds, so you know this phone is talking to that wall and not a neighbour's.")
            Spacer()
            PanelCanvas(px: [UInt8](repeating: 234, count: 64 * 64 * 3), duty: 1)
                .frame(width: 240, height: 240).clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer()
            PrimaryButton(title: "Yes, that's mine", accent: accent) {
                wall.send(["mode": "art"])
                step = .services
            }
            Button("No, nothing happened") {
                wall.send(["mode": "art"])
                step = .find; startSearch()
            }
            .buttonStyle(PressStyle(scale: 0.97)).font(.ui(15, .semibold)).foregroundStyle(Ink.dim)
            .frame(height: 46)
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            if step == .glow { wall.send(["mode": "art"]) }
        }
    }

    // 3b
    private var noWall: some View {
        VStack(spacing: 0) {
            headline("No wall yet? Try it on your phone.", "Tessera runs a stand-in wall on this phone. Everything works and nothing lights up in the room until a real wall answers.")
            Spacer()
            VStack(spacing: 14) {
                wallPicture.frame(width: 200, height: 200)
                Text("STAND-IN").font(.machine(10)).kerning(1.2).foregroundStyle(Ink.dim)
            }
            Spacer()
            PrimaryButton(title: "Continue with the stand-in", accent: Ink.ink) { step = .services }
            Button("Look for a wall again") { step = .find; startSearch() }
                .buttonStyle(PressStyle(scale: 0.97)).font(.ui(15, .semibold)).foregroundStyle(Ink.dim)
                .frame(height: 46)
        }
    }

    // 5
    private var servicesStep: some View {
        VStack(spacing: 0) {
            headline("What do you play from?", "Apple Music is read on this phone. Everything else is read by the wall, so it works from any device, and is set up from here.")
            VStack(spacing: 0) {
                SetupRow(title: "Apple Music", subtitle: "Reads only what is playing. Never your library.",
                         leading: { ServiceMark(service: .appleMusic, side: 44) }) {
                    if musicConnected { Done(text: "Connected") } else {
                        ActionPill(title: "Connect") {
                            StandIn.requestMusicAccess { [weak wall] in
                                wall?.push.restart()
                                musicConnected = Service.appleMusicAuthorized
                            }
                        }
                    }
                }
                Rule()
                SetupRow(title: "Spotify, Last.fm and the rest", subtitle: restLine,
                         leading: { ServiceMark(service: .spotify, side: 44) }) {
                    ActionPill(title: "Set up") { showServices = true }
                }
                Rule()
            }
            .padding(.top, 22)
            Text("Read by the wall, set up from this phone, no computer. SoundCloud, YouTube Music and Amazon Music reach the wall out loud, through its ears, or through a Mac.")
                .font(.ui(12)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Spacer()
            PrimaryButton(title: "Continue", accent: accent) { step = .light }
            Button("Skip for now") { step = .light }
                .buttonStyle(PressStyle(scale: 0.97)).font(.ui(15, .semibold)).foregroundStyle(Ink.dim)
                .frame(height: 46)
        }
    }

    private var restLine: String {
        var on: [String] = []
        if services?.spotify.linked == true { on.append("Spotify") }
        if let u = services?.lastfm.user, !u.isEmpty { on.append("Last.fm") }
        if let u = services?.listenbrainz?.user, !u.isEmpty { on.append("ListenBrainz") }
        return on.isEmpty ? "Any device. A couple of minutes each." : on.joined(separator: ", ") + " connected."
    }

    // 6
    private var lightStep: some View {
        VStack(spacing: 0) {
            headline("How bright?", "Drag and the wall follows live. Most rooms sit around eighty percent.")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Brightness").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(Int(brightness * 100))%").font(.machine(13)).foregroundStyle(Ink.dim)
                }
                Slider(value: $brightness, in: 0.05...1.0, step: 0.05) { editing in
                    if !editing { wall.send(["brightness": brightness]) }
                }
                .tint(accent)
            }
            .padding(.top, 34)
            Rule().padding(.top, 22)
            ToggleRow(title: "Follow the sun",
                      subtitle: "Dims after sunset, back at sunrise. Uses your location once.",
                      isOn: Binding(get: { sun }, set: { on in
                          sun = on
                          wall.send(["sun": on ? "on" : "off"])
                          if on { where0.fetch { lat, lon in wall.send(["lat": lat, "lon": lon]) } }
                      }), accent: accent)
                .padding(.horizontal, -16)
            Rule()
            Spacer()
            PrimaryButton(title: "Continue", accent: accent) { step = .done }
        }
        .onAppear { brightness = wall.state.brightness; sun = wall.state.sun == "on" }
    }

    // 7
    private var finish: some View {
        VStack(spacing: 0) {
            HStack { Text("STEP 4 OF 4 · DONE").font(.machine(10)).kerning(1.2).foregroundStyle(Ink.dim); Spacer() }
                .padding(.top, 14)
            HStack(spacing: 6) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(Ink.ink).frame(height: 3) } }
                .padding(.top, 14)
            wallPicture.frame(width: 190, height: 190).padding(.top, 22)
            headline("First light.", "Tessera is set up. Everything here can be changed later in Settings.")
                .padding(.top, 26)
            VStack(spacing: 0) {
                check(wall.link.isLive ? "Album wall" : "Stand-in wall", wall.link.isLive ? "connected" : "on this phone")
                check("Apple Music", musicConnected ? "connected" : "skipped")
                check("Spotify", services?.spotify.linked == true ? "connected" : "skipped")
            }
            .padding(.top, 22)
            Spacer()
            PrimaryButton(title: "Open the wall", accent: accent) {
                onboarded = true
                dismiss()
            }
        }
    }

    private func check(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(value == "skipped" ? Ink.faint : Ink.moss)
                    Image(systemName: value == "skipped" ? "minus" : "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.ground)
                }
                .frame(width: 22, height: 22)
                Text(label).font(.ui(15)).foregroundStyle(Ink.ink)
                Spacer()
                Text(value).font(.ui(13)).foregroundStyle(Ink.dim)
            }
            .padding(.vertical, 12)
            Rule().padding(.leading, -16)
        }
    }

    private func advance(skip: Bool) {
        switch step {
        case .found, .noWall: step = .services
        case .services: step = .light
        case .light: step = .done
        default: step = .services
        }
    }
}
