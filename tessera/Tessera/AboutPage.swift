// About Tessera: who made it, what it talks to, the wall it is talking to,
// the openings this phone plays, the way back into setup and the way into
// panel tuning, then the credits.
//
// Nothing on this page writes to the wall. It reads /state through the
// session and makes one GET /tuning per visit for the tuning row's count.
// The design choice has its own page (DesignPage.swift), so it can be found
// by search and previewed before it is used.

import SwiftUI
import UIKit

struct AboutPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    /// The room's steady accent, handed on to the tuning page.
    let accent: Color
    @AppStorage(OpeningStyle.key) private var introStyle = OpeningStyle.sting.rawValue
    @AppStorage(OpeningReplay.key) private var replayRequest = 0
    @AppStorage("onboarding.again") private var onboardingAgain = false
    /// Set once the confirmation has been accepted, so the owner is asked
    /// once and later taps open the page directly.
    @AppStorage("tuning.unlocked") private var tuningUnlocked = false
    @AppStorage("design") private var design = Design.room.rawValue
    @State private var tuning: TuningPeek = .waiting
    @State private var confirming = false
    @State private var showTuning = false
    @State private var notice: String?
    /// Set for 2 s after the address is copied: the Address row itself says
    /// so, with a checkmark in place of the copy symbol, so the confirmation
    /// sits beside the button that caused it. The notice under the rows is
    /// Copy details' alone.
    @State private var addressCopied = false
    @State private var addressCopiedTask: Task<Void, Never>?
    @State private var credits = false
    @AccessibilityFocusState private var confirmFocused: Bool
    #if DEBUG
    @State private var hooked = false
    /// Capture hooks only (-about-state look and never): the link the page
    /// shows in place of the session's, and whether it shows no size learned.
    @State private var pinnedLink: LinkState?
    @State private var pinnedUnlearned = false
    #endif

    /// The Settings warm, so About reads as part of Settings.
    private let brass = Color(hex: 0xE5BE83)
    /// The page's ground, which the navigation bar takes too.
    private let ground = Color(hex: 0x14120F)
    private var ax: Bool { type.isAccessibilitySize }
    private var info: [String: Any]? { Bundle.main.infoDictionary }
    private var home: Design { Design(rawValue: design) ?? .room }
    private var saved: OpeningStyle { OpeningStyle.saved(introStyle) }
    private var opening: OpeningKind { OpeningStyle.kind(saved, in: home, assets: .bundled) }
    private var reduced: Bool { reducedMotion || Motion.forcedReduced }
    /// The session's link, or the one a DEBUG capture hook pinned.
    private var linkState: LinkState {
        #if DEBUG
        if let pinnedLink { return pinnedLink }
        #endif
        return wall.link
    }
    /// Whether a wall has stated its size to this phone, or false while
    /// -about-state never pins a phone that has not met one.
    private var learned: Bool {
        #if DEBUG
        if pinnedUnlearned { return false }
        #endif
        return Panel.learned
    }
    private var link: AboutFacts.Link { AboutFacts.Link(linkState) }
    /// The same rule as WallSession.offersLookAgain, applied to the link
    /// shown, so a pinned capture offers what that state really offers.
    /// Never during a search, when a button offering to look would sit
    /// under a status saying the phone is already looking.
    private var offersLookAgain: Bool {
        if case .searching = linkState { return false }
        #if DEBUG
        if let pinnedLink { return !pinnedLink.isLive && (!pinnedLink.isStandIn || wall.explicitStandIn) }
        #endif
        return wall.offersLookAgain
    }
    /// "Again" only once a wall has answered this phone before.
    private var lookAgainTitle: String { learned ? "Look for your wall again" : "Look for your wall" }
    private var tuningOpens: Bool { TuningPeek.opens(tuning, link: link) }
    private var tuningStatus: String { TuningPeek.status(tuning, link: link) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ax ? 22 : 28) {
                    masthead
                    facts
                    openings.id("openings")
                    setupAndTuning
                    acknowledgements
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .onAppear { debugHooks(proxy) }
        }
        .background(ground)
        .foregroundStyle(Ink.ink)
        .tint(brass)
        .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
        // A solid bar in the page's own ground, as on Wall health and
        // Connection. Settings hides the bar for its whole stack, so without
        // this what scrolls under the title stays sharp behind it.
        .toolbarBackground(ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $showTuning) { PanelTuningPage(accent: accent) }
        // One read per visit, and again when the host or the link changes.
        // The task also restarts on the way back from the tuning page, where
        // the last count stays up until the new one lands.
        .task(id: "\(wall.host)|\(wall.link.isLive)") { await readTuning() }
        .onChange(of: wall.link.isLive) { _, live in if !live { confirming = false } }
        .onDisappear { notice = nil; addressCopiedTask?.cancel(); addressCopied = false }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordMark(accent: brass, lit: 1, side: ax ? 36 : 52)
            // The name and the version are one VoiceOver stop, a header read
            // as "Tessera, version 1.0, build 1".
            VStack(alignment: .leading, spacing: 6) {
                // The wordmark stays in the brand face at every size. At
                // accessibility sizes it is capped, so the facts start sooner.
                Text("Tessera").font(.display(ax ? 28 : 42)).tracking(ax ? -0.5 : -0.9)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                Text(AppVersion.detail(info).uppercased()).font(.machine(ax ? 8 : 10)).tracking(ax ? 0 : 1)
                    .foregroundStyle(brass)
            }
            .padding(.top, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppVersion.heading(info))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("about.version")
            Text("Designed and built by Jalen Edusei.").font(.ui(ax ? 12 : 15, .medium))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            // Both the wall and this phone reach public services: the phone
            // itself asks LRCLIB for lyrics, Deezer for tempo, and Spotify
            // once connected. The old "nothing leaves your network" was false.
            Text("There is no Tessera account. The app talks to your wall over your Wi-Fi. The wall and this app look up artwork, lyrics, tempo and weather from public services, and use the services you connect.")
                .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }

    // MARK: - Your wall

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Your wall").padding(.bottom, 4)
            WallFactRow(link: link, learned: learned, ax: ax).accessibilityIdentifier("about.wall")
            addressRow
            // Redrawn each minute, so "last reply 12 minutes ago" keeps time.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                FactRow(label: "Status", value: statusText(now: context.date), subline: nil, dot: linkState.dot, ax: ax)
                    .accessibilityIdentifier("about.status")
            }
            HStack(alignment: .center, spacing: 12) {
                // The same rule as the Settings wall card: away, searching, or
                // this phone chosen over the wall. The automatic stand-in is
                // still looking by itself, so it has nothing to offer.
                if offersLookAgain {
                    Button { notice = nil; wall.lookForWallAgain() } label: {
                        Text(lookAgainTitle).quietLink().multilineTextAlignment(.leading)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .accessibilityIdentifier("about.lookAgain")
                }
                Spacer(minLength: 8)
                Button { copyDetails() } label: {
                    Text("Copy details").font(.ui(ax ? 12 : 14, .semibold)).foregroundStyle(brass)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .accessibilityHint("Copies the app version, the wall address and its status, for a support message")
                .accessibilityIdentifier("about.copyDetails")
            }
            .padding(.top, 10)
            if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.ui(14)).foregroundStyle(brass)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    .accessibilityIdentifier("about.notice")
            }
        }
    }

    /// The session's words, except while searching, which this page words
    /// as the rest of it does, "your wall".
    private func statusText(now: Date) -> String {
        let word = linkState.word(off: wall.state.mode == "off")
        guard case .offline = linkState else { return word }
        return word + AboutFacts.lastReply(wall.lastSync, now: now)
    }

    private var addressRow: some View {
        let words = VStack(alignment: .leading, spacing: 5) {
            Text("Address").font(.ui(ax ? 12 : 15))
            // A host name has almost nowhere to break, so at accessibility
            // sizes it shrinks to stay on one line rather than breaking
            // inside the name. The copy button and VoiceOver still give it
            // in full, and a name too long even then keeps both its ends.
            Text(wall.host).font(.machine(ax ? 10 : 13)).foregroundStyle(Ink.dim)
                .lineLimit(ax ? 1 : nil).minimumScaleFactor(ax ? 0.5 : 1).truncationMode(.middle)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if addressCopied {
                Text("Copied").font(.ui(ax ? 11 : 12, .medium)).foregroundStyle(brass)
            } else if let subline = addressSubline {
                Text(subline).font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about.address")
        let copy = Button { copyAddress() } label: {
            Image(systemName: addressCopied ? "checkmark" : "doc.on.doc").font(.system(size: 16, weight: .medium)).foregroundStyle(brass)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel("Copy wall address")
        .accessibilityValue(addressCopied ? "Copied" : "")
        .accessibilityIdentifier("about.copyAddress")
        return Group {
            if ax {
                VStack(alignment: .leading, spacing: 4) { words; copy }
            } else {
                HStack(alignment: .center, spacing: 12) { words; copy }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    /// Only the stand-in has something to say about the address: whether the
    /// app is still trying it. The automatic stand-in every launch starts in
    /// probes it every few seconds. The owner's own choice of this phone does
    /// not.
    private var addressSubline: String? {
        guard linkState.isStandIn else { return nil }
        return wall.explicitStandIn ? "Not in use while you explore on this phone." : "The app checks this address now and then."
    }

    // MARK: - Openings

    private var openings: some View {
        let choices = OpeningStyle.choices(in: home, assets: .bundled)
        return VStack(alignment: .leading, spacing: 12) {
            header("Openings")
            Text("Plays on this phone when Tessera opens. The wall is not affected.")
                .font(.ui(ax ? 12 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            card {
                ForEach(Array(choices.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Rule(inset: 50) }
                    // "film" is this design's own film, so the identifier
                    // follows what the row writes.
                    ChoiceRow(title: kind.title, subtitle: kind.detail, value: kind, selected: opening, accent: brass) { picked in
                        introStyle = picked.style.rawValue
                        notice = nil
                    }
                    .accessibilityIdentifier("about.opening.\(kind.style.rawValue)")
                }
            }
            if let note = openingNote {
                Text(note).font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("about.openingNote")
            }
            if opening != .none {
                VStack(alignment: .leading, spacing: 4) {
                    // Explicit colours with a plain press style, so the turned
                    // off button stays readable instead of the system grey.
                    Button { play() } label: {
                        Label("Play it now", systemImage: "play.fill").font(.ui(ax ? 12 : 15, .semibold))
                            .foregroundStyle(reduced ? Ink.dim : brass)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(CalibrationLinkStyle())
                    .disabled(reduced)
                    .accessibilityIdentifier("about.playOpening")
                    if reduced {
                        Text("Openings are skipped while Reduce Motion is on.").font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("about.reduceMotion")
                    }
                }
            }
        }
    }

    /// Said when the saved film or mark belongs to another design, so None is
    /// selected here without the owner having picked it.
    private var openingNote: String? {
        guard saved == .film || saved == .mark, opening == .none else { return nil }
        // The None row just above already says it opens straight to the wall.
        return "The \(home.name) design has no film of its own."
    }

    // MARK: - Setup and tuning

    private var setupAndTuning: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Setup and tuning")
            card {
                Button {
                    notice = nil
                    // RootView queues the first run, closes Settings, then
                    // presents it. Later there returns to the home.
                    onboardingAgain = true
                } label: {
                    row(title: "Go through setup again",
                        subtitle: "Find the wall, choose music and set the light. Nothing changes unless you change it.",
                        enabled: true) {
                        Text("Start").font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(brass)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                .accessibilityIdentifier("about.setup")
                Rule(inset: 16)
                Button { tuningTapped() } label: {
                    // At accessibility sizes the chevron would fall under the
                    // words as a stray glyph, so it sits at the end of the
                    // title's line instead. The whole row is the button.
                    row(title: "Panel tuning", subtitle: tuningStatus, enabled: tuningOpens, titleChevron: tuningOpens) {
                        if tuningOpens && !ax { Chevron() }
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                .disabled(!tuningOpens)
                .accessibilityLabel("Panel tuning")
                .accessibilityValue(tuningStatus)
                .accessibilityHint(tuningUnlocked ? "Opens panel tuning" : "Asks before opening panel tuning")
                .accessibilityIdentifier("about.tuning")
                .id("tuning")
                if confirming && tuningOpens { confirmation }
            }
        }
    }

    /// One row of the card. The trailing word or chevron sits at the right,
    /// and under the words at accessibility sizes, where a long subtitle
    /// would squeeze it.
    private func row<Trailing: View>(title: String, subtitle: String, enabled: Bool, titleChevron: Bool = false,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let words = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.ui(ax ? 13 : 16)).foregroundStyle(enabled ? Ink.ink : Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if ax && titleChevron { Spacer(minLength: 8); Chevron() }
            }
            Text(subtitle).font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        return Group {
            if ax {
                // The words take the whole row, so the subtitle wraps at the
                // row's width and not at the title's.
                VStack(alignment: .leading, spacing: 8) {
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 14) { words; Spacer(minLength: 12); trailing() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Return to defaults" is the tuning page's own name for it. It
            // puts every panel and microphone setting back, but leaves the
            // True colour correction as it is, so "every setting" and not
            // "every change". The row above counts both kinds, as the tuning
            // page does, and the noun is "setting" throughout.
            Text("Panel tuning sets how the panel drives its LEDs. It also holds the settings for the wall’s microphone. Some settings restart the panel for a few seconds. A wrong setting can make the picture worse. Return to defaults on that page puts every setting back.")
                .font(.ui(ax ? 12 : 14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($confirmFocused)
            // A fixed 52 pt capsule holding one line, so its type stops
            // growing at accessibility2. A long press shows the label large.
            PrimaryButton(title: "Open panel tuning", accent: brass) { openTuning() }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("about.tuningOpen")
            Button {
                withAnimation(reduced ? nil : Motion.settle) { confirming = false }
            } label: {
                Text("Not now").font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(brass)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(CalibrationLinkStyle())
            .accessibilityIdentifier("about.tuningCancel")
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about.tuningConfirm")
        .id("tuningConfirm")
    }

    // MARK: - Acknowledgements

    private var acknowledgements: some View {
        DisclosureGroup(isExpanded: $credits) {
            VStack(spacing: 0) {
                ForEach(Array(Credit.all.enumerated()), id: \.offset) { index, credit in
                    if index > 0 { Rule(inset: 0) }
                    Link(destination: credit.url) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(credit.title).font(.ui(ax ? 12 : 15, .semibold)).foregroundStyle(Ink.ink)
                                Text(credit.detail).font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(brass).padding(.top, 2).accessibilityHidden(true)
                        }
                        .padding(.vertical, 12).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.99))
                    .accessibilityHint("Opens in Safari")
                }
            }
            .padding(.top, 8)
        } label: {
            // One long word: at the largest accessibility sizes it is wider
            // than the room beside the chevron and would break mid-word, so
            // "Credits", which search also finds About by, takes its place.
            ViewThatFits(in: .horizontal) {
                Text("Acknowledgements")
                Text("Credits")
            }
            .font(.ui(ax ? 13 : 17, .semibold)).foregroundStyle(Ink.ink)
        }
        .tint(brass)
        .accessibilityIdentifier("about.acknowledgements")
        .id("credits")
    }

    /// The typefaces and the public services the wall and the app actually
    /// reach. The TMDB sentence is TMDB's required wording, kept verbatim.
    private struct Credit {
        let title: String
        let detail: String
        let url: URL

        static let all: [Credit] = [
            Credit(title: "Technor and Switzer", detail: "Typefaces by Indian Type Foundry, from Fontshare, under the ITF Free Font License.", url: URL(string: "https://www.fontshare.com")!),
            Credit(title: "Martian Mono", detail: "Typeface by the Martian Mono Project Authors, under the SIL Open Font License.", url: URL(string: "https://github.com/evilmartians/mono")!),
            Credit(title: "Open-Meteo", detail: "Weather data.", url: URL(string: "https://open-meteo.com")!),
            Credit(title: "LRCLIB", detail: "Synced lyrics.", url: URL(string: "https://lrclib.net")!),
            Credit(title: "Cover Art Archive and iTunes Search", detail: "Album artwork.", url: URL(string: "https://coverartarchive.org")!),
            Credit(title: "Deezer", detail: "Song tempo, when the room is too quiet to measure.", url: URL(string: "https://www.deezer.com")!),
            Credit(title: "TMDB", detail: "Film and series posters. This product uses the TMDB API but is not endorsed or certified by TMDB.", url: URL(string: "https://www.themoviedb.org")!),
            Credit(title: "Wikipedia and Openverse", detail: "Pictures for Show me.", url: URL(string: "https://openverse.org")!),
        ]
    }

    // MARK: - Pieces

    private func header(_ title: String) -> some View {
        Text(title).font(.ui(ax ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
    }

    /// The flat card the batch-16 pages use, tinted with this page's warm.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(brass.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Actions

    private func copyAddress() {
        UIPasteboard.general.string = wall.host
        Taps.commit()
        notice = nil
        showAddressCopied()
        AccessibilityNotification.Announcement("Wall address copied").post()
    }

    /// The Address row's own confirmation, for 2 s.
    private func showAddressCopied() {
        addressCopiedTask?.cancel()
        withAnimation(reduced ? nil : Motion.settle) { addressCopied = true }
        addressCopiedTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(reduced ? nil : Motion.settle) { addressCopied = false }
        }
    }

    private func copyDetails() {
        UIPasteboard.general.string = detailsText()
        Taps.commit()
        addressCopiedTask?.cancel()
        addressCopied = false
        say("Details copied.")
    }

    private func say(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    private func detailsText() -> String {
        AboutDetails.text(version: AppVersion.display(info), iOS: UIDevice.current.systemVersion, host: wall.host,
                          status: statusText(now: Date()),
                          size: AboutFacts.sizeLine(link: link, grid: wall.state.grid, side: Panel.side, learned: learned,
                                                    previewSide: WallFactRow.previewSide(link: link, frame: wall.frame)),
                          design: home.name, opening: opening.title)
    }

    /// A counter, not a switch: RootView closes Settings, shows the wall page
    /// and plays the sting, or the Room or iPod home replays its own film.
    /// It can never be left on, so a later Play always works.
    private func play() {
        guard !reduced, opening != .none else { return }
        notice = nil
        replayRequest &+= 1
        Taps.commit()
    }

    private func tuningTapped() {
        guard tuningOpens else { return }
        notice = nil
        if tuningUnlocked { showTuning = true; return }
        withAnimation(reduced ? nil : Motion.settle) { confirming.toggle() }
        Taps.detent(intensity: 0.4)
        if confirming {
            AccessibilityNotification.Announcement("Panel tuning asks first").post()
            // After the confirmation has appeared, or focus has nowhere to go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { confirmFocused = true }
        }
    }

    private func openTuning() {
        tuningUnlocked = true
        Taps.commit()
        confirming = false
        showTuning = true
    }

    private func readTuning() async {
        guard wall.link.isLive else { tuning = .waiting; return }
        let host = wall.host
        // The count from an earlier read stays up while it is checked again,
        // rather than flashing "Reading your wall" on the way back.
        if case .count = tuning {} else { tuning = .reading }
        let result = await Self.peek(host: host)
        guard !Task.isCancelled, wall.host == host, wall.link.isLive else { return }
        tuning = result
    }

    /// One GET /tuning, one attempt, 4 s. Only the brain's own "no tuning
    /// store" answer means unavailable. Anything else that fails leaves the
    /// row open, because the tuning page has its own retry.
    private static func peek(host: String) async -> TuningPeek {
        guard let url = URL(string: "http://\(host)/tuning") else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failed }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 503, json?["error"] as? String == "tuning is not available on this wall" { return .unavailable }
        guard code == 200, let json, let count = TuningPeek.parse(json) else { return .failed }
        return .count(count)
    }

    // MARK: - Capture hooks

    private func debugHooks(_ proxy: ScrollViewProxy) {
        #if DEBUG
        guard !hooked else { return }
        hooked = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        // -about-state copied|details show the confirmation only. Neither
        // touches the pasteboard, so captures never meet the simulator's
        // paste prompt.
        switch value("-about-state") {
        // copied holds the Address row's confirmation, with no timer.
        case "copied": addressCopied = true
        case "details": notice = "Details copied."
        case "confirm":
            // With -about-reset, so the row asks. It waits for the wall, since
            // the row is closed until the link is live.
            Task {
                for _ in 0..<40 where !wall.link.isLive { try? await Task.sleep(for: .milliseconds(250)) }
                confirming = true
                await hookScroll(proxy, to: "tuning")
            }
        case "openings":
            // The openings list from its header down, with nothing asked, for
            // the captures that show which opening is selected.
            Task { await hookScroll(proxy, to: "openings") }
        case "credits":
            credits = true
            Task { await hookScroll(proxy, to: "credits") }
        case "look":
            // Once live, looks for the wall for real, then holds the page at
            // searching. The real look lasts one /state request, 3 s at most
            // (WallSession's request timeout), before the wall reads offline,
            // which is too short to capture however long a fixture holds the
            // answer. The session keeps running underneath.
            Task {
                for _ in 0..<40 where !wall.link.isLive { try? await Task.sleep(for: .milliseconds(250)) }
                wall.lookForWallAgain()
                pinnedLink = .searching
            }
        case "never":
            // A phone that has never reached a wall, during its first look:
            // searching, with no size learned, so the Wall row says "Not
            // connected yet". That state only lasts while a look's one
            // request is out, 3 s at most, before the stand-in takes over
            // again, and the first answer from any fixture teaches the size.
            // So the page is pinned to it, in any fixture phase. Nothing is
            // written and nothing is sent.
            pinnedLink = .searching
            pinnedUnlearned = true
        default: break
        }
        // -about-page tuning opens the tuning page (D09's captures and tests).
        if value("-about-page") == "tuning" {
            tuningUnlocked = true
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                showTuning = true
            }
        }
        #endif
    }

    #if DEBUG
    /// A capture hook's scroll. It waits for the push into Settings to
    /// settle, and scrolls again once the content below has grown, so the
    /// target lands however late the wall answered. Under Reduce Motion it
    /// jumps, so a capture never catches the page part way.
    private func hookScroll(_ proxy: ScrollViewProxy, to target: String) async {
        for delay in [600, 500] {
            try? await Task.sleep(for: .milliseconds(delay))
            withAnimation(reduced ? nil : Motion.settle) { proxy.scrollTo(target, anchor: .top) }
        }
    }
    #endif
}

private extension AboutFacts.Link {
    /// LinkState without its date, for the Foundation-only models.
    init(_ state: LinkState) {
        switch state {
        case .live: self = .live
        case .searching: self = .searching
        case .offline: self = .offline
        case .standIn: self = .standIn
        }
    }
}

/// A flat row: the label on the left, the value on the right, a hairline
/// under it. When the value does not fit beside the label, and always at
/// accessibility sizes, the value moves under the label.
private struct FactRow: View {
    let label: String
    let value: String
    let subline: String?
    var dot: Color? = nil
    let ax: Bool

    var body: some View {
        let valueView = VStack(alignment: ax ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true) }
                Text(value).font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim)
                    .multilineTextAlignment(ax ? .leading : .trailing)
            }
            if let subline { Text(subline).font(.ui(ax ? 11 : 12)).foregroundStyle(Ink.dim).multilineTextAlignment(ax ? .leading : .trailing) }
        }
        let title = Text(label).font(.ui(ax ? 12 : 15))
        return Group {
            if ax {
                VStack(alignment: .leading, spacing: 5) { title; valueView }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) { title; Spacer(minLength: 16); valueView }
                    VStack(alignment: .leading, spacing: 5) { title; valueView.fixedSize(horizontal: false, vertical: true) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// The Wall row as its own view. Only the stand-in's preview size is
/// measured from the frame, and only this row reads it: read in the page's
/// body, every frame the wall sent, 5 to 10 a second, rebuilt the whole page.
private struct WallFactRow: View {
    @Environment(WallSession.self) private var wall
    let link: AboutFacts.Link
    let learned: Bool
    let ax: Bool

    /// The stand-in draws at 64, but a frame pushed from this phone is
    /// measured. Every other state names the wall's own size, so the frame
    /// is not read there at all.
    static func previewSide(link: AboutFacts.Link, frame: @autoclosure () -> Data?) -> Int {
        guard link == .standIn else { return Panel.bench }
        return Panel.square(frame()) ?? Panel.bench
    }

    var body: some View {
        let line = AboutFacts.wallLine(link: link, grid: wall.state.grid, side: Panel.side, learned: learned,
                                       previewSide: Self.previewSide(link: link, frame: wall.frame))
        FactRow(label: "Wall", value: line.value, subline: line.subline, ax: ax)
    }
}
