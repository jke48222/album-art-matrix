import SwiftUI
import UIKit

/// First run introduces the object, then its three decisions. Connection setup
/// remains in Services, the same destination used throughout the app.
struct OnboardingFlow: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarded") private var onboarded = false

    @State private var journey = OnboardingJourney(step: Self.captureStep ?? .welcome)
    @State private var services: WallServices?
    @State private var musicConnected = Service.appleMusicAuthorized
    @State private var musicRefused = Service.appleMusicRefused
    @State private var showServices = false
    @State private var networkHelp = false
    @State private var brightness = 0.8
    @State private var sun = false
    @State private var where0 = OneShotSpot()
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var glowActive = false
    /// The search was running when the app left, usually for iPhone Settings.
    @State private var resumeSearch = false
    /// "Try it on this phone" while a search still runs. The search is left
    /// to finish, and if it ends with the wall away the phone takes over,
    /// as the owner chose.
    @State private var wantsPhone = false
    /// The owner said the glow did not show, so Found offers network help.
    @State private var unseen = false
    /// Stays true for a few seconds after the wall stops answering, so one
    /// missed poll does not swap the no-wall buttons under a finger.
    @State private var recentlyLive = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var temporary = TemporaryWallDisplay()
    @AccessibilityFocusState private var titleFocused: Bool
    /// Arrows beside button labels grow with the label's text size.
    @ScaledMetric(relativeTo: .body) private var arrowSize: CGFloat = 16

    private let amber = Color(hex: 0xF1C889)
    private let room = Color(hex: 0x24211C)
    private var step: OnboardingStep { journey.step }
    private var accessible: Bool { typeSize.isAccessibilitySize }
    private var canEditLight: Bool { wall.link.isLive || wall.link.isStandIn }
    private var waiting: Bool { busy || where0.busy }
    private var captured: Bool { Self.captureStep != nil }
    /// The no-wall screen's connected variant. A stand-in (automatic or
    /// chosen) never counts, because a dropped wall goes offline, not there.
    private var wallAnswering: Bool { wall.link.isLive || (recentlyLive && !wall.link.isStandIn) }
    private static var captureStep: OnboardingStep? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-onboarding-step"), i + 1 < args.count else { return nil }
        return OnboardingStep(rawValue: args[i + 1])
        #else
        return nil
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: accessible ? 22 : 26) {
                    header
                    // Right under the heading: at the end of the content a
                    // problem sat under the pinned footer, so a refused glow
                    // looked like nothing had happened.
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.ui(14)).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding.problem")
                    }
                    if let notice {
                        Text(notice).font(.ui(14)).foregroundStyle(amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding.notice")
                    }
                    content
                    if accessible && hasSecondaryActions {
                        VStack(spacing: 12) { secondaryActions }.frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 620, minHeight: proxy.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            // Shown briefly on each step, so a page that runs under the
            // pinned footer says it scrolls.
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollIndicatorsFlash(trigger: step)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Rectangle().fill(Ink.hairline).frame(height: 1)
                VStack(spacing: 12) {
                    footer
                    if !accessible { secondaryActions }
                }.padding(.horizontal, 24)
            }
            .padding(.bottom, 12)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .background(Ink.ground)
        }
        .background(Ink.ground.ignoresSafeArea()).preferredColorScheme(.dark)
        .tint(amber)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
        .task {
            brightness = wall.state.brightness
            sun = wall.state.sun == "on"
        }
        .task(id: wall.link.isLive) {
            if wall.link.isLive {
                recentlyLive = true
                // First launch starts in the stand-in, so services are read
                // when the wall is in reach, not only once on appear.
                if step == .noWall { problem = nil }
                await refreshServices()
                return
            }
            // One missed poll is not a lost wall. Leave Found or Glow, and
            // drop the no-wall screen's connected variant, only if the wall
            // is still silent a few seconds later.
            guard recentlyLive || [.found, .glow].contains(step) else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !wall.link.isLive else { return }
            recentlyLive = false
            guard [.found, .glow].contains(step), !captured else { return }
            cancelOperation(); stopGlow(); journey.move(to: .noWall)
            problem = "The wall stopped answering. Check its power and Wi-Fi, then try again."
        }
        .task(id: journey.searchID) {
            guard let id = journey.searchID, !captured else { return }
            while !Task.isCancelled {
                if wall.link.isLive { _ = journey.foundWall(for: id); return }
                if journey.expireSearch(for: id) { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
        }
        .onChange(of: step) { _, next in
            titleFocused = true
            if next != .found { unseen = false }
            if next == .light { brightness = wall.state.brightness; sun = wall.state.sun == "on" }
        }
        .onChange(of: wall.link) { _, next in
            guard wantsPhone else { return }
            switch next {
            case .searching: return
            case .offline:
                // The search the owner let run ended with the wall away.
                // Keep their choice of this phone, so Brightness works and
                // Done does not say it is waiting for the wall.
                wantsPhone = false
                if [.services, .light, .done].contains(step) { chooseStandIn() }
            case .live, .standIn: wantsPhone = false
            }
        }
        .onChange(of: scene) { _, next in
            if next == .active {
                musicConnected = Service.appleMusicAuthorized
                musicRefused = Service.appleMusicRefused
                if resumeSearch {
                    resumeSearch = false
                    if step == .noWall { startSearch() }
                } else if step == .find, !captured { startSearch() }
            } else if next == .background {
                cancelOperation()
                where0.cancel()
                if glowActive { stopGlow() }
                if step == .find { resumeSearch = !captured; journey.move(to: .noWall) }
            }
        }
        .onChange(of: wall.host) { _, _ in
            cancelOperation(); services = nil
            if glowActive { stopGlow() }
            if [.found, .glow].contains(step) {
                journey.move(to: .noWall)
                problem = "The wall address changed. Find it again before continuing."
            }
        }
        // Messages appear below a tall stage, often under the fold, and focus
        // stays on the button that failed.
        .onChange(of: problem) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        .onChange(of: notice) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        .onChange(of: where0.problem) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        .onDisappear { cancelOperation(); where0.cancel(); stopGlow() }
        .sheet(isPresented: $showServices, onDismiss: {
            musicConnected = Service.appleMusicAuthorized
            musicRefused = Service.appleMusicRefused
            Task { await refreshServices() }
        }) {
            NavigationStack {
                ServicesPage(accent: amber, services: $services,
                             musicConnected: $musicConnected, musicRefused: $musicRefused)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showServices = false } } }
            }.environment(wall).preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Done is the end of setup, so it offers neither a way back nor
            // "Finish later". Open Tessera is its only exit.
            HStack(spacing: 12) {
                if step != .welcome && step != .done {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.foregroundStyle(Ink.ink).buttonStyle(.plain)
                        .accessibilityLabel("Back").accessibilityIdentifier("onboarding.back")
                }
                Text("TESSERA").font(.display(accessible ? 10 : 15)).tracking(accessible ? 1 : 3).foregroundStyle(amber)
                Spacer(minLength: 6)
                if step != .done {
                    Button(step == .welcome || accessible ? "Later" : "Finish later") { finishOnboarding() }
                        .font(.ui(13, .medium)).foregroundStyle(Ink.dim).frame(minHeight: 44)
                        .accessibilityLabel("Finish setup later").accessibilityIdentifier("onboarding.skip")
                }
            }.frame(minHeight: 44)
            if step != .welcome && step != .done {
                HStack(spacing: 10) {
                    ForEach(Array(["The wall", "Music", "Light"].enumerated()), id: \.offset) { index, title in
                        VStack(alignment: .leading, spacing: 8) {
                            Rectangle().fill(index <= step.section ? amber : Ink.hairline).frame(height: 2)
                            Text(title).font(.ui(11, .medium)).foregroundStyle(index == step.section ? Ink.ink : Ink.faint)
                        }.accessibilityHidden(true)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(step.section + 1) of 3, \(["The wall", "Music", "Light"][step.section])")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .find: discovery
        case .found: found
        case .glow: glow
        case .noWall: noWall
        case .services: music
        case .light: light
        case .done: done
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The display face is wide. Past accessibility2 a single word
            // ("Welcome", "Brightness") outgrows the column and splits by
            // letter, so the title stops growing there and wraps at words.
            Text(title).font(.display(accessible ? 28 : 40)).tracking(accessible ? 0 : -0.8)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                .accessibilityIdentifier("onboarding.title")
            Text(detail).font(.ui(16)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }

    private var welcome: some View {
        // Sized so the steps and the account line sit above the pinned
        // footer at the default text size. At accessibility sizes the steps
        // stack, because three columns are too narrow for whole words.
        let steps = accessible ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                               : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
        return VStack(alignment: .leading, spacing: 20) {
            heading("Welcome to Tessera", detail: "Tessera shows the music you play on your wall. Setup has three steps.")
            stage(illustrated: true)
            steps {
                miniDetail("01", "Find your wall")
                miniDetail("02", "Choose music")
                miniDetail("03", "Set the light")
            }
            Text("No Tessera account needed. Music and creative services connect only when you choose them.")
                .font(.ui(13)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func miniDetail(_ number: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.machine(11)).foregroundStyle(amber)
            Text(title).font(.ui(13, .medium)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Looking for your wall", detail: "Plug in your wall and join the same Wi-Fi. If iOS asks, allow Local Network access.")
            connectionDiagram(searching: true)
            HStack(spacing: 12) {
                ProgressView().tint(amber).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Searching").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                    Text("\(wall.host)").font(.ui(12)).foregroundStyle(Ink.dim).textSelection(.enabled)
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("onboarding.searching")
            networkSupport
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Wall found", detail: "Your wall is answering. Send a short white glow to check it is the right one.")
            stage(illustrated: false)
            identityRow(symbol: "checkmark.circle.fill", title: "Wall connected", detail: wall.host, color: Ink.moss)
            Text("The glow lasts five seconds. Then the wall goes back to what it was showing.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            // After "I didn't see it", another glow alone leads nowhere, so
            // the network and address help is offered here too.
            if unseen { networkSupport }
        }
    }

    private var glow: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Did your wall light up?", detail: "It shows plain white for five seconds, then goes back to what it was showing.")
            // The status comes before the preview so whether the glow is
            // still running is never under the pinned footer.
            identityRow(symbol: glowActive ? "lightbulb.fill" : "lightbulb", title: glowActive ? "Showing white on the wall" : "Glow finished", detail: glowActive ? "Ends after five seconds" : wall.host, color: amber)
            stage(illustrated: false, white: glowActive)
        }
    }

    private var noWall: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Reachable with a live wall (Explore on this phone, a replayed
            // first run, a wall that answers again), so it must not claim
            // the wall is missing. Debounced, see wallAnswering.
            if wallAnswering {
                heading("Wall connected", detail: "Your wall is connected. You can still try Tessera on this phone only.")
                stage(illustrated: false)
                // The choice lives in memory only. The next launch looks for
                // the wall again, so the copy names both ways back.
                Text("If you use this phone only, Tessera stops talking to the wall until you look for it again in Settings under Connection, or until you close and reopen the app.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                heading("No wall connected", detail: "Tessera is not connected to your wall. You can try it on this phone, or check the wall and look again.")
                connectionDiagram(searching: false)
                identityRow(symbol: "iphone", title: "Use this phone for now", detail: "Try artwork, colour and drawing on a preview wall. Connections that need the wall can be set up later.", color: amber)
                networkSupport
            }
        }
    }

    private var networkSupport: some View {
        DisclosureGroup(isExpanded: $networkHelp) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Keep the wall powered on and connect this phone to the same Wi-Fi. Guest networks may prevent devices from finding each other.")
                Text("In iPhone Settings, allow Tessera access to the Local Network. If you use a custom wall address, you can change it later in Settings under Connection.")
                Button("Open iPhone Settings", action: openSettings)
                    .font(.ui(14, .semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding.networkSettings")
            }.font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        } label: {
            Label("Help finding your wall", systemImage: "wifi").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                .frame(minHeight: 44)
        }.tint(amber).accessibilityIdentifier("onboarding.networkHelp")
    }

    private var music: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Music", detail: "Choose where Tessera learns what you are playing. You can add more sources later.")
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    ServiceMark(service: .appleMusic, side: 52)
                    ServiceMark(service: .spotify, side: 52)
                    ServiceMark(service: .lastfm, side: 52)
                    Spacer(minLength: 0)
                }.accessibilityHidden(true)
                Text("Apple Music can report from this phone. Spotify and other sources connect through the wall or a reporter.")
                    .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Button { showServices = true } label: {
                    HStack(spacing: 14) {
                        Text("Choose connections").font(.ui(16, .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: arrowSize, weight: .semibold))
                    }.foregroundStyle(amber).frame(minHeight: 48)
                }.buttonStyle(PressStyle(scale: 0.98)).accessibilityIdentifier("onboarding.services")
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(room).clipShape(RoundedRectangle(cornerRadius: 24))
            // Sources already set up on the wall show here too, the same ones
            // Done lists, so an owner with Spotify linked sees it on this step.
            if musicConnected || musicRefused || !linkedMusic.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    if musicConnected {
                        identityRow(symbol: "checkmark.circle", title: "Apple Music access allowed", detail: "Playback is read from this phone.", color: Ink.moss)
                    } else if musicRefused {
                        identityRow(symbol: "hand.raised", title: "Music access is off", detail: "You can manage permission in Connections under Apple Music, or choose another source.", color: amber)
                    }
                    ForEach(linkedMusic, id: \.title) { source in
                        identityRow(symbol: "checkmark.circle", title: source.title, detail: source.detail, color: Ink.moss)
                    }
                }
            }
            if !wall.link.isLive {
                // A stand-in chosen over a live wall stops probing, so this
                // cannot promise the wall will connect by itself.
                Text("You can allow Apple Music now. Services that run on the wall need it connected. You can look for your wall again in Settings under Connection.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var light: some View {
        VStack(alignment: .leading, spacing: 22) {
            // No wall preview here: it pushed Follow the sun under the
            // pinned footer, and both controls matter more than the picture.
            heading("Brightness", detail: "Choose a comfortable brightness for this room. You can change it any time.")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Brightness").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(Int((brightness * 100).rounded()))%").font(.machine(25)).foregroundStyle(amber)
                        .contentTransition(.numericText())
                }
                Slider(value: $brightness, in: 0.05...1, step: 0.05, onEditingChanged: { editing in
                    if !editing { saveLight(["brightness": brightness], success: wall.link.isStandIn ? "Brightness updated on this phone." : "Brightness saved on the wall.") }
                }).disabled(!canEditLight || waiting).accessibilityLabel("Wall brightness")
                    .accessibilityValue("\(Int((brightness * 100).rounded())) percent")
                    .accessibilityIdentifier("onboarding.brightness")
                // Only the sun glyphs are decoration. The words say where
                // brightness applies, so VoiceOver (and the UI test) must
                // still find them.
                HStack {
                    Image(systemName: "sun.min").accessibilityHidden(true)
                    Spacer()
                    Text(wall.link.isStandIn ? "ON THIS PHONE" : "ROOM LIGHT").font(.machine(10))
                        .foregroundStyle(Ink.dim)
                    Spacer()
                    Image(systemName: "sun.max").accessibilityHidden(true)
                }.font(.system(size: 13)).foregroundStyle(Ink.faint)
            }.padding(20).background(room).clipShape(RoundedRectangle(cornerRadius: 20))
            Toggle(isOn: Binding(get: { sun }, set: setSun)) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Follow the sun").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Text("Softer after sunset. Uses your location once to set the wall’s schedule.")
                        .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }.tint(amber).disabled(!wall.link.isLive || waiting).accessibilityIdentifier("onboarding.sun")
            if where0.busy {
                Label("Finding your location", systemImage: "location").font(.ui(14)).foregroundStyle(amber)
            }
            if let error = where0.problem {
                Text(error).font(.ui(14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.locationProblem")
                if where0.permissionDenied {
                    Button("Open location settings", action: openSettings).font(.ui(14, .semibold)).frame(minHeight: 44)
                }
            }
            if !wall.link.isLive {
                Text(wall.link.isStandIn ? "The sun schedule needs a connected wall. You can look for it again in Settings under Connection." : "Reconnect to your wall to save brightness and the sun schedule.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Setup complete", detail: wall.link.isLive ? "Play some music and it will show on your wall."
                    : (wall.link.isStandIn ? "Play some music and it will show on this phone."
                       : "Your wall is not connected right now. You can look for it again in Settings under Connection."))
            stage(illustrated: false)
            VStack(spacing: 0) {
                summary("The wall", wall.link.isLive ? "Connected" : (wall.link.isStandIn ? "On this phone" : "Waiting to reconnect"))
                summary("Music", musicConnected ? "Apple Music access allowed" : connectedMusicSummary)
                summary("Light", "\(Int((wall.state.brightness * 100).rounded()))%, \(wall.state.sun == "on" ? "follows the sun" : "set by you")")
            }
            Text("You can change connections, brightness and the app design in Settings.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedMusicSummary: String {
        linkedMusic.first?.title ?? "Add when you’re ready"
    }

    /// Music sources the wall already has, in the order Done names them.
    /// Read only from a live wall, so a stale answer is never shown as current.
    private var linkedMusic: [OnboardingLinkedSource] {
        guard wall.link.isLive, let services else { return [] }
        var sources: [OnboardingLinkedSource] = []
        if services.spotify.linked {
            let name = services.spotify.account_name ?? ""
            sources.append(.init(title: "Spotify connected", detail: name.isEmpty ? "Linked on your wall." : name))
        }
        if !services.lastfm.user.isEmpty {
            sources.append(.init(title: "Last.fm saved", detail: services.lastfm.user))
        }
        if let user = services.listenbrainz?.user, !user.isEmpty {
            sources.append(.init(title: "ListenBrainz saved", detail: user))
        }
        return sources
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { Text(title); Spacer(); Text(value).foregroundStyle(Ink.dim) }
                VStack(alignment: .leading, spacing: 7) { Text(title); Text(value).foregroundStyle(Ink.dim) }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.ui(14)).foregroundStyle(Ink.ink).padding(.vertical, 15)
            Rectangle().fill(Ink.hairline).frame(height: 1)
        }.accessibilityElement(children: .combine)
    }

    private func identityRow(symbol: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium)).foregroundStyle(color).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text(detail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    /// The one action pinned at the bottom at every text size.
    @ViewBuilder private var footer: some View {
        switch step {
        case .welcome:
            primary("Find my wall", id: "start", action: startSearch)
        case .find:
            quiet("Continue without a wall", id: "usePhone") { move(to: .noWall) }
        case .found:
            primary("Make the wall glow", id: "identify", action: identify)
        case .glow:
            primary("Yes, that’s my wall", id: "mine") { move(to: .services) }
        case .noWall:
            if wallAnswering {
                primary("Continue with my wall", id: "useWall") { move(to: .found) }
            } else {
                primary("Try it on this phone", id: "usePhone") {
                    // The automatic stand-in, and a search still running,
                    // keep probing, so a wall that finishes booting takes
                    // over by itself. Only an away wall needs the explicit one.
                    // A running search that ends away is handled when the
                    // link settles, through wantsPhone.
                    if case .offline = wall.link { chooseStandIn() }
                    else if wall.link == .searching { wantsPhone = true }
                    move(to: .services)
                }
            }
        case .services:
            primary("Continue to light", id: "continue") { move(to: .light) }
        case .light:
            primary("Continue", id: "continue") { move(to: .done) }
        case .done:
            primary("Open Tessera", id: "open", action: finishOnboarding)
        }
    }

    private var hasSecondaryActions: Bool { ![.find, .light, .done].contains(step) }

    /// The quieter choices. Pinned under the main action at standard sizes.
    /// At accessibility sizes they move to the end of the page, so the pinned
    /// bar does not take a third of the screen.
    @ViewBuilder private var secondaryActions: some View {
        switch step {
        case .welcome:
            quiet("Explore on this phone", id: "usePhone") { move(to: .noWall) }
        case .find, .light, .done:
            EmptyView()
        case .found:
            // A refused glow (pairing code, another check) must not strand
            // the owner on a connected wall.
            if problem != nil { quiet("Skip the glow", id: "skipGlow") { move(to: .services) } }
            quiet("Look again", id: "search", action: startSearch)
        case .glow:
            quiet("I didn’t see it", id: "notMine") {
                // A search would find the same answering wall and loop back
                // here. Found keeps the wall, says what to check, and offers
                // Skip the glow (shown while a problem is set) and the help.
                move(to: .found)
                unseen = true
                problem = "The wall at this address accepted the glow. If yours did not light up, check that its panels have power and try again, or skip the glow and check the address later in Settings under Connection."
            }
        case .noWall:
            if wallAnswering {
                quiet("Use this phone only", id: "usePhone") { chooseStandIn(); move(to: .services) }
            } else {
                quiet("Find my wall again", id: "search", action: startSearch)
            }
        case .services:
            Text("Connect now or come back later.").font(.ui(12)).foregroundStyle(Ink.faint)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.ui(16, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if waiting { ProgressView().tint(Ink.ground) }
                // Scales with the label, so it does not shrink beside
                // accessibility-size text.
                else { Image(systemName: "arrow.right").font(.system(size: arrowSize, weight: .semibold)) }
            }.foregroundStyle(Ink.ground).padding(.horizontal, 21).padding(.vertical, 18)
                .frame(maxWidth: .infinity).background(amber)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(PressStyle(scale: 0.98)).disabled(waiting)
            .accessibilityIdentifier("onboarding.\(id)")
    }

    private func quiet(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.ui(14, .medium)).foregroundStyle(Ink.ink)
            .frame(minHeight: 44).frame(maxWidth: .infinity)
            .accessibilityIdentifier("onboarding.\(id)")
    }

    private func move(to next: OnboardingStep) {
        cancelOperation(); where0.cancel()
        if step == .glow { stopGlow() }
        problem = nil; notice = nil
        journey.move(to: next)
    }

    private func startSearch() {
        cancelOperation(); where0.cancel(); stopGlow()
        problem = nil; notice = nil; wantsPhone = false
        _ = journey.beginSearch()
        // A wall that already answers is found on the first check; looking
        // again would drop it to searching for no reason.
        if !wall.link.isLive { wall.lookForWallAgain() }
    }

    private func goBack() {
        if let previous = step.back(wallLive: wall.link.isLive) { move(to: previous) }
    }

    private func finishOnboarding() {
        cancelOperation(); where0.cancel(); stopGlow()
        onboarded = true
        dismiss()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func refreshServices() async {
        let host = wall.host
        let next = await WallServices.read(host: host)
        guard !Task.isCancelled, host == wall.host else { return }
        services = next
    }

    private func cancelOperation() {
        operationID = UUID(); operation?.cancel(); operation = nil; busy = false
    }

    private func setSun(_ enabled: Bool) {
        guard wall.link.isLive, !waiting else { return }
        if !enabled { saveLight(["sun": "off"], success: "The sun schedule is off."); return }
        problem = nil; notice = nil
        let host = wall.host
        where0.fetch { latitude, longitude in
            guard step == .light, host == wall.host, wall.link.isLive else { return }
            // Clear the place name with the coordinates, as Routines does, so
            // a city saved earlier never labels this new location's weather.
            saveLight(["sun": "on", "lat": latitude, "lon": longitude, "place": ""], success: "The wall will follow sunrise and sunset here.")
        }
    }

    private func saveLight(_ patch: [String: Any], success: String) {
        guard canEditLight, !busy else { return }
        problem = nil; notice = nil
        if wall.link.isStandIn {
            wall.send(patch); brightness = wall.state.brightness; sun = wall.state.sun == "on"; notice = success
            return
        }
        cancelOperation(); let id = operationID; busy = true
        operation = Task { @MainActor in
            let saved = await wall.updateRoutine(patch)
            guard !Task.isCancelled, operationID == id else { return }
            busy = false; brightness = wall.state.brightness; sun = wall.state.sun == "on"
            if saved { notice = success }
            else { problem = "That change didn’t reach the wall. Check the connection and try again." }
        }
    }

    // Temporary display and explicit stand-in routing are shared with panel
    // calibration so identification always restores the content it interrupted.
    private func identify() {
        guard wall.link.isLive, !busy else {
            problem = "Connect to the wall before sending the glow."
            return
        }
        cancelOperation(); let id = operationID; busy = true; problem = nil; notice = nil
        operation = Task { @MainActor in
            let accepted = await temporary.show(on: wall, pixels: Panel.blank(191), purpose: "onboarding", seconds: 5)
            guard !Task.isCancelled, operationID == id else {
                // A request made from this cancelled task would be cancelled
                // too, leaving the wall white until its own timeout.
                Task { _ = await temporary.end(on: wall) }
                return
            }
            guard accepted else {
                // The problem is set once, after the owner check, so VoiceOver
                // reads one sentence, not two that cut each other off.
                guard wall.link.isLive else {
                    busy = false
                    // The shared wording is about checks, not the glow.
                    problem = "Connect to the wall before sending the glow."
                    return
                }
                // The wall's own refusal (a pairing code on screen, another
                // check) is truer than a generic failure on a connected wall.
                let refusal = temporary.problem
                // A fresh reader, so an owner seen on an earlier try cannot
                // outlive a refresh that fails, and this glow's token stays
                // with the display that may still have to end it.
                let reader = TemporaryWallDisplay()
                await reader.refresh(on: wall)
                guard operationID == id else { return }
                busy = false
                if let owner = reader.occupiedBy {
                    problem = "\(Self.occupant(owner)) Try the glow again when it ends, or skip it."
                } else {
                    problem = refusal ?? "The glow did not reach the wall. Try again."
                }
                return
            }
            busy = false
            glowActive = true; journey.move(to: .glow)
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard operationID == id, step == .glow else { return }
            _ = await temporary.end(on: wall)
            guard operationID == id else { return }
            glowActive = false
        }
    }

    private func stopGlow() {
        guard glowActive else { return }
        glowActive = false
        Task { _ = await temporary.end(on: wall) }
    }

    private func chooseStandIn() { wall.useStandIn() }

    private static func occupant(_ purpose: String) -> String {
        switch purpose {
        case "calibration": "True colour is measuring the wall."
        case "guests": "A guest code is on the wall."
        case "panel": "A panel check is on the wall."
        case "onboarding": "Setup is already showing a glow on the wall."
        case "identify": "A short glow is on the wall."
        case "tuning": "Panel tuning is showing a test pattern."
        default: "Another screen is using the wall."
        }
    }

    /// One size on every step. The larger 218pt panel pushed each step's
    /// status line or note under the pinned footer at the default text size.
    private func stage(illustrated: Bool, white: Bool = false) -> some View {
        let side: CGFloat = accessible ? 150 : 154
        let pixels: [UInt8]? = white ? Panel.blank(191) : (illustrated ? OnboardingLightStudy.pixels : wall.frame.map { [UInt8]($0) })
        let caption = illustrated ? "ILLUSTRATION" : (white ? "GLOW, 5 SECONDS" : (wall.frame == nil ? "WAITING FOR FIRST FRAME" : (wall.link.isLive ? "LIVE FROM YOUR WALL" : (wall.link.isStandIn ? "ON THIS PHONE" : "LAST RECEIVED FRAME"))))
        return VStack(spacing: 0) {
            ZStack {
                OnboardingRoomGeometry(accent: amber).accessibilityHidden(true)
                PanelCanvas(px: pixels, duty: 1)
                    .frame(width: side, height: side)
                    .background(Ink.ground)
                    .overlay(Rectangle().strokeBorder(Color(hex: 0x585044), lineWidth: 1))
                    .padding(7).background(Color(hex: 0x12110F))
                    .rotationEffect(.degrees(illustrated && !reduceMotion ? -3 : 0))
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 5, y: 14)
                    .padding(.vertical, 20)
            }.frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Circle().fill(illustrated ? amber : (wall.link.isLive ? Ink.moss : Ink.dim)).frame(width: 5, height: 5)
                Text(caption).font(.machine(11)).tracking(0.8).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !accessible {
                    Text("\(illustrated ? 64 : Panel.side) x \(illustrated ? 64 : Panel.side)").font(.machine(10)).foregroundStyle(Ink.dim)
                        .fixedSize()
                }
            }.padding(.horizontal, 16).padding(.vertical, 14).background(Color(hex: 0x191713))
        }.clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(illustrated ? "Illustration of a lit wall, not a live picture." : caption.lowercased())
            .accessibilityIdentifier("onboarding.wallPreview")
    }

    private func connectionDiagram(searching: Bool) -> some View {
        HStack(spacing: accessible ? 16 : 25) {
            Image(systemName: "iphone").font(.system(size: accessible ? 39 : 48, weight: .ultraLight)).foregroundStyle(Ink.ink)
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { index in
                    Circle().fill(searching ? amber.opacity(0.25 + Double(index) * 0.16) : Ink.faint.opacity(0.45))
                        .frame(width: 4, height: 4)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.faint, lineWidth: 1)
                OnboardingTileMark().stroke(amber.opacity(searching ? 1 : 0.35), lineWidth: 2).padding(15)
            }.frame(width: accessible ? 66 : 86, height: accessible ? 66 : 86)
        }.frame(maxWidth: .infinity).padding(.vertical, accessible ? 26 : 48)
            .background(room).clipShape(RoundedRectangle(cornerRadius: 22)).accessibilityHidden(true)
    }
}

