// Panel tuning: every number that decides what the LEDs actually do.
//
// Tuning a panel is looking at it, so the page is built around the wall:
// a preview at the top, test patterns that go on the wall through a
// temporary display (the owner's mode always comes back), then the wall's
// own knobs in the groups the wall describes. Every write is answered by
// the wall with everything it now holds, and that answer is what the rows
// show. The preview is the picture before the LED settings, and the page
// says so, because the phone cannot show gains, dithering or bit depth.
//
// Launch flags restart the panel. The wall reports whether the renderer
// really came back, so the page can say restarting, back, stalled or
// stopped instead of guessing, and it keeps the other launch flags locked
// until the panel is back.

import SwiftUI

struct PanelTuningPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kept for the callers. The page draws in its own stone, the way each
    /// batch 16 page keeps one quiet accent of its own.
    let accent: Color

    @State private var store = TuningStore()
    @State private var display = TemporaryWallDisplay()
    @State private var tab: Tab = .picture
    /// The pattern of ours on the wall. Only meaningful while `ours`.
    @State private var pattern: TuningPattern = .wall
    /// The wall's own picture from just before our pattern went up, so the
    /// Your wall swatch keeps showing it while wall.frame is the pattern.
    @State private var ownerFrame: Data?
    /// A pattern on its way to the wall. display.busy is also true for a
    /// renewal, so STARTING tracks its own write, as PanelPage does.
    @State private var changing: TuningPattern?
    /// The finger's value per knob, shown instead of the wall's while it is
    /// down and until the wall's answer to it is in.
    @State private var dragging: [String: Double] = [:]
    /// Knobs with a finger on them, or a VoiceOver change not yet sent.
    @State private var holding: Set<String> = []
    @State private var commits: [String: Task<Void, Never>] = [:]
    @State private var lastLive: [String: Date] = [:]
    @State private var confirmingReset = false
    @State private var resetProblem: String?
    @State private var resetNotice: String?
    @State private var notice: String?
    @State private var backNote: String?
    @State private var services: WallServices?
    /// Where the pattern's title and state line ends and how far the page
    /// has scrolled, written every scroll frame. A plain box, so only
    /// stateGone redraws the page.
    @State private var geometry = PinGeometry()
    /// The pattern's title and state line has gone under the pinned strip,
    /// which then says the same, so the two are never on screen together.
    @State private var stateGone = false
    @State private var lastRenew = Date.distantPast
    /// The host the page last asked for /tuning, so a new one is loaded
    /// rather than refreshed.
    @State private var readHost: String?
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15
    #if DEBUG
    @State private var hooked = false
    #endif

    enum Tab: String { case picture, listening }

    private static let space = "tuning.content"
    private let stone = TuningInk.stone
    private var ax: Bool { type.isAccessibilitySize }
    private var reduce: Bool { reduceMotion || Motion.forcedReduced }
    private var live: Bool { wall.link.isLive }
    private var loaded: Bool { !store.knobs.isEmpty }
    private var panel: RendererState { store.panelState }
    private var ours: Bool { display.active && display.purpose == "tuning" }
    /// Another screen's display, including Panel tuning on another phone.
    /// Ignored offline, where the last answer may be stale.
    private var occupied: String? { live && !ours ? display.occupiedBy : nil }
    private var selected: TuningPattern { changing ?? (ours ? pattern : .wall) }
    /// The panel is dark and will not come back by itself. Only said while
    /// the wall answers, since an offline wall's last state may be stale.
    private var panelDark: Bool { live && (panel == .stalled || panel == .stopped) }
    /// The panel is dark for a restart or a start, and will come back.
    private var panelComingBack: Bool { live && panel.comingBack }
    /// A wall that runs without a panel (the Mac preview brain).
    private var absent: Bool { live && panel == .absent }
    /// Nothing here can be tuned: no wall, a wall without tuning, or a wall
    /// that has never been read. The page then describes rather than asks.
    private var tuningUnavailable: Bool { wall.link.isStandIn || store.unsupported || (!live && !loaded) }
    /// The values on screen may not be the wall's any more: it is offline,
    /// or it answers but /tuning has failed twice in a row. The status line
    /// then says when they were read.
    private var stale: Bool { loaded && (!live || store.readFailures >= 2) }
    /// Nothing on the panel would show a change: nothing to tune, a read
    /// that failed, values that may be stale, a dark panel, or no panel at
    /// all. The page then never asks the owner to change a setting and look
    /// at the wall.
    private var nothingToWatch: Bool {
        tuningUnavailable || (!loaded && store.readFailed) || stale || panelDark || absent
    }
    /// Patterns can be offered at all. False draws the grid as turned off.
    private var patternsUsable: Bool { live && occupied == nil && !absent && !panelDark }
    private var patternsEnabled: Bool { patternsUsable && !display.busy && changing == nil }
    /// Our pattern can still be ended with Your wall when the panel went
    /// dark under it.
    private var canEnd: Bool { ours && live && !display.busy && changing == nil }
    private func enabled(_ item: TuningPattern) -> Bool { patternsEnabled || (item == .wall && canEnd) }
    /// The tabs need a wall that answers, or values read from one.
    private var tabsEnabled: Bool { loaded || live }
    private var showsKnobs: Bool { loaded && !wall.link.isStandIn && !store.unsupported }
    private var canWrite: Bool { live && loaded && !store.busy && !store.unsupported }
    private var hasCeiling: Bool { store.knobs.contains { $0.name == Knob.ceiling.name } }
    private var showsPinned: Bool { stateGone && tab == .picture && !ax }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { page(proxy) }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                    geometry.scrolled = y; updatePinned()
                }
                .overlay(alignment: .top) {
                    if showsPinned { pinned(proxy).transition(.opacity) }
                }
                .animation(reduce ? nil : .easeInOut(duration: 0.18), value: showsPinned)
                #if DEBUG
                .task { await hooks(proxy) }
                #endif
        }
        // The ground fills the page edge to edge, under the bar too.
        .background { TuningInk.ground.ignoresSafeArea() }
        .foregroundStyle(Ink.ink).tint(stone)
        // Follows the tab, so the microphone's settings are never headed
        // Panel tuning.
        .navigationTitle(tab == .listening ? "Microphone tuning" : "Panel tuning").navigationBarTitleDisplayMode(.inline)
        // A solid bar in the page's own ground, as on Wall health and
        // Connection: what scrolls under it is hidden, not frosted.
        .toolbarBackground(TuningInk.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable {
            guard live else { return }
            readHost = wall.host
            await store.load(host: wall.host)
            await display.refresh(on: wall)
        }
        .task(id: "\(wall.host)|\(scene)|\(live)") { await poll() }
        .onChange(of: ours) { _, now in if !now { pattern = .wall; ownerFrame = nil } }
        .onChange(of: store.justBack) { _, at in back(at) }
        .onChange(of: store.rowProblems) { old, new in
            // A refused write, once. Polling never changes these.
            if new.contains(where: { old[$0.key] != $0.value }) { Taps.error() }
        }
        .onChange(of: scene) { _, phase in
            guard phase == .background else { return }
            let held = ours
            Task { if await display.end(on: wall), held { notice = "The test pattern ended when you left the app." } }
        }
        // Always end, as PanelPage does: end() waits for a write in flight
        // and sends nothing when no pattern was tried.
        .onDisappear {
            let session = display, source = wall
            store.holding = false
            Task { _ = await session.end(on: source) }
        }
    }

    private func page(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: ax ? 18 : 24) {
            masthead
            // Said only when the notice under it does not already say it.
            if statusText(Date()) != nil {
                TimelineView(.periodic(from: .now, by: 5)) { context in status(context.date) }
            }
            pageNotice
            if let notice {
                Text(notice).font(.ui(14)).foregroundStyle(stone).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tuning.notice")
            }
            tabs
            // The Listening tab's own line is the masthead's, which follows
            // the tab, so the page never says both.
            if tab == .picture {
                if ax {
                    patterns
                    preview
                    if let footnote {
                        Text(footnote).font(.ui(10)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    preview
                    patterns
                }
            }
            if showsKnobs {
                ForEach(store.groups.filter { $0.tab == tab.rawValue }) { group in
                    groupSection(group)
                }
                startOver
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 44)
        .coordinateSpace(.named(Self.space))
    }

    // MARK: Masthead and status

    /// No machine label over the headline: the navigation title right above
    /// already reads Panel tuning.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ax {
                // Both lines stay under 327 pt up to xxxLarge, as PanelPage's
                // do, and the headline is hidden at accessibility sizes. The
                // Listening tab has its own, as the body under it follows the
                // tab: "microphone." is narrower than "panel by eye.".
                Text(tab == .listening ? "Tune the\nmicrophone." : "Tune the\npanel by eye.").font(.display(40)).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            Text(mastheadBody)
                .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tuning.intro")
        }
    }

    /// Follows the tab, so the Listening tab never hears that its settings
    /// change the picture. With nothing to tune, a failed read, values that
    /// may be stale, or a panel that is dark or missing, it describes, and
    /// asks nothing of the owner.
    private var mastheadBody: String {
        if tab == .listening {
            if tuningUnavailable { return "How the microphone is used." }
            return ax ? "These change the microphone, not the picture."
                      : "These settings change how the microphone is used. They do not change the picture."
        }
        if nothingToWatch { return "How the LEDs draw every picture." }
        return ax ? "Change a setting, then look at the wall."
                  : "Each setting changes how the LEDs draw every picture. Change one, then look at the wall."
    }

    /// The first answer on screen, as in Pictures.
    private func status(_ now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if spinning { ProgressView().tint(stone).accessibilityHidden(true) }
            Text(statusText(now) ?? "").font(.ui(ax ? 12 : 14, .medium)).foregroundStyle(stone)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tuning.status")
        }
    }

    private var spinning: Bool {
        if case .searching = wall.link { return true }
        guard live else { return false }
        return store.resetting || store.restartAsked || store.sending || changing != nil || panel.comingBack
            || (!loaded && !store.readFailed && !store.unsupported)
    }

    /// nil where the page notice right under it already says the same:
    /// stand-in, offline never read, unsupported, read error, stalled and
    /// stopped. The status then speaks only when no notice does, or adds
    /// what the notice does not (how long ago the values were read). A
    /// restart on the Picture tab is said by the preview's cover, with its
    /// spinner, and by the pinned strip once the preview has scrolled away.
    private func statusText(_ now: Date) -> String? {
        switch wall.link {
        case .standIn: return nil
        case .searching: return "Looking for your wall"
        case .offline:
            guard loaded, let read = store.lastRead else { return nil }
            return "Last read \(TuningCopy.ago(now.timeIntervalSince(read)))"
        case .live: break
        }
        if store.resetting { return "Returning to defaults" }
        if let item = changing { return item == .wall ? "Ending the test pattern" : "Putting \(item.title) on the wall" }
        if store.unsupported { return nil }
        if !loaded { return store.readFailed ? nil : "Reading the panel settings" }
        if panel.comingBack && tab == .picture { return nil }
        if panel == .restarting { return "Panel restarting" }
        if panel == .starting { return "Panel starting" }
        if let backNote { return backNote }
        if panel == .stalled || panel == .stopped { return nil }
        if store.readFailures >= 2, let read = store.lastRead { return "Last read \(TuningCopy.ago(now.timeIntervalSince(read)))" }
        return TuningCopy.changed(store.changedCount)
    }

    /// At most one, in this order: stand-in, offline, unsupported, read
    /// error, stalled, stopped, occupied, pattern problem. Any action sits
    /// right under its notice.
    @ViewBuilder private var pageNotice: some View {
        if wall.link.isStandIn {
            CreativeConnectionNotice(title: "No wall connected", detail: "Panel tuning needs a physical panel. Find your wall in Connection to use it.",
                                     symbol: "square.dashed", tint: stone).accessibilityIdentifier("tuning.standin")
        } else if case .offline = wall.link {
            CreativeConnectionNotice(title: "Your wall is offline",
                                     detail: loaded ? "These are the last values read. Reconnect to change them." : "Panel settings are read from the wall. Connect to your wall to see and change them.",
                                     symbol: "wifi.slash", tint: stone).accessibilityIdentifier("tuning.offline")
        } else if !live {
            EmptyView()
        } else if store.unsupported {
            CreativeConnectionNotice(title: "Tuning is not available", detail: "This wall’s software does not offer panel tuning.",
                                     symbol: "slider.horizontal.3", tint: stone).accessibilityIdentifier("tuning.unsupported")
        } else if !loaded && store.readFailed {
            VStack(alignment: .leading, spacing: 6) {
                CreativeConnectionNotice(title: "Couldn’t read the panel settings", detail: "Nothing has changed on the wall.",
                                         symbol: "exclamationmark.circle", tint: stone).accessibilityIdentifier("tuning.readError")
                TuningTextButton(title: "Read again", size: ax ? 12 : 15) {
                    readHost = wall.host
                    Task { await store.load(host: wall.host) }
                }
                .disabled(store.reading).accessibilityIdentifier("tuning.retry")
            }
        } else if panel == .stalled {
            stalled
        } else if panel == .stopped {
            CreativeConnectionNotice(title: "The panel program is not running",
                                     detail: "Settings are saved, but nothing is driving the panel. Turn the wall off and on at the power to start it.",
                                     symbol: "bolt.slash", tint: stone).accessibilityIdentifier("tuning.stopped")
        } else if let owner = occupied {
            CreativeConnectionNotice(title: "The wall is in use", detail: Self.occupant(owner),
                                     symbol: "square.dashed", tint: stone).accessibilityIdentifier("tuning.occupied")
        } else if let issue = display.problem {
            CreativeConnectionNotice(title: "Pattern not shown", detail: issue,
                                     symbol: "exclamationmark.circle", tint: stone).accessibilityIdentifier("tuning.patternProblem")
        }
    }

    /// A restart that has not come back. The remedy is a second restart, or
    /// putting back only the launch flag that was changed. Never every
    /// panel default: those include the row settle time that may be what
    /// keeps the ghost rows away, and the brightness ceiling, which cannot
    /// stop the panel at all.
    private var stalled: some View {
        VStack(alignment: .leading, spacing: 12) {
            CreativeConnectionNotice(title: "The panel has not come back",
                                     detail: store.lastRevert == nil
                                        ? "It has been more than 20 seconds since the panel restarted. Restart it again. If it stays dark, turn the wall off and on at the power."
                                        : "It has been more than 20 seconds since the panel restarted. Restart it again, or put back the last setting you changed. If it stays dark, turn the wall off and on at the power.",
                                     symbol: "exclamationmark.triangle", tint: stone).accessibilityIdentifier("tuning.stalled")
            PrimaryButton(title: store.restartAsked ? "Restarting…" : "Restart the panel",
                          enabled: live && !store.busy && !store.sending, accent: stone) {
                Task { if await store.restartPanel() { renew() } }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("tuning.restart")
            if let revert = store.lastRevert, let knob = knob(revert.name) {
                TuningTextButton(title: "Put \(knob.title) back to \(TuningStore.format(revert.previous, knob: knob))",
                                 size: ax ? 12 : 15, fullWidth: ax) {
                    Task { await store.revert(); renew() }
                }
                .disabled(store.busy || store.sending).accessibilityIdentifier("tuning.revert")
            }
        }
    }

    /// What holds the wall, from the purpose its screen registered.
    static func occupant(_ purpose: String) -> String {
        switch purpose {
        case "calibration": "True colour is measuring the wall."
        case "guests": "A guest code is on the wall."
        case "onboarding": "Setup is showing a preview on the wall."
        case "panel": "A panel check is on the wall."
        case "identify": "A short glow is on the wall."
        case "tuning": "Panel tuning on another phone is showing a test pattern. It ends within ten minutes."
        default: "Another screen is using the wall."
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 6) {
            tabButton(.picture, "Picture", "square.grid.3x3")
            tabButton(.listening, "Listening", "waveform")
        }
        .padding(5).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 16))
        // Nothing to show on either tab until the wall has been read once.
        .disabled(!tabsEnabled)
    }

    /// Turned off, both labels go faint and neither is filled, so the
    /// control does not look like the live one.
    private func tabButton(_ value: Tab, _ title: String, _ symbol: String) -> some View {
        let chosen = tab == value
        let filled = chosen && tabsEnabled
        return Button {
            withAnimation(reduce ? nil : .easeInOut(duration: 0.18)) { tab = value }
        } label: {
            HStack(spacing: 8) {
                if !ax { Image(systemName: symbol).font(.system(size: glyph, weight: .medium)) }
                // One line, scaled rather than broken, at the largest sizes.
                Text(title).font(.ui(ax ? 10 : 15, .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(!tabsEnabled ? Ink.faint : chosen ? Ink.ink : Ink.dim)
            .background(filled ? TuningInk.chosen : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CalibrationLinkStyle())
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tuning.tab.\(value.rawValue)")
    }

    // MARK: Preview and patterns

    private var previewPixels: [UInt8]? {
        if ours, pattern != .wall { return TuningPatternCache.pixels(pattern, side: Panel.side) }
        return wall.frame.map { [UInt8]($0) }
    }

    /// The label under the well says what the panel is really doing, so it
    /// never reads live over a panel that is dark or held by another screen.
    /// Under the cover it only names the picture: the cover says why the
    /// panel shows nothing, and the label does not say it again.
    private var previewSource: String {
        if wall.link.isStandIn { return "PHONE PREVIEW" }
        if !live && !ours { return "LAST FRAME, SAVED HERE" }
        let subject = ours ? pattern.title.uppercased() : "YOUR WALL"
        if previewCovered { return subject }
        if let owner = occupied { return "IN USE, \(Self.occupantShort(owner))" }
        return "\(subject), \(ours ? "ON THE WALL" : "LIVE")"
    }

    /// The panel is dark, for a restart or for good, or there is no panel.
    /// The wall's frame is the brain's picture, which carries on, so the
    /// preview is dimmed to match the panel and says why.
    private var previewCovered: Bool { panelComingBack || panelDark || absent }

    private var coverText: String {
        if absent { return "No panel attached" }
        if panelDark { return "The panel is dark" }
        return panel == .starting ? "The panel is starting" : "Restarting the panel"
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                PanelCanvas(px: previewPixels, duty: 1)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // A hairline just outside, so a black picture still has an edge.
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(Ink.hairline, lineWidth: 1).padding(-0.5) }
                if previewCovered {
                    // 0.82 black keeps ink text well over 4.5:1 on the
                    // brightest picture under it.
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.82))
                        VStack(spacing: 8) {
                            if panelComingBack { ProgressView().tint(stone) }
                            // Capped at xxxLarge: the well is 140 pt wide at
                            // accessibility sizes, too narrow for "Restarting"
                            // whole any larger. VoiceOver reads previewLabel.
                            Text(coverText)
                                .font(.ui(13, .medium)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }.padding(8)
                    }.transition(.opacity)
                }
            }
            .frame(maxWidth: ax ? 140 : 200)
            .animation(.easeInOut(duration: 0.25), value: previewCovered)
            .padding(16).frame(maxWidth: .infinity)
            .background(TuningInk.well, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(previewLabel)
            .accessibilityIdentifier("tuning.preview")
            .id("tuning.preview")
            if !ax {
                HStack {
                    Text(previewSource)
                    Spacer(minLength: 8)
                    Text("\(Panel.side) x \(Panel.side)")
                }
                .font(.machine(9)).foregroundStyle(Ink.faint).lineLimit(1).accessibilityHidden(true)
            }
            // Only where there is something to judge: not with no wall, a
            // wall without tuning, a failed read, values that may be stale,
            // or a panel dark or missing.
            if !nothingToWatch {
                Text("The phone shows the picture before the LED settings are applied. Judge each change on the wall itself.")
                    .font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewLabel: String {
        if wall.link.isStandIn { return "Phone preview" }
        if !live && !ours { return "Last frame, saved on this phone" }
        let subject = ours ? pattern.title : "Your wall"
        if panelDark { return "\(subject). The panel is dark" }
        if panelComingBack { return "\(subject). The panel is restarting" }
        if absent { return "Your wall. No panel is attached" }
        if let owner = occupied { return "In use. \(Self.occupant(owner))" }
        return ours ? "\(subject), on the wall" : "Your wall, live"
    }

    /// The chosen pattern's state, under the grid and in the pinned strip.
    /// A dark or restarting panel is said here too, so neither place reads
    /// live or on the wall over a panel that shows nothing.
    private var patternState: String {
        if changing == .wall { return "ENDING" }
        if changing != nil { return "STARTING" }
        if panelDark { return "PANEL DARK" }
        if panelComingBack { return "RESTARTING" }
        if ours { return "ON THE WALL" }
        if wall.link.isStandIn { return "PHONE PREVIEW" }
        if !live { return "LAST FRAME" }
        if absent { return "NO PANEL" }
        return occupied != nil ? "IN USE" : "LIVE"
    }

    /// nil offline and with no wall, where no pattern can be chosen.
    private var footnote: String? {
        if panelDark {
            return ours ? "The panel is dark, so the pattern cannot be seen. Choose Your wall or leave this page to end it."
                        : "The panel is dark, so patterns cannot be seen."
        }
        if ours { return "The pattern stays up while you tune. It ends when you choose Your wall, leave this page, or after ten minutes without a change." }
        if absent { return "No panel is attached, so patterns are not shown." }
        if !live { return nil }
        return "Choosing a pattern puts it on the wall until you choose Your wall or leave this page."
    }

    /// The occupant, short enough for the machine label under the preview.
    static func occupantShort(_ purpose: String) -> String {
        switch purpose {
        case "calibration": "TRUE COLOUR"
        case "guests": "GUEST CODE"
        case "onboarding": "SETUP"
        case "panel": "PANEL CHECK"
        case "identify": "CONNECTION CHECK"
        case "tuning": "ANOTHER PHONE"
        default: "ANOTHER SCREEN"
        }
    }

    private var patterns: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test patterns").font(.ui(ax ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
            // Six equal columns, about 49 pt each on a 375 pt phone, so every
            // swatch keeps a 44 pt target. Three at accessibility sizes.
            // Plain rows rather than a lazy grid, so every swatch is always
            // in the accessibility tree wherever the page is scrolled.
            let columns = ax ? 3 : 6
            let items = TuningPattern.allCases
            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(items[start..<min(start + columns, items.count)]) { item in swatchButton(item) }
                    }
                }
            }
            // Stacked at accessibility sizes, so a long word in the title is
            // never squeezed beside the state and broken.
            let layout = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                // Never larger than the Test patterns header above it: 12
                // under its 13 at accessibility sizes.
                Text(selected.title).font(.ui(ax ? 12 : 17, .semibold)).fixedSize(horizontal: false, vertical: true)
                if !ax { Spacer(minLength: 8) }
                Text(patternState).font(.machine(ax ? 7 : 10)).tracking(ax ? 0 : 1).foregroundStyle(stone).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("tuning.patternState")
            }
            // The pinned strip repeats this line, so it appears only once
            // this line has gone under it.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { bottom in
                geometry.stateBottom = bottom; updatePinned()
            }
            Text(selected.detail).font(.ui(ax ? 12 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if !ax, let footnote { Text(footnote).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
        }
        .id("tuning.patterns")
    }

    private func swatchButton(_ item: TuningPattern) -> some View {
        let chosen = selected == item
        // Turned off for want of a wall (offline, in use, no panel, a dark
        // panel), the grid fades. Briefly off while a pattern starts, it
        // does not. Your wall stays open to end our pattern on a dark panel.
        let usable = patternsUsable || (item == .wall && ours && live)
        return Button { Task { await put(item) } } label: {
            VStack(spacing: 6) {
                swatch(item).aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.hairline) }
                    .opacity(usable ? 1 : 0.4)
                    .padding(3)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? (usable ? stone : Ink.faint) : .clear, lineWidth: 2) }
                // One size for every name, on up to two lines that are
                // always reserved, so Dark colours and Colour bars wrap
                // between words instead of shrinking below the others.
                // Left off above the default text size: the title under the
                // grid names the choice.
                if type <= .large {
                    Text(item.title).font(.ui(11, chosen ? .semibold : .medium))
                        .foregroundStyle(!usable ? Ink.faint : chosen ? Ink.ink : Ink.dim)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(!enabled(item))
        .accessibilityLabel("\(item.title) pattern")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tuning.pattern.\(item.rawValue)")
    }

    @ViewBuilder private func swatch(_ item: TuningPattern) -> some View {
        if item == .wall {
            // While ours is up, wall.frame is the pattern itself, so the
            // swatch that brings the owner's picture back keeps showing it.
            let own = ours ? (ownerFrame ?? wall.frame) : wall.frame
            PanelCanvas(px: own.map { [UInt8]($0) }, duty: 1).accessibilityHidden(true)
        } else if let image = TuningPatternCache.swatch(item) {
            // A bitmap made once per pattern. A Canvas of 4096 rects would be
            // filled again on every page update, several a second in a drag.
            Image(decorative: image, scale: 1).resizable().interpolation(.none).accessibilityHidden(true)
        } else {
            Color.black.accessibilityHidden(true)
        }
    }

    /// Put a pattern on the wall, change the one that is up, or end ours for
    /// Your wall. The wall's own mode and frame come back when ours ends.
    private func put(_ item: TuningPattern) async {
        guard enabled(item) else { return }
        if item == .wall {
            guard ours else { return }
            changing = .wall
            defer { changing = nil }
            if await display.end(on: wall) { Taps.commit() }
            return
        }
        if ours, item == pattern { return }
        changing = item
        defer { changing = nil }
        let starting = !ours
        // The owner's picture, taken before ours replaces it on the wall.
        if starting { ownerFrame = wall.frame }
        let pixels = TuningPatternCache.pixels(item, side: Panel.side)
        let shown = ours ? await display.update(on: wall, pixels: pixels)
                         : await display.show(on: wall, pixels: pixels, purpose: "tuning", seconds: 600)
        if shown { pattern = item; notice = nil; lastRenew = Date(); Taps.landed() }
        else if starting && !ours { ownerFrame = nil }
    }

    /// Keep our pattern up while the owner tunes: any committed change
    /// renews the ten minutes, at most once every 5 s.
    private func renew() {
        guard ours, !display.busy, Date().timeIntervalSince(lastRenew) >= 5 else { return }
        lastRenew = Date()
        Task { _ = await display.update(on: wall) }
    }

    // MARK: Pinned strip

    /// The strip's height. It covers the top of the scroll view once shown.
    private static let stripHeight: CGFloat = 56

    /// Shows the strip once the pattern's title and state line has scrolled
    /// under where the strip sits, so "Your wall" and its state are never on
    /// screen twice.
    private func updatePinned() {
        let edge = geometry.stateBottom - Self.stripHeight
        // 8 pt either way, so the strip never flickers at the edge.
        let gone = stateGone ? geometry.scrolled > edge - 8 : geometry.scrolled > edge + 8
        if gone != stateGone { stateGone = gone }
    }

    private func pinned(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduce ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo("tuning.preview", anchor: .top) }
        } label: {
            HStack(spacing: 12) {
                PanelCanvas(px: previewPixels, duty: 1).frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // Dimmed with the panel, as the preview is.
                    .opacity(previewCovered ? 0.3 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    // The pattern's state over its title, the pair under
                    // the grid, which has scrolled away by now.
                    Text(patternState).font(.machine(9)).foregroundStyle(Ink.faint)
                    Text(selected.title).font(.ui(14, .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                }
                Spacer(minLength: 8)
                // The state line already says restarting.
                if panelComingBack { ProgressView().tint(stone) }
            }
            .padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: Self.stripHeight)
            .background(TuningInk.ground)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(CalibrationLinkStyle())
        .accessibilityLabel("\(selected.title), \(patternState.lowercased())")
        .accessibilityHint("Shows the preview")
        .accessibilityIdentifier("tuning.pinned")
    }

    // MARK: Groups

    private func knob(_ name: String) -> Knob? { store.knobs.first { $0.name == name } }

    /// The group's knobs, in the wall's order. A brain that does not list
    /// the brightness ceiling still gets it, drawn from /state.
    private func knobs(in group: TuningGroup) -> [Knob] {
        let listed = store.knobs.filter { $0.group == group.key }
        return group.key == "Panel" && !hasCeiling ? [Knob.ceiling] + listed : listed
    }

    private func groupSection(_ group: TuningGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                let changed = store.changed(in: group.key)
                let layout = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                layout {
                    Text(group.title).font(.ui(ax ? 13 : 22, .semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("tuning.group.\(group.key)")
                    if !ax { Spacer(minLength: 8) }
                    if changed > 0 {
                        Text("\(changed) CHANGED").font(.machine(ax ? 7 : 9)).foregroundStyle(Ink.faint).lineLimit(1).fixedSize()
                            .accessibilityLabel("\(changed) changed")
                    }
                }
                if !group.summary.isEmpty {
                    Text(group.summary).font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                suggestion(group)
                if group.key == "Panel", panel == .absent {
                    CreativeConnectionNotice(title: "No panel attached",
                                             detail: "This wall is running without a panel. Panel drive settings are saved and take effect when one is connected.",
                                             symbol: "rectangle.dashed", tint: stone)
                        .padding(.top, 6).accessibilityIdentifier("tuning.absent")
                }
                links(group)
            }
            .padding(.bottom, 6)
            // Each row's scope line, said once for a run of rows it covers.
            let list = knobs(in: group)
            let scopes = TuningCopy.scopes(list.map(scope))
            ForEach(Array(list.enumerated()), id: \.element.id) { index, knob in
                Rectangle().fill(TuningInk.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    row(knob, scope: scopes[index])
                    // A row whose note points at another pattern than its
                    // group's gets that pattern one tap away too.
                    if let item = Self.rowPatterns[knob.name], showsPatternLinks, group.tab == "picture" {
                        patternLink(item, id: "tuning.knob.\(knob.name).suggest").padding(.bottom, 8)
                    }
                }
                .id("tuning.knob.\(knob.name)").scrollAnchor("tuning.knob.\(knob.name).anchor")
            }
            if group.key == "Colour" {
                Rectangle().fill(TuningInk.rule).frame(height: 1)
                measured
            }
        }
        .scrollAnchor("tuning.group.\(group.key).anchor")
    }

    /// Rows whose note sends the owner to a pattern other than the group's.
    /// Row addressing and Row settle time are judged on the Grid, while
    /// Panel drive as a whole suggests Dark steps.
    private static let rowPatterns: [String: TuningPattern] = ["panel_type": .grid, "addr_settle_ns": .grid]

    /// Pattern links need a wall that answers or was read, and a panel to
    /// show them on.
    private var showsPatternLinks: Bool { (live || loaded) && !absent }

    /// The pattern that shows a group best, one tap away.
    @ViewBuilder private func suggestion(_ group: TuningGroup) -> some View {
        if group.tab == "picture", let raw = group.pattern, let item = TuningPattern(rawValue: raw), showsPatternLinks {
            patternLink(item, id: "tuning.suggest.\(group.key)")
        }
    }

    @ViewBuilder private func patternLink(_ item: TuningPattern, id: String) -> some View {
        if item == .wall {
            // The wall's own picture is already up unless ours is.
            if ours {
                suggestionButton("Show your wall’s own picture", item: item, id: id)
            }
        } else if panelDark {
            // A dark panel shows no pattern, so none is offered.
            EmptyView()
        } else if ours && pattern == item {
            Text("\(item.title.uppercased()) IS ON THE WALL").font(.machine(9)).foregroundStyle(stone)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 22, alignment: .leading)
        } else {
            suggestionButton("Show \(item.title) on the wall", item: item, id: id)
        }
    }

    private func suggestionButton(_ title: String, item: TuningPattern, id: String) -> some View {
        TuningTextButton(title: title, size: ax ? 12 : 14) { Task { await put(item) } }
            .disabled(!enabled(item)).accessibilityIdentifier(id)
    }

    /// The pages with the live meter and the word lists, for the microphone's
    /// groups.
    @ViewBuilder private func links(_ group: TuningGroup) -> some View {
        if group.key == "Hearing" {
            linkRow("Live level and recent recognitions", "Hearing & gestures", id: "tuning.hearingLink") {
                HearingPage(accent: stone, services: $services)
            }
            // Named for what the page holds, the song library, which is
            // also the page's own title.
            linkRow("Add or remove songs", "Song library", id: "tuning.teachLink") { TeachPage(accent: stone) }
        } else if group.key == "Voice" {
            linkRow("Wake word choice and live score", "Voice", id: "tuning.voiceLink") { VoicePage(accent: stone) }
        }
    }

    private func linkRow<Destination: View>(_ title: String, _ subtitle: String, id: String,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Chevron()
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier(id)
    }

    // MARK: Rows

    private func isLegacyCeiling(_ knob: Knob) -> Bool { knob.name == Knob.ceiling.name && !hasCeiling }

    private func wallValue(_ knob: Knob) -> Double {
        isLegacyCeiling(knob) ? wall.state.panelBrightness : (store.values[knob.name] ?? knob.min)
    }

    private func defaultValue(_ knob: Knob) -> Double? {
        isLegacyCeiling(knob) ? 160 : store.defaults[knob.name]
    }

    /// Where a change to this knob shows, unless the knob does nothing on
    /// this wall now, when its reason is said instead.
    private func scope(_ knob: Knob) -> String? {
        store.inactive[knob.name] == nil ? TuningCopy.applies(knob.applies) : nil
    }

    /// scope is the row's scope line after the group has left off repeats.
    private func rowState(_ knob: Knob, scope: String?) -> TuningRowState {
        let value = wallValue(knob)
        let def = defaultValue(knob)
        let reason = store.inactive[knob.name]
        let locked = knob.restart && panel.comingBack
        return TuningRowState(
            shown: dragging[knob.name] ?? value,
            defaultValue: def,
            changed: def.map { abs(value - $0) > max(knob.step / 2, 1e-6) } ?? false,
            greyed: reason != nil,
            holding: holding.contains(knob.name),
            pending: knob.restart && holding.contains(knob.name),
            note: reason ?? (locked ? "Available when the panel is back." : knob.note),
            applies: scope,
            problem: store.rowProblems[knob.name])
    }

    /// Readable either way: rows switch colours when turned off rather
    /// than fading.
    private func rowEnabled(_ knob: Knob) -> Bool {
        canWrite && store.inactive[knob.name] == nil && !(knob.restart && panel.comingBack)
    }

    @ViewBuilder private func row(_ knob: Knob, scope: String?) -> some View {
        let state = rowState(knob, scope: scope)
        if knob.isBool {
            TuningToggleRow(knob: knob, state: state) { on in set(knob, on ? 1 : 0) }
                .disabled(!rowEnabled(knob))
        } else if knob.isChoice {
            TuningChoiceRow(knob: knob, state: state, choose: { set(knob, $0) }, useDefault: { useDefault(knob) })
                .disabled(!rowEnabled(knob))
        } else {
            TuningSliderRow(knob: knob, state: state, useDefault: { useDefault(knob) }, actions: railActions(knob))
                .disabled(!rowEnabled(knob))
        }
    }

    private var measured: some View {
        let gains = [wall.state.wbR, wall.state.wbG, wall.state.wbB]
        // Within 0.005 of 1 is the uncorrected wall, as True colour reads it.
        let corrected = gains.contains { abs($0 - 1) > 0.005 }
        // Each pair is kept whole, so a narrow row breaks between pairs and
        // never between a letter and its number.
        let pairs = zip(["R", "G", "B"], gains).map { "\($0.0)\u{00A0}" + String(format: "%.2f", $0.1) }
        return TuningFactRow(title: "Measured correction",
                             parts: corrected ? pairs : ["Not measured"],
                             note: corrected ? "From True colour. It multiplies the gains above. Return to defaults leaves it as it is."
                                             : "True colour can measure it with your camera.",
                             spoken: corrected ? String(format: "red %.2f, green %.2f, blue %.2f", gains[0], gains[1], gains[2]) : nil)
            .accessibilityIdentifier("tuning.measured")
    }

    private func syncHolding() { store.holding = !holding.isEmpty }

    private func railActions(_ knob: Knob) -> TuningRailActions {
        let name = knob.name
        return TuningRailActions(
            began: { holding.insert(name); syncHolding() },
            moved: { v in
                dragging[name] = v
                // A launch flag waits for the finger to come off. Everything
                // else follows the drag, a write every 0.12 s at most.
                if !knob.restart { liveWrite(knob, v) }
            },
            ended: { v in holding.remove(name); syncHolding(); commit(knob, v) },
            cancelled: { holding.remove(name); syncHolding(); dragging[name] = nil },
            adjusted: { v in
                dragging[name] = v
                holding.insert(name); syncHolding()
                schedule(knob, v)
            })
    }

    private func liveWrite(_ knob: Knob, _ v: Double) {
        let now = Date()
        if let last = lastLive[knob.name], now.timeIntervalSince(last) < 0.12 { return }
        lastLive[knob.name] = now
        if isLegacyCeiling(knob) {
            Task { _ = await wall.updateRoutine([knob.name: v]) }
        } else {
            Task { await store.send(knob.name, v) }
        }
    }

    /// VoiceOver steps one value at a time, so the write waits 0.8 s after
    /// the last one: several swipes on a launch flag cost one restart.
    private func schedule(_ knob: Knob, _ v: Double) {
        commits[knob.name]?.cancel()
        commits[knob.name] = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commits[knob.name] = nil
            holding.remove(knob.name); syncHolding()
            commit(knob, v)
        }
    }

    /// The final value, once. The finger's value stays on screen until the
    /// wall has answered, then the wall's answer takes over.
    private func commit(_ knob: Knob, _ v: Double) {
        let name = knob.name
        commits[name]?.cancel(); commits[name] = nil
        Taps.commit()
        if isLegacyCeiling(knob) {
            Task {
                // An older brain: /state, which drops a write while one is
                // in flight, so the release value is tried until it lands.
                for _ in 0..<6 {
                    if await wall.updateRoutine([name: v]) { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if dragging[name] == v { dragging[name] = nil }
            }
            return
        }
        Task {
            await store.idle()
            if store.values[name] != v {
                await store.send(name, v, isBool: knob.isBool); await store.idle()
            } else {
                // The last live write already landed it, and live writes
                // are not logged, so the release is logged here once.
                store.noteCommitted(name)
            }
            if dragging[name] == v { dragging[name] = nil }
            renew()
        }
    }

    /// A switch or a choice: shown at once, sent at once.
    private func set(_ knob: Knob, _ v: Double) {
        let name = knob.name
        dragging[name] = v
        Taps.detent(intensity: 0.4)
        Task {
            await store.send(name, v, isBool: knob.isBool)
            await store.idle()
            dragging[name] = nil
            renew()
        }
    }

    private func useDefault(_ knob: Knob) {
        guard let d = defaultValue(knob) else { return }
        Taps.commit()
        if isLegacyCeiling(knob) {
            Task { _ = await wall.updateRoutine([knob.name: d]) }
            return
        }
        Task {
            await store.send(knob.name, d, isBool: knob.isBool)
            await store.idle()
            renew()
        }
    }

    // MARK: Start over

    /// A reset relaunches the panel program. With no panel, or a program
    /// that is not running, nothing restarts, and the copy does not say so.
    private var resetRestarts: Bool { !absent && !(live && panel == .stopped) }

    /// Names the two values the owner may not have settled: the shipped
    /// spatial dither and row settle time are not the renderer script's own
    /// fallbacks, and a reset writes them. Each is named only when it is off
    /// its default now, so the question never promises a change that will
    /// not happen.
    private var confirmText: String {
        let named = ["dither", "addr_settle_ns"].compactMap { name -> (title: String, value: String)? in
            guard let knob = knob(name), let d = store.defaults[name], store.isChanged(knob) else { return nil }
            return (knob.title, TuningStore.format(d, knob: knob))
        }
        return TuningCopy.resetQuestion(anyChanged: store.changedCount > 0, restarts: resetRestarts, named: named)
    }

    private var startOver: some View {
        // Never while the panel is coming back, so a reset can not meet a
        // 409 and read as "not confirmed".
        let off = !live || store.busy || store.sending || panel.comingBack
        return VStack(alignment: .leading, spacing: 10) {
            Text("Start over").font(.ui(ax ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
            // The question repeats the intro, so while it is asked the
            // question stands alone.
            if confirmingReset {
                Text(confirmText).font(.ui(ax ? 11 : 14)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tuning.reset.question")
                // One name for the action everywhere: the button that asks,
                // this one, and the status line while it runs.
                TuningTextButton(title: store.resetting ? "Returning…" : "Return to defaults", tint: Ink.signal,
                                 size: ax ? 12 : 15, fullWidth: ax) { reset() }
                    .disabled(off).accessibilityIdentifier("tuning.reset.confirm")
                TuningTextButton(title: "Keep my settings", size: ax ? 12 : 15, fullWidth: ax) { confirmingReset = false }
                    .disabled(store.resetting).accessibilityIdentifier("tuning.reset.keep")
            } else {
                Text(TuningCopy.startOver(restarts: resetRestarts))
                    .font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                TuningTextButton(title: "Return to defaults", size: ax ? 12 : 15, fullWidth: ax) {
                    withAnimation(reduce ? nil : .easeInOut(duration: 0.18)) { confirmingReset = true }
                }
                .disabled(off).accessibilityIdentifier("tuning.reset")
            }
            if let resetProblem {
                Label(resetProblem, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("tuning.reset.problem")
            }
            if let resetNotice {
                Text(resetNotice).font(.ui(14)).foregroundStyle(stone).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tuning.reset.notice")
            }
        }
        .padding(.top, 8)
        .id("tuning.startOver")
        .scrollAnchor("tuning.startOver.anchor")
    }

    private func reset() {
        guard live, !store.busy else { return }
        resetProblem = nil; resetNotice = nil
        Task { await performReset() }
    }

    private func performReset() async {
        if await store.reset() {
            confirmingReset = false
            resetNotice = store.panelState.comingBack ? "Defaults restored. The panel is restarting." : "Defaults restored."
            Taps.commit()
            renew()
        } else {
            resetProblem = store.problem ?? TuningCopy.resetNotConfirmed
            Taps.error()
        }
    }

    // MARK: The wall, read and watched

    /// Only while the scene is active: every 5 s, 1 s while the panel is
    /// coming back or a reset is out, 2 s while our pattern is up. It picks
    /// up changes from other phones and the voice.
    private func poll() async {
        guard scene == .active else { return }
        store.log = { FlightLog.note("TUNE", $0) }
        while !Task.isCancelled {
            if live {
                let host = wall.host
                if readHost != host || (!loaded && !store.readFailed && !store.unsupported && !store.reading) {
                    readHost = host
                    await store.load(host: host)
                } else if loaded {
                    await store.refresh(host: host)
                }
                await display.refresh(on: wall)
            }
            let seconds: Double = panel.comingBack || store.resetting ? 1 : ours ? 2 : 5
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        }
    }

    /// The panel came back: said for 4 s, felt once, and read aloud.
    private func back(_ at: Date?) {
        guard let at else { return }
        let said: String
        switch store.justBackCause {
        case .reset?: said = "Defaults restored"; resetNotice = "Defaults restored."
        case .setting?: said = "Panel back with the new setting"
        default: said = "Panel back"
        }
        backNote = said
        Taps.landed()
        AccessibilityNotification.Announcement(said).post()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if store.justBack == at { backNote = nil }
        }
    }

    // MARK: Capture hooks

    #if DEBUG
    /// -tuning-tab picture|listening, -tuning-pattern <pattern>,
    /// -tuning-state pattern|finished|reset-confirm|reset-done,
    /// -tuning-send name=value, -tuning-adjust name=steps, -tuning-knob
    /// <name>, -tuning-scrolled (to the first group, under the strip). The ones that change a wall (reset-done,
    /// -tuning-send and -tuning-adjust) only run against a loopback address,
    /// so a stray argument cannot restart or reset a real wall.
    /// -tuning-adjust takes the VoiceOver path, one step at a time, because
    /// XCUITest on iOS cannot send increment or decrement.
    private func hooks(_ proxy: ScrollViewProxy) async {
        guard !hooked else { return }
        hooked = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        if let raw = value("-tuning-tab"), let chosen = Tab(rawValue: raw) { tab = chosen }
        let want = value("-tuning-state"), send = value("-tuning-send"), focus = value("-tuning-knob")
        let adjust = value("-tuning-adjust")
        let scroll = args.contains("-tuning-scrolled")
        guard want != nil || send != nil || adjust != nil || focus != nil || scroll else { return }
        let loopback = wall.host.hasPrefix("127.0.0.1") || wall.host.hasPrefix("localhost")
        var tries = 0
        while !live, tries < 40 { tries += 1; try? await Task.sleep(for: .milliseconds(250)) }
        tries = 0
        while !loaded, !store.unsupported, !store.readFailed, tries < 40 { tries += 1; try? await Task.sleep(for: .milliseconds(250)) }
        switch want {
        case "pattern", "finished":
            let item = value("-tuning-pattern").flatMap(TuningPattern.init(rawValue:)) ?? .darkSteps
            await put(item)
            // Ends only a pattern the wall confirmed, so a failed start is
            // never captured as finished.
            if want == "finished", ours { await put(.wall) }
        // The hooks scroll to a point 64 pt above their target, so the
        // 56 pt pinned strip does not cover its first lines.
        case "reset-confirm":
            confirmingReset = true
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo("tuning.startOver.anchor", anchor: .top)
        case "reset-done" where loopback:
            confirmingReset = true
            await performReset()
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo("tuning.startOver.anchor", anchor: .top)
        default: break
        }
        if let send, loopback, let eq = send.firstIndex(of: "=") {
            let name = String(send[..<eq]), raw = String(send[send.index(after: eq)...])
            let sent: Any
            switch raw {
            case "true": sent = true
            case "false": sent = false
            default: sent = Double(raw) ?? 0
            }
            await store.send(patch: [name: sent], for: name)
        }
        if let adjust, loopback, let eq = adjust.firstIndex(of: "="), let target = knob(String(adjust[..<eq])),
           let steps = Int(adjust[adjust.index(after: eq)...]) {
            for _ in 0..<abs(steps) {
                let now = dragging[target.name] ?? wallValue(target)
                // The rail's own VoiceOver step, so the test covers its math.
                railActions(target).adjusted(TuningStore.stepped(now, up: steps > 0, knob: target))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        if let focus, let target = knob(focus) {
            if let group = store.groups.first(where: { $0.key == target.group }) { tab = group.tab == "listening" ? .listening : .picture }
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo("tuning.knob.\(focus).anchor", anchor: .top)
        } else if scroll {
            // The tab's first group, with the patterns just gone under the
            // pinned strip, so the strip shows in place of their state line.
            try? await Task.sleep(for: .milliseconds(300))
            let first = store.groups.first { $0.tab == tab.rawValue }
            proxy.scrollTo(first.map { "tuning.group.\($0.key).anchor" } ?? "tuning.patterns", anchor: .top)
        }
    }
    #endif
}

private extension View {
    /// A 1 pt point 64 pt above this view, named for ScrollViewProxy.
    /// scrollTo(anchor: .top) puts a view's top edge at the top of the
    /// scroll view, which is where the 56 pt pinned strip sits once the
    /// preview has scrolled away, so the capture hooks scroll here instead
    /// and the view's title line lands just below the strip. The alignment
    /// guide moves it in layout, not only in drawing, so the scroll sees it.
    func scrollAnchor(_ id: String) -> some View {
        background(alignment: .top) {
            Color.clear.frame(width: 1, height: 1)
                .id(id)
                .alignmentGuide(.top) { $0[.top] + 64 }
                .accessibilityHidden(true)
        }
    }
}

/// See PanelTuningPage.geometry.
private final class PinGeometry {
    /// Unmeasured, the line is taken as far below, so the strip never
    /// shows before the page has been laid out.
    var stateBottom: CGFloat = .infinity
    var scrolled: CGFloat = 0
}

/// Pattern pixels are made once per pattern and side: the preview, the
/// swatches and the pinned strip all redraw often.
@MainActor private enum TuningPatternCache {
    private static var made: [String: [UInt8]] = [:]
    private static var swatches: [TuningPattern: CGImage] = [:]

    static func pixels(_ pattern: TuningPattern, side: Int) -> [UInt8] {
        let key = "\(pattern.rawValue)|\(side)"
        if let hit = made[key] { return hit }
        let fresh = pattern.pixels(side: side)
        made[key] = fresh
        return fresh
    }

    /// The 64 x 64 composition as an sRGB bitmap, the colour space
    /// Color(red:green:blue:) used when the swatches were drawn as rects.
    static func swatch(_ pattern: TuningPattern) -> CGImage? {
        if let hit = swatches[pattern] { return hit }
        let side = 64
        let rgb = pixels(pattern, side: side)
        guard rgb.count == side * side * 3 else { return nil }
        var rgbx = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            rgbx[i * 4] = rgb[i * 3]; rgbx[i * 4 + 1] = rgb[i * 3 + 1]; rgbx[i * 4 + 2] = rgb[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        swatches[pattern] = image
        return image
    }
}
