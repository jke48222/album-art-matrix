import SwiftUI
import UIKit

/// Wall health: how the computer behind the panels is doing, one /health
/// reading at a time. Problems come first with what to do, then the two
/// measured tiles, then every named part in plain words.
///
/// Read only. The one write is the panel program restart, offered only when
/// the panels stop taking pictures. What a reading means, and every sentence
/// here, lives in WallVitals.swift, where scripts/test_wall_vitals.swift
/// checks it without a screen.
struct HealthPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    /// The Settings landing's reading. Seeds the page, and every new reading
    /// is written back, so the Settings row always describes this one.
    @Binding var vitals: Vitals?

    @State private var reading: Vitals?
    /// The wall `reading` came from. A new address starts from nothing.
    @State private var readHost: String?
    @State private var lastFailed = false
    /// A Check now or pull to refresh failed since the last answer. That,
    /// or a reading past HealthRules.staleAfter, makes the page stale. One
    /// failed background poll only changes the freshness line.
    @State private var manualFailed = false
    @State private var checking = false
    /// A read has finished since polling started, so a reading carried in
    /// from Settings is not called stale before the page could check.
    @State private var attempted = false
    @State private var expanded: Set<HealthPart> = []
    @State private var othersOpen = false
    /// What the last reading of this visit said, so feedback fires only
    /// when that changes, never on a routine poll.
    @State private var lastLevel: HealthLevel?
    @State private var lastLead: HealthPart?
    @State private var failingNoted = false
    @State private var restarting = false
    @State private var restartNote: String?
    #if DEBUG
    @State private var debugLink: HealthLink?
    @State private var fixture: String?
    @State private var hooked = false
    #endif
    /// Font.custom scales with .body, and so does this, so the status dot
    /// stays centred on the headline's first line at every text size.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 17

    /// The Care section's tint on the Settings row that opened this page.
    private let slate = Color(hex: 0xACBDD0)
    private let ground = Color(hex: 0x14171A)
    private var compact: Bool { typeSize.isAccessibilitySize }

    private var link: HealthLink {
        #if DEBUG
        if let debugLink { return debugLink }
        #endif
        switch wall.link {
        case .live: return .live
        case .searching: return .searching
        case .offline: return .offline
        // The automatic stand-in is already looking for the wall, so only
        // the owner's own choice of this phone is offered a look.
        case .standIn: return .standIn(chosen: wall.offersLookAgain)
        }
    }

    private var report: HealthReport? { reading.map(HealthReport.init(vitals:)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Ticks every 5 s, so "Checked 25 seconds ago" and the stale
                // rule follow the clock between readings.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    page(HealthScreen(link: link, report: report, now: max(context.date, .now), lastFailed: lastFailed,
                                      manualFailed: manualFailed, checking: checking, attempted: attempted))
                }
                // Full width whatever the text length, so a short state
                // (searching, the stand-in) is not a narrow centred column.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .refreshable { await read(manual: true) }
            .onAppear {
                #if DEBUG
                applyHooks()
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "-health-scroll"), args.indices.contains(i + 1) {
                    let target = "health.\(args[i + 1])"
                    Task { try? await Task.sleep(for: .milliseconds(600)); proxy.scrollTo(target, anchor: .top) }
                }
                #endif
            }
        }
        // The ground fills the page edge to edge, under the bar too.
        .background { ground.ignoresSafeArea() }
        .foregroundStyle(Ink.ink).tint(slate)
        .navigationTitle("Wall health").navigationBarTitleDisplayMode(.inline)
        // A solid bar in the page's own ground: what scrolls under it is
        // hidden, not frosted.
        .toolbarBackground(ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // Polls only while this page is on screen, the app is in front and
        // the wall answers. .task ends when a page is pushed over this one.
        .task(id: "\(wall.host)|\(scene == .active)|\(link == .live)") { await poll() }
    }

    private func page(_ screen: HealthScreen) -> some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            hero(screen)
            if screen.lookAgain || screen.addressLink { offlineActions(screen) }
            if let report = screen.report {
                if screen.dimmed {
                    // Heads everything below, notices included: all of it is
                    // the last reading, not the wall now.
                    Text("LAST READING").font(.machine(compact ? 8 : 9)).tracking(compact ? 0 : 0.8).foregroundStyle(Ink.dim)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("health.lastReading")
                }
                if !report.problems.isEmpty { problems(report, screen: screen) }
                tiles(report, dimmed: screen.dimmed)
                checks(report, screen: screen)
                Text(report.footnote)
                    .font(.ui(compact ? 9 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .id("health.footnote").accessibilityIdentifier("health.footnote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hero

    private func hero(_ screen: HealthScreen) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // No eyebrow above the headline: the bar already names the page,
            // and the name is said once at every text size.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: compact ? 10 : 12) {
                    HealthStatusDot(dot: screen.dot, size: dotSize, accent: slate)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + verdictCapHeight / 2 }
                    // display(36): measured with the bundled Technor at 375 pt
                    // (305 pt beside the dot), every verdict fits two lines at
                    // the default size. The widest line is "Needs attention."
                    // at 294 pt. Up to xxxLarge the longest word, "connected."
                    // at 267 pt, still fits, so no word breaks. From xLarge,
                    // "Picture updates stopped." takes three lines. At
                    // accessibility sizes the longest word at ui(18) is 291 pt
                    // at AX5, under the 298 pt beside the 18 pt dot.
                    Text(screen.verdict).font(compact ? .ui(18, .semibold) : .display(36)).tracking(compact ? 0 : -1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(screen.summary).font(.ui(compact ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            // One element: the headline and what it means, read together.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(screen.verdict).accessibilityValue(screen.summary)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("health.verdict")
            freshnessRow(screen)
        }
    }

    /// The status dot. At accessibility sizes it grows with the headline,
    /// to under half its cap height, so its colour still reads beside
    /// letters several times the default size.
    private var dotSize: CGFloat { compact ? max(10, verdictCapHeight * 0.45) : 12 }

    /// The headline's cap height at this text size. The dot's centre sits
    /// half of it above the baseline, on the middle of the first line.
    private var verdictCapHeight: CGFloat {
        let size = (compact ? 18 : 36) * bodyScale / 17
        return UIFont(name: compact ? Face.uiSemibold : Face.display, size: size)?.capHeight ?? size * 0.7
    }

    @ViewBuilder private func freshnessRow(_ screen: HealthScreen) -> some View {
        if screen.freshness == nil {
            // Nothing to pair it with (no reading yet): the button sits
            // under the summary, not alone at the far edge.
            checkButton(screen)
        } else if compact {
            VStack(alignment: .leading, spacing: 4) { freshness(screen); checkButton(screen) }
        } else {
            // The long "Could not check…" line and the button do not
            // share a 375 pt row, so the button then moves under it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { freshness(screen); Spacer(minLength: 8); checkButton(screen) }
                VStack(alignment: .leading, spacing: 4) { freshness(screen); checkButton(screen) }
            }
        }
    }

    @ViewBuilder private func freshness(_ screen: HealthScreen) -> some View {
        if let text = screen.freshness {
            Text(text).font(.ui(compact ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("health.freshness")
        }
    }

    @ViewBuilder private func checkButton(_ screen: HealthScreen) -> some View {
        if let title = screen.check {
            Button { Task { await read(manual: true) } } label: {
                HStack(spacing: 7) {
                    if checking { ProgressView().controlSize(.small).tint(slate) } else { Image(systemName: "arrow.clockwise") }
                    Text(checking ? "Checking…" : title)
                }
                .font(.ui(compact ? 12 : 14, .semibold)).foregroundStyle(slate)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            // PressStyle adds no fade of its own, so the slate label stays
            // readable while a read is in flight.
            .buttonStyle(PressStyle(scale: 0.97)).disabled(checking)
            .accessibilityIdentifier("health.check")
        }
    }

    // MARK: Offline

    private func offlineActions(_ screen: HealthScreen) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if screen.lookAgain {
                // The same action as the Settings wall card's look again. The
                // capsule holds one line, so its type stops at accessibility2
                // and a long press shows the label large.
                PrimaryButton(title: "Look for your wall", accent: slate) { wall.lookForWallAgain() }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("health.lookAgain")
            }
            if screen.addressLink {
                // Settings' own route, so the Connection page arrives with
                // the bindings Settings gives it.
                NavigationLink(value: SettingsDestination.addresses) {
                    Text("Check the wall’s address").quietLink()
                        .multilineTextAlignment(.leading).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98)).accessibilityIdentifier("health.address")
            }
        }
    }

    // MARK: Problems

    private func problems(_ report: HealthReport, screen: HealthScreen) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(report.problems) { finding in
                // Signal red is under 4.5:1 as text on this ground, so act
                // titles are set in ink with the red kept for the symbol.
                // A last reading is faint, with its titles in dim.
                let act = finding.level == .act
                let tint = screen.dimmed ? Ink.faint : act ? Ink.signal : Ink.tile
                let detail = screen.detail(for: finding)
                Group {
                    if screen.titlesNotice(finding) {
                        CreativeConnectionNotice(title: finding.noticeTitle, detail: detail, symbol: finding.part.noticeSymbol,
                                                 tint: tint, titleInk: screen.dimmed ? Ink.dim : act ? Ink.ink : nil)
                    } else {
                        // The headline already names this problem, so its
                        // notice gives only what to do.
                        HealthLeadNotice(detail: detail, symbol: finding.part.noticeSymbol, tint: tint)
                    }
                }
                .accessibilityIdentifier("health.problem.\(finding.part.rawValue)")
                if finding.part == .panels, act, screen.phase == .report || restartNote != nil {
                    restartControl(button: screen.phase == .report)
                }
            }
        }
    }

    /// Offered under the panels problem only. The button shows while the
    /// wall answers. The brain relaunches the panel program itself, so this
    /// needs nothing the plug advice does not already assume. The note stays
    /// on a stale or offline reading too, because after a restart that did
    /// not help it is where the plug advice is said.
    private func restartControl(button: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if button {
                Button { Task { await restartPanels() } } label: {
                    HStack(spacing: 7) {
                        if restarting { ProgressView().controlSize(.small).tint(slate) } else { Image(systemName: "arrow.counterclockwise") }
                        Text(restarting ? "Restarting…" : "Restart the panel program").multilineTextAlignment(.leading)
                    }
                    .font(.ui(compact ? 12 : 14, .semibold)).foregroundStyle(slate)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.97)).disabled(restarting)
                .accessibilityIdentifier("health.restartPanels")
            }
            if let restartNote {
                Text(restartNote).font(.ui(compact ? 10 : 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.restartNote")
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder private func tiles(_ report: HealthReport, dimmed: Bool) -> some View {
        // Both numbers roll only when motion is allowed.
        let still = reduceMotion || Motion.forcedReduced
        let temperature = report.temperature.map {
            HealthTemperatureTile(tile: $0, dimmed: dimmed, compact: compact, accent: slate, reduceMotion: still)
        }
        let frames = HealthFramesTile(tile: report.frames, dimmed: dimmed, compact: compact, accent: slate, reduceMotion: still)
        if compact {
            VStack(spacing: 12) { temperature; frames }
        } else {
            // Equal heights: each tile fills the height of the taller one.
            HStack(alignment: .top, spacing: 12) { temperature; frames }.fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Checks

    @ViewBuilder private func checks(_ report: HealthReport, screen: HealthScreen) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.problems.isEmpty {
                Text(screen.checksHeader).font(.ui(compact ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                rows(report.checks, dimmed: screen.dimmed)
            } else if !report.checks.isEmpty {
                Button {
                    withAnimation(Motion.settle) { othersOpen.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(screen.othersTitle).font(.ui(compact ? 13 : 17, .semibold)).multilineTextAlignment(.leading)
                        Text("\(report.checks.count)").font(.machine(compact ? 8 : 10)).foregroundStyle(Ink.dim)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(slate)
                            .rotationEffect(.degrees(othersOpen ? 0 : -90))
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.99))
                .accessibilityLabel(screen.othersTitle)
                .accessibilityValue("\(report.checks.count) checks, \(othersOpen ? "shown" : "hidden")")
                .accessibilityHint(othersOpen ? "Hides the checks that passed" : "Shows the checks that passed")
                .accessibilityIdentifier("health.others")
                if othersOpen { rows(report.checks, dimmed: screen.dimmed).transition(.opacity) }
            }
        }
        .id("health.checks")
    }

    private func rows(_ checks: [HealthCheck], dimmed: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(checks) { check in
                HealthRow(check: check, expanded: expanded.contains(check.part), accent: slate, compact: compact, dimmed: dimmed) {
                    withAnimation(Motion.settle) { expanded.formSymmetricDifference([check.part]) }
                }
            }
        }
    }

    // MARK: Reading

    private func poll() async {
        #if DEBUG
        applyHooks()
        if fixture != nil { return }
        #endif
        if readHost != wall.host { adopt(wall.host) }
        guard scene == .active, link == .live else { return }
        // A new stretch of polling: a read starts at once. A failure from
        // before the app went to the background or the wall went offline
        // no longer says "Could not check" next to the verdict. The reading
        // keeps its verdict until this read ends, because "the latest check
        // got no reply" would be untrue before one has been made.
        attempted = false; lastFailed = false
        while !Task.isCancelled {
            await read(manual: false)
            do { try await Task.sleep(for: .seconds(HealthRules.poll)) } catch { return }
        }
    }

    /// A reading belongs to the wall that sent it. The first time, the
    /// landing's reading is this wall's, so it seeds the page.
    private func adopt(_ host: String) {
        reading = readHost == nil ? vitals : nil
        readHost = host
        lastFailed = false; manualFailed = false; attempted = false; failingNoted = false
        lastLevel = nil; lastLead = nil; restartNote = nil; expanded = []
    }

    private func read(manual: Bool) async {
        #if DEBUG
        if fixture != nil { return }
        #endif
        guard link == .live, !checking else { return }
        let host = wall.host
        checking = true
        let fresh = await Vitals.read(host: host)
        checking = false
        // A read cut short by leaving the page says nothing about the wall.
        guard !Task.isCancelled, wall.host == host, readHost == host else { return }
        attempted = true
        if let fresh {
            reading = fresh
            vitals = fresh
            lastFailed = false; manualFailed = false; failingNoted = false
            react(to: HealthReport(vitals: fresh))
        } else {
            lastFailed = true
            if manual { manualFailed = true }
            if !failingNoted { failingNoted = true; FlightLog.note("HEALTH", "no reading from \(host)") }
        }
    }

    /// Feedback when what the wall is doing changes, never on a routine
    /// poll, and never for the first reading of a visit.
    private func react(to report: HealthReport) {
        let previous = lastLevel, previousLead = lastLead
        lastLevel = report.level; lastLead = report.lead
        guard let previous, previous != report.level || previousLead != report.lead else { return }
        FlightLog.note("HEALTH", ([report.level.name] + (report.lead.map { [$0.rawValue] } ?? [])).joined(separator: " "))
        AccessibilityNotification.Announcement("Wall health: \(report.verdict)").post()
        if report.level == .act && previous != .act { Taps.error() }
        if report.lead != .panels { restartNote = nil }
    }

    private func restartPanels() async {
        guard !restarting, link == .live else { return }
        #if DEBUG
        // A fixture forces the link live, but a capture never touches the
        // network. The note for a restart that did not help is still shown,
        // so that state can be captured without a wall.
        if fixture != nil {
            restartNote = PanelProgram.note(.relaunching, stillFailing: true)
            return
        }
        #endif
        restarting = true; restartNote = nil
        defer { restarting = false }
        let host = wall.host
        let (answer, said) = await PanelProgram.restart(host: host)
        FlightLog.note("HEALTH", "restart the panel program at \(host): \(said ?? "no answer")")
        guard wall.host == host else { return }
        if answer == .relaunching { Taps.commit() } else { Taps.error() }
        // The program takes a moment to come back and take a picture, so
        // the wall is read again after it has had one.
        try? await Task.sleep(for: .seconds(3))
        while checking { try? await Task.sleep(for: .milliseconds(100)) }
        // Read like a background poll: the owner did not ask for this read,
        // so one that fails is a hiccup and does not turn the page stale.
        await read(manual: false)
        guard wall.host == host else { return }
        let stillFailing = lastFailed || (report?.problems.contains { $0.part == .panels && $0.level == .act } ?? true)
        restartNote = PanelProgram.note(answer, stillFailing: stillFailing)
        AccessibilityNotification.Announcement(restartNote ?? "The panel program restarted.").post()
    }

    #if DEBUG
    /// Capture hooks. -health-fixture decodes an authored reading instead of
    /// asking the wall and never polls. -health-link is this page's own
    /// idea of the link, never written to the session.
    private func applyHooks() {
        guard !hooked else { return }
        hooked = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        switch value("-health-link") {
        case "offline": debugLink = .offline
        case "searching": debugLink = .searching
        case "standin": debugLink = .standIn(chosen: true)
        case "standin-auto": debugLink = .standIn(chosen: false)
        default: break
        }
        if let name = value("-health-fixture") {
            fixture = name
            // A fixture capture must not depend on a wall answering.
            if debugLink == nil { debugLink = .live }
            readHost = wall.host
            let now = Date()
            switch name {
            case "loading": checking = true
            case "unreadable": lastFailed = true
            case "stale":
                reading = HealthFixtures.vitals("steady", receivedAt: now.addingTimeInterval(-95))
                lastFailed = true; attempted = true
            // Not attempted, so a capture taken a while after launch is not
            // turned stale by the clock.
            default: reading = HealthFixtures.vitals(name, receivedAt: debugLink == .offline ? now.addingTimeInterval(-300) : now)
            }
            if let reading { vitals = reading }
        } else if debugLink != nil {
            // -health-link alone is that link with no reading at all, so
            // nothing is seeded from Settings and nothing is read.
            fixture = "none"
        }
        if let part = value("-health-explain") {
            expanded = part == "all" ? Set(HealthPart.allCases) : Set([HealthPart(rawValue: part)].compactMap { $0 })
        }
        if args.contains("-health-others-open") { othersOpen = true }
    }
    #endif
}

// MARK: - Parts

private struct HealthStatusDot: View {
    let dot: HealthScreen.Dot
    let size: CGFloat
    let accent: Color

    var body: some View {
        Group {
            switch dot {
            case .progress: ProgressView().controlSize(.small).tint(accent)
            case .quiet: Circle().fill(Ink.faint).frame(width: size, height: size)
            case .level(let level):
                Circle().fill(level == .act ? Ink.signal : level == .watch ? Ink.tile : Ink.moss).frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The notice for a lone problem the headline already names: the symbol and
/// what to do, drawn like CreativeConnectionNotice without its title line.
private struct HealthLeadNotice: View {
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(detail).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.ui(16, .semibold)).foregroundStyle(tint).accessibilityHidden(true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// The two measured tiles' frame: a quiet slate wash, no stroke, no shadow.
private struct HealthTile<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A tile's first row: its name, and a status word that moves under it when
/// the two do not share the tile's width (375 pt phones, larger text).
private struct HealthTileHeader<Status: View>: View {
    let title: String
    let compact: Bool
    @ViewBuilder let status: Status

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) { name; Spacer(minLength: 4); status }
            VStack(alignment: .leading, spacing: 2) { name; status }
        }
    }

    private var name: some View {
        Text(title).font(.ui(compact ? 11 : 13, .medium)).foregroundStyle(Ink.dim)
    }
}

/// A number with its unit beside it, or under it when the tile is narrow.
private struct HealthTileValue: View {
    let number: Int
    let unit: String
    let dimmed: Bool
    let compact: Bool
    /// No default, so no tile can forget to pass Reduce Motion on.
    let reduceMotion: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) { figure; label }
            VStack(alignment: .leading, spacing: 0) { figure; label }
        }
    }

    private var figure: some View {
        Text("\(number)").font(.machine(compact ? 20 : 30)).foregroundStyle(dimmed ? Ink.dim : Ink.ink)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(number)))
            .animation(reduceMotion ? nil : Motion.settle, value: number)
    }

    // Units and captions are text, so they take dim: faint is under 4.5:1
    // on the tile's wash.
    private var label: some View {
        Text(unit).font(.machine(11)).foregroundStyle(Ink.dim)
    }
}

private struct HealthTemperatureTile: View {
    let tile: HealthReport.Temperature
    let dimmed: Bool
    let compact: Bool
    let accent: Color
    let reduceMotion: Bool

    var body: some View {
        HealthTile(accent: accent) {
            HealthTileHeader(title: "Temperature", compact: compact) { status }
            HealthTileValue(number: tile.celsius, unit: "°C", dimmed: dimmed, compact: compact, reduceMotion: reduceMotion)
            if compact {
                // The trace is left out at accessibility sizes, and the
                // range is said in words.
                if let words = tile.rangeWords { note(words) } else if let text = tile.note { note(text) }
            } else {
                if tile.trace.count >= 2 {
                    HealthTemperatureTrace(samples: tile.trace, color: dimmed ? Ink.faint : accent).frame(height: 40)
                }
                // No trace yet, or none kept by this wall: a line says so,
                // so the tile is not left with an empty lower half.
                if let text = tile.note { note(text) }
                if let window = tile.window, let range = tile.rangeCaption {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text(window); Spacer(minLength: 6); Text(range) }
                        VStack(alignment: .leading, spacing: 2) { Text(window); Text(range) }
                    }
                    .font(.machine(9)).foregroundStyle(Ink.dim)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature").accessibilityValue(tile.accessibilityValue(lastReading: dimmed))
        .accessibilityIdentifier("health.tile.temperature")
    }

    @ViewBuilder private var status: some View {
        // On a last reading "Normal" is left off: it would read as now.
        if let shown = tile.statusWord(lastReading: dimmed) {
            let word = Text(shown).font(.ui(compact ? 10 : 12, .semibold))
            switch tile.status {
            case .normal: word.foregroundStyle(Ink.dim)
            case .warm: word.foregroundStyle(dimmed ? Ink.dim : Ink.tile)
            case .hot:
                // Hot is said in ink: the signal dot beside it carries the colour.
                HStack(spacing: 5) {
                    Circle().fill(dimmed ? Ink.faint : Ink.signal).frame(width: 6, height: 6)
                    word.foregroundStyle(dimmed ? Ink.dim : Ink.ink)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.ui(compact ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
    }
}

private struct HealthFramesTile: View {
    let tile: HealthReport.Frames
    let dimmed: Bool
    let compact: Bool
    let accent: Color
    let reduceMotion: Bool

    var body: some View {
        HealthTile(accent: accent) {
            HealthTileHeader(title: "Frame rate", compact: compact) {
                if let status = tile.statusWord(lastReading: dimmed) {
                    Text(status).font(.ui(compact ? 10 : 12, .semibold)).foregroundStyle(tile.behind && !dimmed ? Ink.tile : Ink.dim)
                }
            }
            if let number = tile.perSecond {
                HealthTileValue(number: number, unit: "a second", dimmed: dimmed, compact: compact, reduceMotion: reduceMotion)
            } else if let word = tile.word {
                Text(word).font(.ui(compact ? 16 : 22, .semibold)).foregroundStyle(dimmed ? Ink.dim : Ink.ink)
            }
            if !compact {
                // The rail only means something against a target. Otherwise
                // an empty rail's height keeps the two tiles level.
                if let fraction = tile.fraction {
                    HealthFramesMeter(fraction: fraction, color: dimmed ? Ink.faint : accent)
                } else {
                    Color.clear.frame(height: 4)
                }
            }
            // The caption names the window first ("LAST MEASURED"), then
            // the sentence about it.
            let captions = tile.captions(lastReading: dimmed)
            if compact {
                if let words = tile.words(lastReading: dimmed) {
                    Text(words).font(.ui(10)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            } else if !captions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(captions, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
                .font(.machine(9)).foregroundStyle(Ink.dim)
            }
            if let note = tile.note {
                Text(note).font(.ui(compact ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame rate").accessibilityValue(tile.accessibilityValue)
        .accessibilityIdentifier("health.tile.frames")
    }
}

/// The last hour of temperature: a 1.5 pt line, no fill and no threshold,
/// scaled to the samples' own range with 2°C either side.
private struct HealthTemperatureTrace: View {
    let samples: [Vitals.TempSample]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2, let window = samples.map(\.ageS).max(), window > 0,
                  let lowest = samples.map(\.celsius).min(), let highest = samples.map(\.celsius).max() else { return }
            let low = lowest - 2, span = highest + 2 - low
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: size.width * (1 - sample.ageS / window),
                                    y: size.height * (1 - (sample.celsius - low) / span))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A paced animation against its target, drawn like the colour gains.
private struct HealthFramesMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.ink.opacity(0.09))
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4).accessibilityHidden(true)
    }
}

/// One named part: its value on the right, and what it means one tap away.
/// The press is PressStyle's own, so the toggle adds no second buzz.
private struct HealthRow: View {
    let check: HealthCheck
    let expanded: Bool
    let accent: Color
    let compact: Bool
    /// A last reading: titles fade to dim beside the live page's ink.
    let dimmed: Bool
    var toggle: () -> Void
    /// The info symbol grows with the text, held at 24 pt so it stays a
    /// mark beside the title rather than a second headline.
    @ScaledMetric(relativeTo: .body) private var infoSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: compact ? .firstTextBaseline : .center, spacing: 12) {
                    if !compact {
                        Image(systemName: check.part.rowSymbol).font(.system(size: 17)).foregroundStyle(dimmed ? Ink.dim : accent)
                            .frame(width: 24).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).font(.ui(compact ? 12 : 15, .semibold)).foregroundStyle(dimmed ? Ink.dim : Ink.ink)
                        // At accessibility sizes the value sits under the
                        // title, above a subtitle and an explanation in dim,
                        // so it is set in ink to stand apart from them.
                        if compact { Text(check.value).font(.ui(11, .medium)).foregroundStyle(dimmed ? Ink.dim : Ink.ink) }
                        if let subtitle = check.subtitle {
                            Text(subtitle).font(.ui(compact ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if !compact {
                        Text(check.value).font(.ui(14)).foregroundStyle(Ink.dim).multilineTextAlignment(.trailing)
                    }
                    Image(systemName: expanded ? "info.circle.fill" : "info.circle").font(.system(size: min(infoSize, 24))).foregroundStyle(Ink.faint)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 12).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.99))
            .accessibilityLabel(check.title)
            .accessibilityValue(check.subtitle.map { "\(check.value). \($0)" } ?? check.value)
            .accessibilityHint(expanded ? "Hides the explanation" : "Shows what this means")
            .accessibilityIdentifier("health.row.\(check.part.rawValue)")
            if expanded {
                // The next element after its row, so VoiceOver reads it right
                // after the value it explains.
                Text(check.explanation).font(.ui(compact ? 10 : 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, compact ? 0 : 36).padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("health.explain.\(check.part.rawValue)")
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.1)).frame(height: 1) }
    }
}