private struct OnboardingLinkedSource {
    let title: String
    let detail: String
}

private struct OnboardingTileMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            for column in 0..<3 {
                let tile = CGRect(x: rect.minX + CGFloat(column) * rect.width / 3,
                                  y: rect.minY + CGFloat(row) * rect.height / 3,
                                  width: rect.width / 3 - 3, height: rect.height / 3 - 3)
                path.addRoundedRect(in: tile, cornerSize: CGSize(width: 1, height: 1))
            }
        }
        return path
    }
}

private struct OnboardingRoomGeometry: View {
    var accent: Color
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x302A22)))
            var plane = Path()
            plane.move(to: CGPoint(x: size.width * 0.75, y: 0))
            plane.addLine(to: CGPoint(x: size.width, y: 0))
            plane.addLine(to: CGPoint(x: size.width, y: size.height))
            plane.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.88))
            plane.closeSubpath()
            context.fill(plane, with: .color(Color(hex: 0x26221C)))
            var horizon = Path()
            horizon.move(to: CGPoint(x: 0, y: size.height * 0.88))
            horizon.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.88))
            horizon.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(horizon, with: .color(accent.opacity(0.09)), lineWidth: 1)
            for x in stride(from: 0.0, to: size.width, by: 3) {
                let opacity = 0.012 + 0.008 * sin(x * 1.73)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(opacity)))
            }
        }
    }
}

private enum OnboardingLightStudy {
    /// An authored, deterministic 64-pixel illustration, never presented as live
    /// artwork. The four woven fields introduce Tessera's material and palette.
    static let pixels: [UInt8] = {
        let side = 64
        var result = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x) / Double(side - 1), v = Double(y) / Double(side - 1)
                let radius = hypot(u - 0.51, v - 0.49)
                let sun = max(0, 1 - radius / 0.68)
                let stripe = (x / 4 + y / 4) % 2 == 0 ? 1.0 : 0.84
                let diagonal = sin((u + v) * 13) * 0.09
                let brightness = max(0.08, min(1, sun + diagonal)) * stripe
                let cool = x < 31 && y > 31
                let color: (Double, Double, Double) = cool ? (108, 143, 137) : (246, 172 + 40 * v, 73 + 70 * v)
                let i = (y * side + x) * 3
                result[i] = UInt8(color.0 * brightness)
                result[i + 1] = UInt8(color.1 * brightness)
                result[i + 2] = UInt8(color.2 * brightness)
            }
        }
        return result
    }()
}
