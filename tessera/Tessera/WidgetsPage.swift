import SwiftUI
import UIKit
import WidgetKit

/// Settings, around your home: the wall on the Home Screen. The picture is
/// the real widget, drawn from the real snapshot at its real size, so what
/// this page shows is what the Home Screen shows. Read only: nothing here
/// writes to the wall or to the snapshot, and the preview's keys are inert.
struct WidgetsPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var type
    let accent: Color
    @State private var result: WallSnapshot.ReadResult?
    @State private var placed: Placed = .checking
    @State private var width: CGFloat = 327
    private let stone = Color(hex: 0xCBC4B5)
    private var ax: Bool { type.isAccessibilitySize }

    enum Placed: Equatable {
        case checking, none, unavailable
        case placed(small: Bool, medium: Bool)
    }

    private var record: WallSnapshot.Record? {
        if case .record(let r) = result { return r }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let notice {
                    CreativeConnectionNotice(title: notice.title, detail: notice.detail, symbol: notice.symbol, tint: stone)
                        .accessibilityIdentifier(notice.id)
                }
                // At accessibility sizes the steps come first, as PanelCheckPage
                // moves its preview down: the preview is fixed size and scaled,
                // the steps are what grow.
                if ax { steps }
                TimelineView(.everyMinute) { context in
                    preview(at: clock(context.date))
                        // The tick re-reads the snapshot too. The app rewrites
                        // it every minute without posting snapshotDidWrite, so
                        // without this a page left open on a live wall would
                        // age its own copy and dim after ten minutes.
                        .onChange(of: context.date) { read() }
                }
                if !ax { steps }
                explanation
                privacy
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
        }
        .background(Color(hex: 0x151513)).foregroundStyle(Ink.ink).tint(stone)
        // Apple's name for the place, as every line on this page writes it,
        // so the title and the prose under it agree.
        .navigationTitle("Home Screen").navigationBarTitleDisplayMode(.inline)
        .onAppear { read() }
        .onReceive(NotificationCenter.default.publisher(for: WallSession.snapshotDidWrite)) { _ in read() }
        // Again whenever the app comes back: the widget may have just been added.
        .task(id: scene) {
            guard scene == .active else { return }
            read()
            await checkPlaced()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("HOME SCREEN WIDGET", systemImage: "apps.iphone")
                .font(.machine(ax ? 8 : 11)).tracking(ax ? 0 : 1.4).foregroundStyle(stone)
            if !ax {
                // Both lines are 13 characters or fewer, so they fit 327 pt up
                // to xxxLarge and the break never strands a word.
                Text("The wall,\nat a glance.").font(.display(40)).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("widgets.headline")
            }
            Text(ax ? "A copy of your wall for the Home Screen." : "A small copy of what your wall is showing. The medium size adds Art, Lamp and Off.")
                .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                if placed == .checking { ProgressView().tint(stone).accessibilityHidden(true) }
                Text(placedText).font(.ui(ax ? 12 : 14, .medium)).foregroundStyle(stone)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("widgets.status")
            }
        }
    }

    private var placedText: String {
        switch placed {
        case .checking: "Checking your Home Screen"
        case .none: "Not on your Home Screen yet"
        case .unavailable: "Home Screen status unavailable"
        case .placed(true, true): "On your Home Screen, small and medium"
        case .placed(true, false): "On your Home Screen, small"
        case .placed(false, true): "On your Home Screen, medium"
        case .placed(false, false): "On your Home Screen"
        }
    }

    // MARK: Notice

    /// At most one, most specific first, and always about what the preview
    /// under it shows. With nothing saved, or nothing readable, the widget
    /// asks to open Tessera whatever the link, so that is what the notice
    /// explains. Otherwise the session is the truth about the link. A
    /// capture that pinned a fixture reads the fixture's own link, so the
    /// notice and the preview beside it agree.
    private var notice: (title: String, detail: String, symbol: String, id: String)? {
        switch result {
        case .missing?:
            // The widget's own status, and why it asks for the app.
            return ("Not set up yet", "Until Tessera saves its first picture, the widget asks you to open the app.", "arrow.up.forward.app", "widgets.missing")
        case .unreadable?:
            return ("The saved picture cannot be read", "Until Tessera saves a new one, the widget asks you to open the app.", "exclamationmark.triangle", "widgets.unreadable")
        case nil:
            return nil
        default:
            break
        }
        let (queued, offline, standIn) = linkFacts
        if queued {
            // The same words as the widget's own status line.
            return ("Queued for the wall", "Changes made from the widget are sent when the wall reconnects.", "tray.and.arrow.up", "widgets.queued")
        }
        if offline {
            return ("Your wall is offline", "Until it reconnects, the widget says how current its picture is.", "wifi.slash", "widgets.offline")
        }
        if standIn, let r = record {
            // Only a picture this phone drew is a phone preview. The host is
            // stamped only by a wall that answered.
            if r.source == .phone {
                if r.host.isEmpty {
                    return ("No wall yet", "Until a wall is connected, the widget shows this phone’s preview and says so.", "iphone", "widgets.standin")
                }
                return ("Your wall is not answering", "Until it answers, the widget shows this phone’s preview and says so.", "wifi.slash", "widgets.unanswered")
            }
            return ("Your wall is not answering", "The widget keeps your wall’s last frame and shows when it was taken.", "wifi.slash", "widgets.unanswered")
        }
        return nil
    }

    private var linkFacts: (queued: Bool, offline: Bool, standIn: Bool) {
        #if DEBUG
        if WallSnapshot.frozen {
            // A pinned fixture with no record has no link to speak of.
            guard let r = record else { return (false, false, false) }
            return (r.link != .live && r.queued, r.link == .away, r.link == .standIn)
        }
        #endif
        let offline: Bool
        if case .offline = wall.link { offline = true } else { offline = false }
        return (!wall.link.isLive && !wall.outbox.isEmpty, offline, wall.link.isStandIn)
    }

    // MARK: Preview

    private var screen: CGSize {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
            ?? CGSize(width: width + 48, height: 852)
    }

    private func clock(_ date: Date) -> Date {
        #if DEBUG
        if let pinned = WallSnapshot.pinnedNow { return pinned }
        #endif
        return date
    }

    private var liveTimer: Bool {
        #if DEBUG
        return WallSnapshot.pinnedNow == nil
        #else
        return true
        #endif
    }

    private func preview(at now: Date) -> some View {
        let reading = WidgetReading(result: result ?? .missing, now: now, liveTimer: liveTimer)
        let store = WallSnapshot.Store.shared
        let medium = WidgetMetrics.size(family: .medium, screen: screen, measured: store.measured("systemMedium"))
        let small = WidgetMetrics.size(family: .small, screen: screen, measured: store.measured("systemSmall"))
        let side = record.flatMap { $0.side ?? Panel.square($0.frame) }
        // A picture this phone drew is not the wall's, so the size above it
        // does not say wall either.
        let drawer = record?.source == .phone ? "PREVIEW" : "WALL"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("MEDIUM")
                Spacer(minLength: 8)
                if let side { Text("\(side) x \(side) \(drawer)") }
            }
            .font(.machine(ax ? 7 : 9)).foregroundStyle(Ink.dim).accessibilityHidden(true)
            // As wide as the widget under it, so the size ends at its edge.
            .frame(width: shown(medium).width)
            scaled(medium) {
                WallWidgetMedium(reading: reading, frame: record?.frame, side: side, interactive: false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Medium widget preview")
            .accessibilityValue(reading.accessibility)
            .accessibilityIdentifier("widgets.preview.medium")
            smallRow(reading, size: small, side: side)
            Text(freshness(now)).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("widgets.freshness")
        }
        // A picture of the widget, not the widget: nothing in it can be tapped.
        .allowsHitTesting(false)
    }

    @ViewBuilder private func smallRow(_ reading: WidgetReading, size: CGSize, side: Int?) -> some View {
        let picture = scaled(size) {
            WallWidgetSmall(reading: reading, frame: record?.frame, side: side)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Small widget preview")
        .accessibilityValue(reading.accessibility)
        .accessibilityIdentifier("widgets.preview.small")
        let caption = VStack(alignment: .leading, spacing: 6) {
            Text("SMALL").font(.machine(ax ? 7 : 9)).foregroundStyle(Ink.dim).accessibilityHidden(true)
            Text("The wall alone. A label appears when the picture is not current, the wall is dark or a check is running.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        if ax {
            VStack(alignment: .leading, spacing: 12) { picture; caption }
        } else {
            HStack(alignment: .top, spacing: 16) { picture; caption }
        }
    }

    /// The widget at its real point size, scaled down only when the page is
    /// narrower than it (a 329 pt medium on a 327 pt page), never reflowed.
    private func scaled<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        let s = shown(size).scale
        return WidgetCanvas(size: size, content: content)
            .overlay {
                RoundedRectangle(cornerRadius: Round.hero, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1)
            }
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: size.width * s, height: size.height * s, alignment: .topLeading)
    }

    /// The scale a widget is drawn at on this page, and its drawn width.
    private func shown(_ size: CGSize) -> (scale: CGFloat, width: CGFloat) {
        let s = min(1, max(0.1, width) / size.width)
        return (s, size.width * s)
    }

    private func freshness(_ now: Date) -> String {
        switch result {
        case .record(let r)?:
            let from = r.source == .wall ? "from your wall" : "from this phone"
            return "Last saved \(Self.when(r.written, now: now)), \(from)."
        case .unreadable?:
            return "The saved picture cannot be read right now."
        default:
            return "Nothing saved yet."
        }
    }

    /// "9:41 PM" today, "12 Sep at 9:41 PM" on another day.
    private static func when(_ date: Date, now: Date) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        if Calendar.current.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(day.string(from: date)) at \(time.string(from: date))"
    }

    // MARK: Steps and explanation

    private var steps: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Add the widget").font(.ui(ax ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                step("01", "Touch and hold an empty part of your Home Screen", "Wait until the apps jiggle.")
                step("02", "Tap Edit, then Add Widget", "Edit is in the top corner of the screen.")
                step("03", "Search for Tessera", "Choose small or medium, then tap Add Widget.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widgets.steps")
    }

    /// PicturesPage's numbered row, in this page's stone.
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Never wraps: the width grows with the text size instead.
            Text(number).font(.machine(ax ? 8 : 10)).foregroundStyle(stone).lineLimit(1).fixedSize()
                .frame(minWidth: 24, alignment: .leading).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(ax ? 12 : 15, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.ui(ax ? 10 : 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(stone.opacity(0.1)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it stays current").font(.ui(ax ? 13 : 22, .semibold)).accessibilityAddTraits(.isHeader)
            // Only what the code guarantees. Whether the widget reaches the
            // wall on its own is not known yet (debug counters record it), so
            // it is not promised here.
            Text("The widget shows the frame this phone saved the last time Tessera was open. After ten minutes without word from the wall, the picture dims and shows the time it was taken.")
                .font(.ui(ax ? 12 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Guest codes stay private", systemImage: "lock").font(.ui(ax ? 12 : 15, .semibold))
            Text("A guest code on the wall is never copied to the widget. The widget keeps showing what was up before it.")
                .font(.ui(ax ? 11 : 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.plaster, in: RoundedRectangle(cornerRadius: Round.sheet))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("widgets.privacy")
    }

    // MARK: Reading

    private func read() {
        result = WallSnapshot.Store.shared.read()
    }

    private func checkPlaced() async {
        #if DEBUG
        // -widget-installed none|small|medium|both, for captures.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-widget-installed"), i + 1 < args.count {
            switch args[i + 1] {
            case "none": placed = .none
            case "small": placed = .placed(small: true, medium: false)
            case "medium": placed = .placed(small: false, medium: true)
            default: placed = .placed(small: true, medium: true)
            }
            return
        }
        #endif
        do {
            let ours = try await WidgetCenter.shared.currentConfigurations().filter { $0.kind == WallSnapshot.kind }
            placed = ours.isEmpty ? .none : .placed(small: ours.contains { $0.family == .systemSmall },
                                                   medium: ours.contains { $0.family == .systemMedium })
        } catch {
            placed = .unavailable
        }
    }
}
