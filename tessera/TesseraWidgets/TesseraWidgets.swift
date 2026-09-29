// The widget is the wall, not a card about the wall.
//
// Moonlitt's widget is the moon: no frame, no label, no chrome, just the
// object at its current state. Tessera's is the same idea taken literally.
// The small widget is the panel and nothing else while its picture is
// current, and one label when it is not, or when a check is up. The medium one adds the words and
// the three keys, in a column of their own beside the panel.
//
// A widget cannot poll, so the provider tries the wall directly and falls
// back to the record the app last wrote (Shared/WallSnapshot.swift). An
// extension's local network access can be denied without ever prompting, so
// the record is the normal path, not the error path. The timeline carries
// its own future: the entry where a current picture turns "As of", the one
// where a timer finishes, the ones where "As of 9:41 PM" becomes a day and
// then a date. Honesty rests on those, not on WidgetKit reloading in time.
//
// The views and every rule about what they say live in Shared/, so the
// app's Home Screen page and render harness draw this exact widget.

import AppIntents
import SwiftUI
import WidgetKit

struct WallEntry: TimelineEntry {
    let date: Date
    let result: WallSnapshot.ReadResult
    let reading: WidgetReading

    var frame: Data? {
        if case .record(let r) = result { return r.frame }
        return nil
    }

    var side: Int? {
        if case .record(let r) = result { return r.side ?? Panel.square(r.frame) }
        return nil
    }
}

struct WallProvider: TimelineProvider {
    typealias Entry = WallEntry

    func placeholder(in context: Context) -> WallEntry {
        let now = Date()
        return WallEntry(date: now, result: .unreadable, reading: WidgetReading(result: .unreadable, now: now))
    }

    /// The gallery shows the owner's own last frame, or the not set up
    /// state, never invented art. It asks for this at once, so no network.
    func getSnapshot(in context: Context, completion: @escaping (WallEntry) -> Void) {
        let result = WallSnapshot.Store.shared.read()
        completion(Self.entries(for: result, from: Date())[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WallEntry>) -> Void) {
        Task {
            let store = WallSnapshot.Store.shared
            var result = store.read()
            var frozen = false
            #if DEBUG
            frozen = WallSnapshot.frozen
            #endif
            if !frozen {
                // The real sizes on this phone, for the app's preview.
                if let family = WallWidgetFamily(context.family) {
                    store.setMeasured(context.displaySize, for: family.measuredKey)
                }
                result = await Self.refresh(result, in: store)
            }
            let now = Date()
            let entries = Self.entries(for: result, from: now)
            // A request, not a promise: the reload budget decides. The
            // scheduled entries above keep the labels true in the meantime.
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }

    /// Asks the wall directly and writes what it said. Only a record with a
    /// host can be dialled: the host is stamped by a wall that answered.
    private static func refresh(_ result: WallSnapshot.ReadResult, in store: WallSnapshot.Store) async -> WallSnapshot.ReadResult {
        guard case .record(let cached) = result, !cached.host.isEmpty else { return result }
        guard var live = await WallSnapshot.fetchLive(host: cached.host, carrying: cached) else {
            count("widget.debug.snapshot")
            return result
        }
        // The outbox is the app's. Whatever it recorded since this read began
        // stays, rather than being overwritten by a copy taken before.
        if case .record(let latest) = store.read() { live.queued = latest.queued }
        store.write(live)
        count("widget.debug.live")
        return .record(live)
    }

    /// Whether the extension ever reaches the wall on the real phone, which
    /// Apple's rules leave open. Debug builds only.
    private static func count(_ key: String) {
        #if DEBUG
        let d = WallSnapshot.Store.shared.defaults
        d.set(d.integer(forKey: key) + 1, forKey: key)
        #endif
    }

    /// One entry now, then one at each moment the reading changes on its
    /// own, so the stale flip, a timer's end and the midnight rollover of an
    /// "As of" time need no reload.
    static func entries(for result: WallSnapshot.ReadResult, from start: Date) -> [WallEntry] {
        #if DEBUG
        // A capture pinned the clock: one still entry, read at that moment.
        if let pinned = WallSnapshot.pinnedNow {
            return [WallEntry(date: start, result: result,
                              reading: WidgetReading(result: result, now: pinned, liveTimer: false))]
        }
        #endif
        var out: [WallEntry] = []
        var at = start
        for _ in 0..<8 {
            let reading = WidgetReading(result: result, now: at)
            out.append(WallEntry(date: at, result: result, reading: reading))
            guard let next = reading.nextChange, next > at else { break }
            at = next
        }
        return out
    }
}

// MARK: - Views

/// One entry view that reads the family, so both sizes share a configuration.
private struct WallEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WallEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                WallWidgetMedium(reading: entry.reading, frame: entry.frame, side: entry.side, interactive: true)
            default:
                WallWidgetSmall(reading: entry.reading, frame: entry.frame, side: entry.side)
            }
        }
        .containerBackground(Ink.ground, for: .widget)
        // Opens the Wall page. Sheets stay as they are: dismissing Settings
        // would end a running panel check or clear a guest draft.
        .widgetURL(URL(string: "tessera://wall"))
    }
}

struct WallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WallSnapshot.kind, provider: WallProvider()) { entry in
            WallEntryView(entry: entry)
        }
        .configurationDisplayName("The wall")
        .description("What the wall is showing. The medium size adds Art, Lamp and Off.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // The panel must reach the edges: this is an object, not a card. The
        // medium widget pads its own column instead.
        .contentMarginsDisabled()
    }
}

@main
struct TesseraWidgetBundle: WidgetBundle {
    init() {
        #if DEBUG
        // A face missing from UIAppFonts falls back to the system font
        // without a word, so say which ones this process can find.
        for name in ["Technor-Bold", "Switzer-Medium", "Switzer-Semibold", "MartianMono-Medium"] {
            print("[widget fonts] \(name): \(UIFont(name: name, size: 12) != nil ? "found" : "missing")")
        }
        #endif
    }

    var body: some Widget {
        WallWidget()
        WallLiveActivity()
    }
}
