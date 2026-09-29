import SwiftUI
import UIKit

/// The link from this phone to the wall, on one page: how it is now and why,
/// what to try when the wall is away, a read-only check of each step, what is
/// waiting to be sent, the wall's address, and what happened recently.
///
/// Everything above the check rows comes from WallSession (link, lastSync,
/// lastProblem, outbox, history), so this page cannot disagree with the
/// settings card, Control Center or the widgets. Only a check's results are
/// this page's own, and they are dated and cleared when the address or the
/// link changes under them.
struct ConnectionPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var type
    let accent: Color
    @Binding var services: WallServices?

    @State private var check = ConnectionCheckRun()
    @State private var watcher = NetworkWatcher()
    @State private var glow = TemporaryWallDisplay()
    @State private var glowTask: Task<Void, Never>? = nil
    @State private var glowing = false
    @State private var glowProblem: GlowProblem? = nil
    /// Another screen's display session holds the wall (its purpose), from
    /// the wall's state or a refused glow. Make it glow waits for it to end.
    @State private var heldBy: String? = nil
    /// The name the wall gives in its state while live: the name this
    /// address answers with right now.
    @State private var liveName: String? = nil
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var focusOnOpen = true
    /// The address just saved, while the page is still looking for it.
    @State private var savedHost: String? = nil
    #if DEBUG
    /// Set at creation for -connection-confirm-discard, so the confirm shows
    /// the moment a seeded queue does, however the page is re-created.
    @State private var confirmingDiscard = CommandLine.arguments.contains("-connection-confirm-discard")
    #else
    @State private var confirmingDiscard = false
    #endif
    /// When the last delivery started from Send now on this page, so its
    /// result does not claim the wall "came back".
    @State private var sentHere: Date? = nil
    @State private var showAllHistory = false
    /// The name.local suggestion is being tried before it is used.
    @State private var suggesting = false
    /// It did not answer, so it is not offered again this visit.
    @State private var suggestionHidden = false
    @State private var suggestionNotice: String? = nil
    @State private var logURL: URL? = nil
    #if DEBUG
    @State private var hooked = false
    /// The section a capture scrolled to, kept so the page can scroll to it
    /// again when the content above it changes height.
    @State private var scrollTarget: Section? = nil
    #endif

    /// The Care section's tint (SettingsSheet), this page's accent.
    private let slate = Color(hex: 0xACBDD0)
    /// A shade under the 0x121619 first drawn for this page, so faint and
    /// signal text clear 4.5:1 (4.54 and 4.61) as well as dim (5.9).
    private let ground = Color(hex: 0x0E1215)

    private struct GlowProblem: Equatable {
        var title: String
        var detail: String
    }

    private var ax: Bool { type.isAccessibilitySize }

    /// The link in the page's terms: LinkState, plus the owner's choice of
    /// this phone, which LinkState alone cannot tell from a stand-in that
    /// took over because no wall answered.
    ///
    /// The lights are left out here and read by HeroStatus alone: wall.state
    /// is set at every poll, and ten times a second from the stand-in, so a
    /// read in this body would redraw the whole page each time. Nothing
    /// else on the page depends on them.
    private var kind: LinkKind {
        switch wall.link {
        case .live: .live(lightsOff: false)
        case .searching: .searching
        case .offline(let since): .offline(since: since)
        case .standIn: wall.explicitStandIn ? .phoneOnly : .noWallFound
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { page }
                #if DEBUG
                .onAppear { runHooks(proxy) }
                // The sections above a capture's target change height as
                // the link settles, a check runs or a notice appears, which
                // moved the target under the bar. Scroll again after each.
                .onChange(of: layoutKey) { _, _ in
                    guard let target = scrollTarget else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .background { ground.ignoresSafeArea() }
        .foregroundStyle(Ink.ink).tint(slate)
        .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
        // A solid bar in the page's own ground, as on Wall health: what
        // scrolls under it is hidden, not frosted.
        .toolbarBackground(ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable { await wall.poll() }
        .task(id: scene) {
            guard scene == .active else { watcher.stop(); return }
            watcher.start()
            // Services come through the binding: the Settings sheet reads
            // them whenever the wall answers, for the Your Mac row too.
            logURL = FlightLog.prepareForShare()
        }
        .onChange(of: scene) { _, phase in
            // A glow never outlives the page being in front.
            if phase == .background { endGlow() }
        }
        .onDisappear {
            check.cancel()
            endGlow()
            watcher.stop()
        }
        .onChange(of: wall.host) { _, _ in
            // Results for one address say nothing about the next.
            check.cancel()
            check.clear()
            editing = false
            fieldFocused = false
            confirmingDiscard = false
            suggestionHidden = false
            suggestionNotice = nil
            glowProblem = nil
            heldBy = nil
            liveName = nil
        }
        // A refused glow names the screen that holds the wall. Ask again
        // every few seconds until it lets go, for a wall whose state does
        // not report its display session.
        .task(id: heldBy) {
            guard heldBy != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, wall.link.isLive else { continue }
                // Nil when the read failed, which says nothing either way.
                let holder = await LiveProbe.displayHolder(hostPort: wall.host)
                if !Task.isCancelled, holder == "", glowTask == nil { heldBy = nil; return }
            }
        }
        .onChange(of: kind.key) { _, _ in
            if !check.running { check.clear() }
            // "Looking for the wall at ..." holds only while it looks.
            if kind != .searching { savedHost = nil }
            if !kind.isLive { glowProblem = nil; heldBy = nil; liveName = nil }
            AccessibilityNotification.Announcement(ConnectionWords.headline(kind, problem: wall.lastProblem)).post()
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            // At accessibility sizes the way forward comes first, so the
            // fix is on the first screen. Live with changes waiting, that is
            // Send now, so the queue comes before the quiet links.
            if ax {
                if kind.isLive && !wall.outbox.contents.isEmpty {
                    waiting
                    actions
                } else {
                    actions
                    waiting
                }
                tryList
            } else {
                waiting
                tryList
                actions
            }
            anchored(.check) { checkSection }
            anchored(.address) { addressSection }
            anchored(.recent) { recentSection }
            anchored(.related) { relatedSection }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
    }

    /// Scroll anchors, for captures of the sections below the first screen.
    private enum Section: String { case check, address, recent, related }

    /// A section whose scroll anchor sits a bar's height above its header,
    /// so a scroll to it leaves the header clear of the inline bar. The
    /// anchor takes no room: it reaches up into the section before.
    private func anchored<Content: View>(_ section: Section, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.anchorLead).id(section)
                .allowsHitTesting(false).accessibilityHidden(true)
            content()
        }
        .padding(.top, -Self.anchorLead)
    }

    private static let anchorLead: CGFloat = 72

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            // No eyebrow above the headline: the bar already names the page,
            // as on Wall health. The display face splits words letter by
            // letter past accessibility2, so large type gets the interface
            // face instead.
            Text(ConnectionWords.headline(kind, problem: wall.lastProblem))
                .font(ax ? .ui(18, .semibold) : .display(40)).tracking(ax ? 0 : -1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("connection.headline")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HeroStatus(kind: kind, ax: ax, tint: slate)
                    if ConnectionWords.showsReason(kind), let reason = wall.lastProblemSentence {
                        AddressText(reason, large: ax).font(.ui(ax ? 10 : 13)).foregroundStyle(Ink.dim)
                            .accessibilityIdentifier("connection.reason")
                    }
                    // At large sizes the words need the width, so the
                    // picture and its caption go under them, not away.
                    if ax { HeroThumb(kind: kind).padding(.top, 8) }
                }
                Spacer(minLength: 8)
                if !ax { HeroThumb(kind: kind) }
            }
        }
    }

    // MARK: - Waiting to send

    /// Shown in every state while something waits: a queue kept from an
    /// earlier session still goes out when a wall answers. The page redraws
    /// on every poll, so the ten-minute gate is read against the clock here,
    /// and the minute timeline only moves the relative times.
    ///
    /// The header and the note belong to a queue. A finished delivery with
    /// nothing left waiting shows its result line alone.
    ///
    /// The page's own state is read here, outside the timeline's closure, so
    /// a change to it always redraws the section.
    @ViewBuilder private var waiting: some View {
        let contents = wall.outbox.contents
        let confirming = confirmingDiscard
        let here = sentHere
        if !contents.isEmpty || recentDelivery(now: Date()) != nil {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 14) {
                    if !contents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            header("Waiting to send")
                            // While the discard question stands in for Send
                            // now, a note pointing at Send now is left out.
                            if !(confirming && kind.isLive) {
                                Text(ConnectionWords.waitingNote(kind)).font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("connection.waiting.note")
                            }
                        }
                        VStack(spacing: 0) {
                            if !contents.keys.isEmpty {
                                waitingRow(OutboxWords.describe(keys: contents.keys, frame: false, clip: false),
                                           queuedLine(wall.outbox.patchAt), id: "connection.waiting.settings")
                            }
                            if contents.frame {
                                waitingRow("A picture", queuedLine(wall.outbox.frameAt), id: "connection.waiting.picture")
                            }
                            if contents.clip {
                                waitingRow("A clip", "Kept only while Tessera is open.", id: "connection.waiting.clip")
                            }
                        }
                    }
                    if let delivery = recentDelivery(now: context.date) {
                        deliveryView(delivery, now: context.date, fromHere: here == delivery.at)
                    }
                    if !contents.isEmpty { waitingActions(confirming: confirming) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connection.waiting")
        }
    }

    /// The last delivery, for ten minutes. It is kept for this session only:
    /// the history below keeps the lasting record.
    private func recentDelivery(now: Date) -> Outbox.Delivery? {
        guard let delivery = wall.outbox.lastDelivery, now.timeIntervalSince(delivery.at) < 600 else { return nil }
        return delivery
    }

    /// "Queued at 8:06 PM". What happens next is said once, under the header.
    private func queuedLine(_ at: Date?) -> String? {
        at.map { "Queued at \(ConnectionCheck.clock($0))" }
    }

    private func waitingRow(_ title: String, _ detail: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(ax ? 12 : 15, .semibold)).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
        .overlay(alignment: .bottom) { hairline }
        .accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }

    private func deliveryView(_ delivery: Outbox.Delivery, now: Date, fromHere: Bool) -> some View {
        let when = ConnectionCheck.relative(delivery.at, now: now)
        return VStack(alignment: .leading, spacing: 8) {
            if delivery.complete {
                Label(fromHere ? "Sent to the wall" : "Sent when the wall came back", systemImage: "checkmark.circle")
                    .font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.moss)
                if !delivery.sent.isEmpty {
                    Text("\(delivery.sent.words), \(when).").font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if fromHere, delivery.sent.isEmpty, delivery.refused.isEmpty {
                // Send now reached nothing at all.
                Label("The wall did not respond. Everything is still waiting.", systemImage: "exclamationmark.circle")
                    .font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                if !delivery.again.isEmpty {
                    // The rows above name what is waiting, so this does not.
                    Label("Some changes are waiting again", systemImage: "exclamationmark.circle")
                        .font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    // Beside "Connected" the drop is over, so the line says
                    // so instead of reading as the wall's state now.
                    Text(kind.isLive
                         ? (wall.outbox.isEmpty ? "The connection dropped partway through. The wall is responding again."
                            : "The connection dropped partway through. The wall is responding again, so Send now can finish.")
                         : "The wall stopped responding before everything arrived.")
                        .font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if !delivery.refused.isEmpty {
                    Label("Not applied on the wall: \(delivery.refused.phrase).", systemImage: "exclamationmark.circle")
                        .font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Text("The wall kept what it had before.")
                        .font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityIdentifier("connection.delivery")
    }

    @ViewBuilder private func waitingActions(confirming: Bool) -> some View {
        if confirming {
            // Inline, as Pictures confirms a removal: the question sits where
            // the button was, with both answers under it.
            VStack(alignment: .leading, spacing: 6) {
                Text("Discard what is waiting? The wall keeps what it has now.")
                    .font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.discardQuestion")
                VStack(alignment: .leading, spacing: 0) {
                    discardButton("connection.confirmDiscard") {
                        confirmingDiscard = false
                        wall.discardOutbox()
                        Taps.commit()
                    }
                    Button { confirmingDiscard = false } label: { linkLabel("Keep") }
                        .modifier(PageLink()).accessibilityIdentifier("connection.keep")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if wall.link.isLive {
                    PrimaryButton(title: wall.delivering ? "Sending\u{2026}" : "Send now", enabled: !wall.delivering, accent: slate) {
                        Task { await sendNow() }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("connection.sendNow")
                }
                discardButton("connection.discard") { confirmingDiscard = true }
                    .disabled(wall.delivering)
            }
        }
    }

    /// Discard, in signal red, and never larger than Send now beside it.
    private func discardButton(_ id: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { linkLabel("Discard") }
            .modifier(PageLink(color: Ink.signal, underlined: false))
            .accessibilityIdentifier(id)
    }

    private func sendNow() async {
        guard let delivery = await wall.deliverOutbox() else { return }
        sentHere = delivery.at
    }

    // MARK: - What to try

    @ViewBuilder private var tryList: some View {
        switch kind {
        case .offline, .noWallFound:
            VStack(alignment: .leading, spacing: 6) {
                header("What to try")
                VStack(spacing: 0) {
                    // A finished check knows which step stopped, so its
                    // advice leads. Before one, the last failure's.
                    ForEach(ConnectionAdvice.steps(for: wall.lastProblem, check: finishedCheck), id: \.title) { step in
                        adviceRow(step)
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("connection.try")
        default:
            EmptyView()
        }
    }

    /// The rows of a check that has finished at the address in use.
    private var finishedCheck: [CheckStep]? {
        guard check.hasResult, !check.running, check.hostPort == wall.host else { return nil }
        return check.steps
    }

    /// A symbol, not a number, leads each row: the check below is the page's
    /// one numbered list, and two lists from 01 would read as one. At large
    /// sizes the symbol grows with the title and sits on its first line.
    private func adviceRow(_ step: ConnectionAdvice.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: step.symbol).font(ax ? .ui(12, .semibold) : .system(size: 17)).foregroundStyle(slate)
                .frame(minWidth: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // "Same Wi-Fi" never breaks at its hyphen.
                Text(ConnectionWords.unbreakable(step.title)).font(.ui(ax ? 12 : 15, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ConnectionWords.unbreakable(step.detail)).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).overlay(alignment: .bottom) { hairline }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title). \(step.detail)")
    }

    // MARK: - The way forward

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            // With something waiting while live, Send now is the page's one
            // filled button, and the check steps back to a quiet link.
            if kind.isLive, !wall.outbox.isEmpty {
                Button { runCheck() } label: { linkLabel(check.running ? "Checking\u{2026}" : ConnectionWords.primary(kind)) }
                    .modifier(PageLink()).disabled(check.running)
                    .accessibilityIdentifier("connection.primary")
            } else {
                PrimaryButton(title: primaryTitle, enabled: primaryEnabled, accent: slate) { primaryAction() }
                    // A fixed 52 pt capsule with one line: its type stops at
                    // accessibility2, where the longest label still fits, and a
                    // long press shows it large.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("connection.primary")
            }
            // Each quiet link keeps its footnote right under it.
            VStack(alignment: .leading, spacing: 0) {
                if let secondary = secondaryTitle {
                    Button { secondaryAction() } label: { linkLabel(secondary) }
                        .modifier(PageLink()).accessibilityIdentifier("connection.secondary")
                }
                footnote(ConnectionWords.footnote(kind))
            }
            if kind.isLive {
                VStack(alignment: .leading, spacing: 0) {
                    Button { startGlow() } label: {
                        // While it glows, a spinner and dimmed words: a
                        // status, not a second button.
                        HStack(spacing: 8) {
                            if glowing { ProgressView().controlSize(.small).tint(slate).accessibilityHidden(true) }
                            linkLabel(glowing ? "Glowing\u{2026}" : "Make it glow")
                        }
                    }
                    // Off while another screen holds the wall, as the
                    // notice below says, so it never invites a tap that
                    // can only be refused.
                    .modifier(PageLink()).disabled(glowing || heldBy != nil)
                    .accessibilityIdentifier("connection.glow")
                    footnote("Five seconds of white, then back to what it was showing.")
                }
                .padding(.top, 6)
                // Reads the wall's display session and name on its own, so
                // a state set at every poll redraws this, not the page.
                .background { StateWatch(session: { sessionChanged($0) }, name: { liveName = $0 }) }
            }
            if kind.isLive, let owner = heldBy {
                CreativeConnectionNotice(title: "The wall is in use",
                                         detail: ConnectionWords.occupant(owner) + " Make it glow works again when it ends.",
                                         symbol: "square.dashed", tint: slate)
                    .accessibilityIdentifier("connection.glowProblem").padding(.top, 6)
            } else if let glowProblem {
                CreativeConnectionNotice(title: glowProblem.title, detail: glowProblem.detail,
                                         symbol: "exclamationmark.circle", tint: slate)
                    .accessibilityIdentifier("connection.glowProblem").padding(.top, 6)
            }
        }
    }

    /// The wall's display session changed. This page's own glow holds it
    /// while it runs, and is not another screen.
    private func sessionChanged(_ purpose: String?) {
        guard glowTask == nil else { return }
        heldBy = purpose
        if purpose != nil { glowProblem = nil }
    }

    private var primaryTitle: String {
        if kind.isLive, check.running { return "Checking\u{2026}" }
        return ConnectionWords.primary(kind)
    }

    /// Off while a check runs, in every state: the Stop beside it ends the
    /// check first. Away from the wall the label stays, since there the
    /// primary looks for the wall and the check is the quiet action.
    private var primaryEnabled: Bool {
        guard !check.running else { return false }
        switch kind {
        case .searching: return false
        case .live, .offline, .noWallFound, .phoneOnly: return true
        }
    }

    private func primaryAction() {
        switch kind {
        case .live: runCheck()
        case .searching: break
        // A look clears this phone only, invalidates anything in flight and
        // asks at once. The session delivers what is waiting when it answers.
        case .offline, .noWallFound, .phoneOnly: wall.lookForWallAgain()
        }
    }

    private var secondaryTitle: String? {
        if check.running { return "Stop" }
        return kind.isLive ? nil : "Check each step"
    }

    private func secondaryAction() {
        if check.running { check.cancel() } else { runCheck() }
    }

    private func runCheck(probe: any ConnectionProbing = LiveProbe()) {
        guard !check.running else { return }
        let session = wall
        check.start(hostPort: wall.host, knownName: answeredName, probe: probe, live: { session.link.isLive })
    }

    // MARK: - The glow

    /// Five seconds of white through a temporary display session, which the
    /// wall ends by itself as well. Mode and settings are never touched.
    private func startGlow(seconds: Double = 5) {
        guard wall.link.isLive, glowTask == nil, heldBy == nil else { return }
        glowProblem = nil
        glowing = true
        let display = glow
        glowTask = Task { @MainActor in
            let white = Panel.blank(191)
            var accepted = await display.show(on: wall, pixels: white, purpose: "identify", seconds: seconds)
            if !accepted, !Task.isCancelled, display.problem == "Unknown display purpose." {
                // A brain from before "identify": setup's own glow looks the same.
                accepted = await display.show(on: wall, pixels: white, purpose: "onboarding", seconds: seconds)
            }
            // A cancel came from endGlow, which also ends what was started.
            guard !Task.isCancelled else { return }
            guard accepted else {
                // The wall's own refusal (a pairing code on screen) is truer
                // than a generic failure. A fresh reader names another
                // screen's session, since show() never records one.
                let refusal = display.problem
                let reader = TemporaryWallDisplay()
                await reader.refresh(on: wall)
                guard !Task.isCancelled else { return }
                if let owner = reader.occupiedBy {
                    heldBy = owner
                } else {
                    glowProblem = GlowProblem(title: "Glow not confirmed",
                                              detail: refusal ?? "The glow did not reach the wall. Try again.")
                }
                glowing = false
                glowTask = nil
                return
            }
            Taps.commit()
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Ended first: end() polls the wall, so the state no longer
            // names this glow when the page stops treating it as its own.
            _ = await display.end(on: wall)
            guard !Task.isCancelled else { return }
            glowing = false
            glowTask = nil
        }
    }

    /// Ends a glow early: the page left, or the app went to the background.
    /// end() waits for a start in flight and sends nothing if none was tried.
    private func endGlow() {
        glowTask?.cancel()
        glowTask = nil
        glowing = false
        let display = glow, source = wall
        Task { _ = await display.end(on: source) }
    }

    // MARK: - From this phone to the wall

    private var rows: [CheckStep] {
        check.hasResult ? check.steps
            : ConnectionCheck.passive(host: wall.host, link: kind, network: watcher.reading, problem: wall.lastProblem)
    }

    /// A row's own offer of another address: the wall's name after a check
    /// found the number silent, or an allowed address for a blocked name.
    /// While it shows, the steadier-address notice below stays away.
    private var rowSuggestion: String? {
        guard check.hasResult, !suggestionHidden else { return nil }
        return check.steps.lazy.compactMap(\.suggestion).first
    }

    private var checkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("From this phone to the wall")
            TimelineView(.everyMinute) { context in
                Text(summaryLine(now: context.date)).font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connection.summary")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { step in stepRow(step) }
            }
            if check.hasResult, !check.running, ConnectionCheck.reachedWall(check.steps), !kind.isLive {
                // Reachable, but the session is not using it: a stand-in, an
                // away wall between probes, or this phone chosen.
                VStack(alignment: .leading, spacing: 10) {
                    CreativeConnectionNotice(title: "The wall is reachable", detail: "Tessera is not using it yet.",
                                             symbol: "checkmark.circle", tint: slate)
                    Button { wall.lookForWallAgain() } label: { linkLabel(kind == .phoneOnly ? "Connect to the wall" : "Use the wall") }
                        .modifier(PageLink()).accessibilityIdentifier("connection.useWall")
                }
                .padding(.top, 6)
            }
        }
    }

    private func summaryLine(now: Date) -> String {
        guard check.hasResult else { return ConnectionCheck.summary(rows, ran: false) }
        // A failed step beside "Connected" says the session still reaches the wall.
        let summary = ConnectionCheck.summary(check.steps, ran: true, live: kind.isLive)
        guard !check.running, let at = check.finishedAt else { return summary }
        return summary + " Checked \(ConnectionCheck.relative(at, now: now))."
    }

    /// One row, with its own action (Open iPhone Settings, Use the name)
    /// inside it, above the row's hairline, so the action reads as the row's.
    private func stepRow(_ step: CheckStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 14) {
                // Never wraps: the column grows with the text size instead.
                Text(step.number).font(.machine(ax ? 8 : 10)).foregroundStyle(slate).lineLimit(1).fixedSize()
                    .frame(minWidth: 24, alignment: .leading).padding(.top, 4)
                GradeLayout(stacked: ax) {
                    Text(step.title).font(.ui(ax ? 12 : 15, .semibold)).fixedSize(horizontal: false, vertical: true)
                    // Row 03's grade can be the wall's name or number.
                    AddressText(step.grade, large: ax).font(.machine(ax ? 8 : 11)).foregroundStyle(gradeColour(step.status))
                        .multilineTextAlignment(ax ? .leading : .trailing)
                    AddressText(step.detail, large: ax).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim)
                }
                glyph(step.status).frame(width: 22, height: 22)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step.spoken)
            .accessibilityIdentifier("connection.step.\(step.id.rawValue)")
            if step.id == .permission, step.status == .failed {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: { linkLabel("Open iPhone Settings") }
                    .modifier(PageLink()).padding(.leading, 38)
                    .accessibilityIdentifier("connection.openSettings")
            }
            if let candidate = step.suggestion, !suggestionHidden {
                // At large sizes the address would break mid-name in
                // this link. The row's detail above names it.
                Button { trySuggestion(candidate) } label: {
                    linkLabel(suggesting ? "Checking\u{2026}" : ax ? "Use the name" : "Use \(candidate)")
                }
                .modifier(PageLink()).padding(.leading, 38).disabled(suggesting)
                .accessibilityIdentifier("connection.step.suggestion")
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { hairline }
        .animation(Motion.settle, value: step)
    }

    private func gradeColour(_ status: CheckStep.Status) -> Color {
        switch status {
        case .passed: Ink.ink
        case .attention: Ink.tile
        case .failed: Ink.signal
        case .running, .waiting, .unknown, .notChecked: Ink.dim
        }
    }

    /// Colour is never the only cue: each status has its own shape too.
    @ViewBuilder private func glyph(_ status: CheckStep.Status) -> some View {
        switch status {
        // Held at the large size, so it stays inside its 22 pt frame at the
        // accessibility sizes, as the fixed-size symbols do.
        case .running: ProgressView().controlSize(.small).tint(slate).dynamicTypeSize(...DynamicTypeSize.large)
        case .passed: Image(systemName: "checkmark.circle").font(.system(size: 17)).foregroundStyle(Ink.moss)
        case .attention: Image(systemName: "exclamationmark.circle").font(.system(size: 17)).foregroundStyle(Ink.tile)
        case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 17)).foregroundStyle(Ink.signal)
        case .unknown: Image(systemName: "questionmark.circle").font(.system(size: 17)).foregroundStyle(Ink.faint)
        case .notChecked, .waiting: Image(systemName: "minus.circle").font(.system(size: 17)).foregroundStyle(Ink.faint)
        }
    }

    // MARK: - Wall address

    private var draftReading: WallAddressInput.Draft { WallAddressInput.draft(draft, current: wall.host) }

    /// The wall's name, only when the address in use answered with it: from
    /// a check here, or an answer to the session since the address was set.
    /// The session keeps the name of whichever wall answered last, and a
    /// name another address answered with is never offered as this wall's.
    private var answeredName: String? {
        if kind.isLive, let liveName { return liveName }
        if check.hostPort == wall.host, let found = check.wallName { return found }
        let name = wall.lastWallName
        guard !name.isEmpty else { return nil }
        if ConnectionCheck.nameIsCurrent(wall.history.events) { return name }
        #if DEBUG
        // Captures seed a wall that answered at a number with this name
        // (-seed-wall-host with -seed-wall-name), since the fixture cannot
        // answer at 192.168.1.40 itself.
        if let seeded = Self.seededName, seeded.host == wall.host, seeded.name == name { return name }
        #endif
        return nil
    }

    #if DEBUG
    private static let seededName: (host: String, name: String)? = {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let host = value("-seed-wall-host").flatMap({ WallAddressInput.normalize($0) }),
              let name = value("-seed-wall-name") else { return nil }
        return (host, name)
    }()
    #endif

    /// The wall's name as a stable address, when the address in use is a
    /// number the router can change and this wall answered with its name.
    /// This device's own number (127.0.0.1) never changes, so it gets no offer.
    private var suggestion: String? {
        guard !editing, !suggestionHidden, let name = answeredName,
              let parts = WallAddressInput.split(wall.host), WallAddressInput.isNumeric(parts.host),
              !WallAddressInput.isLoopback(parts.host),
              let candidate = WallAddressInput.named(name, port: parts.port),
              candidate != wall.host else { return nil }
        return candidate
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Wall address")
            if editing { editor } else { addressValue }
            if let savedHost, savedHost == wall.host, kind == .searching {
                Label {
                    AddressText("Address saved. Looking for the wall at \(savedHost).", large: ax)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .font(.ui(ax ? 10 : 14)).foregroundStyle(slate)
                .accessibilityIdentifier("connection.address.notice")
            }
            if !editing { facts }
            // Row 03 already offers the name after a check found the number
            // silent, so the notice does not say it a second time.
            if let candidate = suggestion, rowSuggestion == nil, let ip = WallAddressInput.split(wall.host)?.host {
                VStack(alignment: .leading, spacing: 10) {
                    // The notice's type does not shrink at large sizes, where
                    // an address in it would break mid-name. There it points
                    // at the name shown just above instead, and so does the link.
                    // Away, the number may be why: the wall's name is the
                    // way back. Live, the name only makes the address last.
                    CreativeConnectionNotice(title: "A steadier address",
                                             detail: steadierDetail(ip: ip, candidate: candidate),
                                             symbol: "signpost.right", tint: slate)
                    Button { trySuggestion(candidate) } label: {
                        linkLabel(suggesting ? "Checking\u{2026}" : ax ? "Use the name" : "Use \(candidate)")
                    }
                    .modifier(PageLink()).disabled(suggesting)
                    .accessibilityIdentifier("connection.suggestion")
                }
            }
            if let suggestionNotice {
                Label {
                    AddressText(suggestionNotice, large: ax)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.ink)
                .accessibilityIdentifier("connection.suggestion.notice")
            }
        }
    }

    private func steadierDetail(ip: String, candidate: String) -> String {
        let away = switch kind {
        case .offline, .noWallFound: true
        default: false
        }
        return switch (away, ax) {
        case (false, true):
            "Your router can change the number in use. The name on the network, shown above, reaches the same wall."
        case (false, false):
            ConnectionWords.unbreakable("\(ip) is a number your router can change. \(candidate) reaches the same wall by name.")
        case (true, true):
            "Nothing responds at the number in use now, and your router may have changed it. The wall\u{2019}s name, shown above, stays the same."
        case (true, false):
            ConnectionWords.unbreakable("Nothing responds at \(ip) now, and your router may have changed it. The wall\u{2019}s name, \(candidate), stays the same.")
        }
    }

    @ViewBuilder private var addressValue: some View {
        // One line that shrinks rather than wraps: an address has no spaces,
        // so a wrap would split it mid-name (from xxxLarge beside Change).
        let value = Text(wall.host).font(.machine(ax ? 10 : 14)).textSelection(.enabled)
            .lineLimit(1).minimumScaleFactor(0.5).accessibilityIdentifier("connection.address.value")
        let change = Button("Change") { beginEditing(wall.host) }
            .font(.ui(ax ? 12 : 14, .semibold)).foregroundStyle(slate).frame(minHeight: 44)
            .accessibilityIdentifier("connection.address.change")
        if ax {
            VStack(alignment: .leading, spacing: 4) { value; change }
        } else {
            HStack(alignment: .center, spacing: 12) {
                value
                Spacer(minLength: 8)
                change
            }
        }
    }

    @ViewBuilder private var facts: some View {
        // The number a check reached, for a named address: what the name
        // leads to today.
        if let remote = check.remote, check.hostPort == wall.host,
           let host = WallAddressInput.split(wall.host)?.host, !WallAddressInput.isNumeric(host) {
            fact("Network address", remote, "Can change when your router restarts.")
        }
        // The same name.local the suggestion uses: a name that already ends
        // in .local keeps it, and one that cannot be a host is not shown.
        // Why a name helps is said only when a number is in use and nothing
        // below or above already offers the name.
        // Only a name this address answered with, and not when the address
        // in use is that name already.
        let current = WallAddressInput.split(wall.host)?.host ?? ""
        if let name = answeredName, let named = WallAddressInput.named(name, port: WallAddressInput.defaultPort),
           let host = WallAddressInput.split(named)?.host, host != current {
            let why = WallAddressInput.isNumeric(current) && !WallAddressInput.isLoopback(current)
                && suggestion == nil && rowSuggestion == nil
            fact("Name on the network", host, why ? "Stays the same when the number changes." : nil)
        }
    }

    private func fact(_ label: String, _ value: String, _ why: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim)
            // A name or number, so one line that shrinks, never a wrap mid-name.
            Text(value).font(.machine(ax ? 9 : 13)).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.5)
            if let why {
                Text(why).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var editor: some View {
        let reading = draftReading
        return VStack(alignment: .leading, spacing: 10) {
            TextField("album-matrix.local:8788", text: $draft)
                .font(.machine(ax ? 10 : 14)).foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .submitLabel(.done).focused($fieldFocused)
                .onSubmit { save(reading.address) }
                // Focused once it exists: set before, the focus is dropped.
                .onAppear { if focusOnOpen { fieldFocused = true } }
                .padding(16).frame(minHeight: 52)
                .background(Ink.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Wall address").accessibilityIdentifier("connection.address.field")
            if let line = reading.line {
                AddressText(line, large: ax).font(.ui(ax ? 10 : 12)).foregroundStyle(reading.isProblem ? Ink.ink : Ink.dim)
                    .accessibilityIdentifier(reading.isProblem ? "connection.address.problem" : "connection.address.preview")
            }
            PrimaryButton(title: "Use this address", enabled: reading.address != nil, accent: slate) { save(reading.address) }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("connection.address.save")
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Button { editing = false; fieldFocused = false } label: { linkLabel("Cancel") }
                    .modifier(PageLink()).accessibilityIdentifier("connection.address.cancel")
                if wall.host != WallSession.defaultHost {
                    Button { save(WallSession.defaultHost) } label: { linkLabel("Use the standard address") }
                        .modifier(PageLink()).accessibilityIdentifier("connection.address.standard")
                }
            }
        }
    }

    private func beginEditing(_ text: String, focus: Bool = true) {
        draft = text
        focusOnOpen = focus
        editing = true
    }

    /// Only a changed address is saved. The session then looks for the wall
    /// there as it would from the stand-in, so an address that never answers
    /// reads "No wall found", not offline since the last wall's reply.
    private func save(_ address: String?) {
        guard let address else { return }
        editing = false
        fieldFocused = false
        guard address != wall.host else { return }
        wall.setHost(address)
        savedHost = address
        Taps.commit()
    }

    /// Switch to name.local only after it answers as Tessera. An owner may
    /// have typed the number because the name failed on their network.
    private func trySuggestion(_ candidate: String) {
        guard !suggesting else { return }
        suggesting = true
        suggestionNotice = nil
        let host = wall.host
        Task { @MainActor in
            let answer = await LiveProbe().ask(hostPort: candidate, timeout: .seconds(4))
            suggesting = false
            guard wall.host == host else { return }
            if case .tessera = answer {
                save(candidate)
            } else {
                suggestionHidden = true
                suggestionNotice = "\(candidate) did not respond, so the address is unchanged."
                Taps.error()
            }
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        let all = wall.history.events
        let shown = Array(all.prefix(showAllHistory ? LinkHistory.limit : 8))
        // One line per time, "6:10 PM" today and the day alone, "Sep 26",
        // before. Martian is monospaced, so the longest label sets one
        // column width for every row, and the sentences start on one line.
        let widest = shown.map { ConnectionCheck.column($0.at) }.max { $0.count < $1.count } ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            header("Recent")
            if shown.isEmpty {
                Text("Nothing yet. Changes to the connection appear here.").font(.ui(ax ? 10 : 14)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connection.recent.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { event in recentRow(event, widest: widest) }
                }
                if all.count > shown.count {
                    Button { showAllHistory = true } label: { linkLabel("Show all") }
                        .modifier(PageLink()).accessibilityIdentifier("connection.recent.showAll")
                }
            }
            if let logURL {
                VStack(alignment: .leading, spacing: 0) {
                    ShareLink(item: logURL, preview: SharePreview("Tessera log")) { linkLabel("Share the app log") }
                        .modifier(PageLink())
                        // The file is written every few seconds. Write it now, so
                        // the copy shared includes the last moments.
                        .simultaneousGesture(TapGesture().onEnded { _ = FlightLog.prepareForShare() })
                        .accessibilityIdentifier("connection.shareLog")
                    footnote("For troubleshooting. It includes song titles and your wall\u{2019}s address.")
                }
                .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("connection.recent")
    }

    private func recentRow(_ event: LinkEvent, widest: String) -> some View {
        let clock = ConnectionCheck.clock(event.at)
        let when = ZStack(alignment: .topLeading) {
            // Holds the column at the widest label, never shown.
            if !ax { Text(widest).hidden() }
            Text(ConnectionCheck.column(event.at))
        }
        .font(.machine(ax ? 8 : 11)).foregroundStyle(Ink.faint).lineLimit(1).minimumScaleFactor(0.8)
        .fixedSize(horizontal: !ax, vertical: false)
        let words = VStack(alignment: .leading, spacing: 3) {
            Text(event.sentence).font(.ui(ax ? 12 : 14)).fixedSize(horizontal: false, vertical: true)
            // "Address changed" carries the new address as its detail.
            if let detail = event.detail, !detail.isEmpty {
                AddressText(detail, large: ax).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim)
            }
        }
        return Group {
            if ax {
                VStack(alignment: .leading, spacing: 4) { when; words }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    when.padding(.top, 2)
                    words
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11).overlay(alignment: .bottom) { hairline }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([event.sentence, event.detail, clock]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    // MARK: - Related

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Related")
            VStack(spacing: 0) {
                NavigationLink { MacReporterPage(accent: accent, services: $services) } label: {
                    relatedRow("desktopcomputer", "Your Mac", macDetail)
                }
                .buttonStyle(PressStyle(scale: 0.99)).accessibilityIdentifier("connection.mac")
                // The catalog's own words, so this row and the landing agree.
                NavigationLink(value: SettingsDestination.health) {
                    relatedRow(SettingsDestination.health.symbol, SettingsDestination.health.title,
                               SettingsDestination.health.detail)
                }
                .buttonStyle(PressStyle(scale: 0.99)).accessibilityIdentifier("connection.health")
                if kind != .phoneOnly {
                    Button {
                        wall.useStandIn()
                        Taps.commit()
                    } label: {
                        relatedRow("iphone", "Use this phone only",
                                   "Tessera stops contacting the wall until you connect again.", chevron: false)
                    }
                    .buttonStyle(PressStyle(scale: 0.99)).accessibilityIdentifier("connection.phoneOnly")
                }
            }
        }
    }

    private var macDetail: String {
        ConnectionWords.macDetail(live: wall.link.isLive, loaded: services != nil, available: services?.mac != nil,
                                  endpoint: services?.mac?.endpoint, answering: services?.mac?.answering)
    }

    private func relatedRow(_ symbol: String, _ title: String, _ detail: String, chevron: Bool = true) -> some View {
        HStack(alignment: ax ? .firstTextBaseline : .center, spacing: 14) {
            // At large sizes the symbol grows with the title, on its line.
            Image(systemName: symbol).font(ax ? .ui(12) : .system(size: 18)).foregroundStyle(slate)
                .frame(minWidth: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(ax ? 12 : 16)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if chevron { Chevron().accessibilityHidden(true) }
        }
        .padding(.vertical, 10).frame(minHeight: 56)
        .overlay(alignment: .bottom) { hairline }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    /// A quiet link's words: wrapped lines stay on the text column's left
    /// edge, a hyphen never ends a line, and the tap target is 44 pt tall.
    private func linkLabel(_ title: String) -> some View {
        Text(ConnectionWords.unbreakable(title))
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            .accessibilityLabel(title)
    }

    /// The note under an action. Capped with the actions, so at the largest
    /// sizes it never outgrows the filled button above it.
    private func footnote(_ text: String) -> some View {
        Text(text).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.ui(ax ? 13 : 22, .semibold)).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var hairline: some View { Rectangle().fill(slate.opacity(0.1)).frame(height: 1) }

    // MARK: - Capture hooks

    #if DEBUG
    /// Launch arguments that put the page in each state without touches, for
    /// captures and UI tests. See the D07 capture list.
    private func runHooks(_ proxy: ScrollViewProxy) {
        guard !hooked else { return }
        hooked = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        // The editor without the keyboard, so a capture shows the page.
        if let text = value("-connection-edit") { beginEditing(text, focus: false) }
        // -connection-scroll check|address|recent|related, and the editor's
        // own section when it is open.
        if let target = value("-connection-scroll").flatMap(Section.init(rawValue:))
            ?? (args.contains("-connection-edit") ? .address : nil) {
            scrollTarget = target
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        switch value("-connection-history") {
        case "sample": wall.debugSeedHistory(Self.sampleHistory(now: Date()))
        case "clear":
            wall.debugClearHistory()
            // The first answer logs "Wall responding", so the empty list is
            // cleared again once the wall has answered.
            Task { @MainActor in
                await waitUntil(seconds: 10) { wall.link.isLive }
                wall.debugClearHistory()
            }
        default: break
        }
        if args.contains("-connection-phone-only") { wall.useStandIn() }
        if args.contains("-connection-look") { wall.lookForWallAgain() }
        Task { @MainActor in
            // Every launch starts in the automatic stand-in until the first
            // probe answers, so hooks that need the wall wait for it.
            if let scenario = value("-connection-check-fixture"), let probe = ScriptedProbe(scenario: scenario) {
                await waitUntil(seconds: 5) { wall.link.isLive }
                // Away from the wall, the link settles first: a change of
                // state clears a finished check's rows.
                await waitUntil(seconds: 10) { if case .searching = wall.link { false } else { true } }
                runCheck(probe: probe)
            } else if value("-connection-check") == "auto" {
                await waitUntil(seconds: 10) { wall.link.isLive }
                if wall.link.isLive { runCheck() }
            }
            if args.contains("-connection-queue") {
                // Seeded only while away, so the reconnect cannot deliver it
                // before the capture.
                await waitUntil(seconds: 60) { if case .offline = wall.link { true } else { false } }
                if case .offline = wall.link {
                    wall.outbox.add(patch: ["brightness": 0.4, "mode": "ambient"])
                    wall.outbox.add(frame: Panel.blank(40))
                }
            }
            if let result = value("-connection-delivery") {
                await waitUntil(seconds: 8) { wall.link.isLive }
                seedDelivery(result)
            }
            if args.contains("-connection-glow") {
                await waitUntil(seconds: 10) { wall.link.isLive }
                // Thirty seconds, so a capture is not racing the end.
                startGlow(seconds: 30)
            }
            // -connection-save <address> saves as the editor would, for the
            // "Address saved" notice. It needs -seed-wall-host, since an
            // address given with -wall.host cannot be changed in session.
            if let address = value("-connection-save") {
                await waitUntil(seconds: 8) { wall.link.isLive }
                save(WallAddressInput.normalize(address))
            }
            // After a queue or a delivery above has been seeded. The state
            // starts true for this flag as well (see confirmingDiscard).
            if args.contains("-connection-confirm-discard") {
                await waitUntil(seconds: 15) { !wall.outbox.isEmpty }
                if !wall.outbox.isEmpty { confirmingDiscard = true }
            }
        }
    }

    /// What changes the height above a scroll target: the hero and its
    /// reason, the queue, the advice, the actions and their notices.
    private var layoutKey: String {
        [kind.key, "\(check.running)", "\(check.hasResult)", wall.lastProblem?.rawValue ?? "",
         "\(wall.outbox.isEmpty)", "\(wall.outbox.lastDelivery?.at.timeIntervalSince1970 ?? 0)",
         heldBy ?? "", glowProblem?.title ?? "", savedHost ?? "", "\(editing)"].joined(separator: "|")
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func seedDelivery(_ result: String) {
        let at = Date().addingTimeInterval(-120)
        let none = Outbox.Contents()
        switch result {
        case "sent":
            wall.outbox.debugSetDelivery(Outbox.Delivery(at: at, sent: Outbox.Contents(keys: ["brightness"], frame: true),
                                                         again: none, refused: none))
        case "partial":
            // The requeued items are listed above the result.
            wall.outbox.add(patch: ["mode": "ambient"])
            wall.outbox.add(frame: Panel.blank(40))
            wall.outbox.debugSetDelivery(Outbox.Delivery(at: at, sent: Outbox.Contents(keys: ["brightness"]),
                                                         again: Outbox.Contents(keys: ["mode"], frame: true), refused: none))
        case "refused":
            wall.outbox.debugSetDelivery(Outbox.Delivery(at: at, sent: Outbox.Contents(keys: ["mode"]),
                                                         again: none, refused: Outbox.Contents(keys: ["ticker_text"])))
        case "unanswered":
            // Send now reached nothing: everything went back in the queue,
            // and the result says so as this page's own send.
            wall.outbox.add(patch: ["mode": "ambient"])
            wall.outbox.add(frame: Panel.blank(40))
            sentHere = at
            wall.outbox.debugSetDelivery(Outbox.Delivery(at: at, sent: none,
                                                         again: Outbox.Contents(keys: ["mode"], frame: true), refused: none))
        default:
            break
        }
    }

    /// A fixed day of events: yesterday's first answer, then an outage this
    /// morning with a change that waited and was sent on the way back.
    static func sampleHistory(now: Date) -> [LinkEvent] {
        [
            LinkEvent(kind: .responding, at: now.addingTimeInterval(-26 * 3600)),
            LinkEvent(kind: .stopped, at: now.addingTimeInterval(-3 * 3600), detail: "No response within 3 seconds."),
            LinkEvent(kind: .waiting, at: now.addingTimeInterval(-3 * 3600 + 60), detail: "Brightness"),
            LinkEvent(kind: .looking, at: now.addingTimeInterval(-2 * 3600)),
            LinkEvent(kind: .respondingAgain, at: now.addingTimeInterval(-2 * 3600 + 5)),
            LinkEvent(kind: .sent, at: now.addingTimeInterval(-2 * 3600 + 6), detail: "Brightness"),
        ]
    }
    #endif
}

/// The wall's display session (a panel check, a guest code, a glow) and its
/// name, read on their own so a state set at every poll redraws this empty
/// view only. Shown only while the wall is live.
private struct StateWatch: View {
    @Environment(WallSession.self) private var wall
    let session: (String?) -> Void
    let name: (String?) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: wall.state.displaySession, initial: true) { _, purpose in session(purpose) }
            .onChange(of: wall.state.wallName, initial: true) { _, value in name(value) }
    }
}

/// The status line under the headline. Its own view because it is the one
/// place that reads the lights (wall.state), so a state set at every poll or
/// stand-in tick redraws this line, not the page.
private struct HeroStatus: View {
    @Environment(WallSession.self) private var wall
    let kind: LinkKind
    let ax: Bool
    let tint: Color

    var body: some View {
        let shown: LinkKind = kind.isLive ? .live(lightsOff: wall.state.mode == "off") : kind
        TimelineView(.everyMinute) { context in
            HStack(alignment: .center, spacing: 8) {
                if kind == .searching { ProgressView().tint(tint).accessibilityHidden(true) }
                AddressText(ConnectionWords.status(shown, host: wall.host, problem: wall.lastProblem, now: context.date), large: ax)
                    .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim)
                    .accessibilityIdentifier("connection.status")
            }
        }
    }
}

/// Copy that may hold a wall address. An address has no spaces to wrap at,
/// so at accessibility sizes a Text wider than its line would break it letter
/// by letter. There each address gets a line of its own and shrinks to fit,
/// and the words around it wrap as usual. VoiceOver reads the whole sentence
/// once. At other sizes this is a plain Text.
private struct AddressText: View {
    let text: String
    let large: Bool

    init(_ text: String, large: Bool) {
        self.text = text
        self.large = large
    }

    var body: some View {
        let pieces = large ? ConnectionWords.addressPieces(text) : []
        if pieces.contains(where: \.isAddress) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    if piece.isAddress {
                        Text(piece.text).lineLimit(1).minimumScaleFactor(0.5)
                    } else {
                        Text(ConnectionWords.unbreakable(piece.text)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        } else {
            // A word joiner after each hyphen, so album-matrix.local never
            // breaks at its hyphen. VoiceOver reads the copy as written.
            Text(ConnectionWords.unbreakable(text)).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(text)
        }
    }
}

/// The page's quiet links: ink with an underline, faint with none while
/// disabled, so "Glowing..." or a running "Checking..." never looks like a
/// live button. Capped with PrimaryButton at accessibility2, so at the
/// largest sizes the filled button stays the strongest thing on the page.
private struct PageLink: ViewModifier {
    var color: Color = Ink.ink
    var underlined = true
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .font(.ui(15, .semibold))
            .foregroundStyle(enabled ? color : Ink.faint)
            .underline(underlined && enabled, pattern: .solid)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityShowsLargeContentViewer()
    }
}

/// The wall's picture beside the status. Its own view, so a moving face
/// redraws only this, not the whole page, at every frame pulled.
private struct HeroThumb: View {
    @Environment(WallSession.self) private var wall
    let kind: LinkKind

    var body: some View {
        if let frame = wall.frame {
            // With the lights off the wall is dark, whatever its last frame
            // held, so the thumb is drawn dark too and its caption says why.
            let off = kind.isLive && wall.state.mode == "off"
            VStack(spacing: 6) {
                WallThumb(frame: off ? Data(Panel.blank(side: Panel.square(frame) ?? 64)) : frame, live: wall.link.isLive)
                Text(ConnectionWords.caption(kind, frameFromPhone: wall.frameFromPhone, mode: wall.state.mode))
                    .font(.machine(9)).foregroundStyle(Ink.faint).lineLimit(1).fixedSize()
            }
            // The status line carries the meaning. WallThumb's own label says
            // "not reachable" even for this phone only.
            .accessibilityHidden(true)
        }
    }
}

/// A check row's title, grade and detail. The grade sits at the end of the
/// title's line when both fit whole, and under the title when they do not,
/// so neither is squeezed until a word breaks. The detail runs full width
/// underneath. `stacked` forces the grade under the title (large type).
private struct GradeLayout: Layout {
    var stacked: Bool
    var spacing: CGFloat = 10
    var lineGap: CGFloat = 4

    private func placements(width: CGFloat, subviews: Subviews) -> (rects: [CGRect], height: CGFloat) {
        guard subviews.count == 3 else { return ([], 0) }
        let title = subviews[0], grade = subviews[1], detail = subviews[2]
        let titleIdeal = title.sizeThatFits(.unspecified)
        let gradeIdeal = grade.sizeThatFits(.unspecified)
        var rects: [CGRect] = []
        var y: CGFloat = 0
        if !stacked, titleIdeal.width + spacing + gradeIdeal.width <= width {
            let line = max(titleIdeal.height, gradeIdeal.height)
            rects.append(CGRect(x: 0, y: 0, width: titleIdeal.width, height: titleIdeal.height))
            rects.append(CGRect(x: width - gradeIdeal.width, y: 0, width: gradeIdeal.width, height: gradeIdeal.height))
            y = line + lineGap
        } else {
            let titleSize = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
            rects.append(CGRect(x: 0, y: 0, width: width, height: titleSize.height))
            y = titleSize.height + 2
            let gradeSize = grade.sizeThatFits(ProposedViewSize(width: width, height: nil))
            rects.append(CGRect(x: 0, y: y, width: width, height: gradeSize.height))
            y += gradeSize.height + lineGap
        }
        let detailSize = detail.sizeThatFits(ProposedViewSize(width: width, height: nil))
        rects.append(CGRect(x: 0, y: y, width: width, height: detailSize.height))
        return (rects, y + detailSize.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        return CGSize(width: width, height: placements(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rects, _) = placements(width: bounds.width, subviews: subviews)
        for (subview, rect) in zip(subviews, rects) {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
    }
}
