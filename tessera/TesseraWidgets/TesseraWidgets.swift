// The widget is the wall, not a card about the wall.
//
// Moonlitt's widget is the moon: no frame, no label, no chrome, just the
// object at its current state. Tessera's is the same idea taken literally.
// The small widget is 4,096 emitters and nothing else. The medium one adds
// the placard, because at that size there is room for the wall to be named.
//
// A widget cannot poll, so the provider tries the wall directly and falls
// back to whatever the app last wrote. An extension's local network access
// can be denied without ever prompting, so the fallback is the normal path,
// not the error path, and anything older than ten minutes says when it is
// from rather than pretending to be current.

import AppIntents
import WidgetKit
import SwiftUI

struct WallEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let title: String?
    let artist: String?
    let mode: String
    let asOf: Date?          // nil when the frame came from the wall just now

    var isDark: Bool { mode == "off" || image == nil }
}

struct WallProvider: TimelineProvider {
    typealias Entry = WallEntry

    func placeholder(in context: Context) -> WallEntry {
        WallEntry(date: Date(), image: nil, title: nil, artist: nil, mode: "off", asOf: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WallEntry) -> Void) {
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WallEntry>) -> Void) {
        Task {
            let e = await entry()
            // The wall changes when a track changes, which is minutes, not
            // seconds. Asking more often than this would cost battery for
            // frames nobody is looking at.
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(300))))
        }
    }

    private func entry() async -> WallEntry {
        let cached = WallSnapshot.read()

        if let live = await WallSnapshot.fetchLive(host: cached.host) {
            WallSnapshot.write(px: live.px, title: live.title, artist: live.artist,
                               mode: live.mode, host: cached.host)
            return WallEntry(
                date: Date(),
                image: WallSnapshot.render(live.px),
                title: live.title, artist: live.artist, mode: live.mode,
                asOf: nil
            )
        }

        let stale = (cached.updated.map { Date().timeIntervalSince($0) > 600 } ?? true)
        return WallEntry(
            date: Date(),
            image: cached.px.flatMap { WallSnapshot.render($0) },
            title: cached.title, artist: cached.artist, mode: cached.mode,
            asOf: stale ? cached.updated : nil
        )
    }
}

// MARK: - Views

private struct Panel: View {
    let entry: WallEntry
    var body: some View {
        ZStack {
            Color.black
            if let img = entry.image, !entry.isDark {
                Image(uiImage: img)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
    }
}

private struct SmallWall: View {
    let entry: WallEntry
    var body: some View {
        Panel(entry: entry)
            .overlay(alignment: .bottomTrailing) {
                if let asOf = entry.asOf {
                    Text(asOf, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(6)
                }
            }
    }
}

private struct MediumWall: View {
    let entry: WallEntry
    var body: some View {
        HStack(spacing: 14) {
            Panel(entry: entry)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                if let title = entry.title, !title.isEmpty, !entry.isDark {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let artist = entry.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                } else {
                    Text(entry.mode == "off" ? "Asleep" : "Nothing playing")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer(minLength: 0)

                if let asOf = entry.asOf {
                    Text(asOf, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                // The three things worth doing from the home screen. These
                // run in the app's process (see Shared/WallIntents.swift),
                // which is the only process allowed to dial the wall.
                HStack(spacing: 6) {
                    WidgetKey(label: "Art", mode: .art, on: entry.mode == "art")
                    WidgetKey(label: "Lamp", mode: .lamp, on: entry.mode == "ambient")
                    WidgetKey(label: "Off", mode: .off, on: entry.mode == "off")
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WidgetKey: View {
    let label: String
    let mode: WallMode
    let on: Bool

    var body: some View {
        Button(intent: SetWallModeIntent(mode: mode)) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(on ? Color.white : Color.white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widgets

/// One entry view that reads the family, so both sizes share a configuration.
private struct WallEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WallEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium: MediumWall(entry: entry)
            default: SmallWall(entry: entry)
            }
        }
        .containerBackground(.black, for: .widget)
    }
}

struct WallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TesseraWall", provider: WallProvider()) { entry in
            WallEntryView(entry: entry)
        }
        .configurationDisplayName("The wall")
        .description("What the wall is showing.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // The frame must reach the edges: this is an object, not a card.
        .contentMarginsDisabled()
    }
}

@main
struct TesseraWidgetBundle: WidgetBundle {
    var body: some Widget {
        WallWidget()
        WallLiveActivity()
    }
}
