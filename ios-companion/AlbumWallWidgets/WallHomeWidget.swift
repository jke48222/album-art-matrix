// The home-screen widget: the wall on your home screen, last known.
// Small = just the panel. Medium = panel plus the track, paper-style.
import SwiftUI
import UIKit
import WidgetKit

private let widgetPaper = Color(red: 0.957, green: 0.945, blue: 0.918)
private let widgetInk = Color(red: 0.086, green: 0.075, blue: 0.059)
private let widgetSignal = Color(red: 0.878, green: 0.243, blue: 0.102)

struct WallSnapshotEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let mode: String
    let frame: UIImage?
}

struct WallSnapshotProvider: TimelineProvider {
    private var suite: UserDefaults? {
        UserDefaults(suiteName: "group.com.jalenedusei.albumwall")
    }

    private func load() -> WallSnapshotEntry {
        let d = suite
        let frame = d?.data(forKey: "framePNG").flatMap(UIImage.init(data:))
        return WallSnapshotEntry(
            date: Date(),
            title: d?.string(forKey: "title") ?? "Nothing yet",
            artist: d?.string(forKey: "artist") ?? "Open AlbumWall",
            mode: d?.string(forKey: "mode") ?? "art",
            frame: frame)
    }

    /// Freshness without the app: ask the wall directly, fall back to the
    /// app-group snapshot when the network says no.
    private func fetchLive(completion: @escaping (WallSnapshotEntry) -> Void) {
        let host = suite?.string(forKey: "wallHost") ?? "album-matrix.local:8788"
        guard let stateURL = URL(string: "http://\(host)/state"),
              let frameURL = URL(string: "http://\(host)/frame.raw") else {
            completion(load()); return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: cfg)
        session.dataTask(with: stateURL) { sData, _, _ in
            guard let sData,
                  let obj = try? JSONSerialization.jsonObject(with: sData)
                    as? [String: Any] else {
                completion(load()); return
            }
            let now = obj["now_showing"] as? [String: String]
            session.dataTask(with: frameURL) { fData, resp, _ in
                var frame: UIImage? = nil
                if let fData, fData.count == 64 * 64 * 3,
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    frame = UIImage.fromRGB64(fData)
                }
                let snap = load()
                completion(WallSnapshotEntry(
                    date: Date(),
                    title: now?["title"] ?? snap.title,
                    artist: now?["artist"] ?? snap.artist,
                    mode: obj["mode"] as? String ?? snap.mode,
                    frame: frame ?? snap.frame))
            }.resume()
        }.resume()
    }

    func placeholder(in context: Context) -> WallSnapshotEntry {
        WallSnapshotEntry(date: Date(), title: "Warm Static",
                          artist: "Analog Motel", mode: "art", frame: nil)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (WallSnapshotEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<WallSnapshotEntry>) -> Void) {
        fetchLive { entry in
            // spin mode: stop-motion — rotated frames, one per minute
            if entry.mode == "cd", let disc = entry.frame {
                let rpm = suite?.double(forKey: "rpm") ?? 7.5
                let perMin = (rpm * 360.0 / 60.0 * 60.0)
                    .truncatingRemainder(dividingBy: 360)
                let entries = (0..<15).map { i in
                    WallSnapshotEntry(
                        date: Date().addingTimeInterval(Double(i) * 60),
                        title: entry.title, artist: entry.artist,
                        mode: entry.mode,
                        frame: disc.rotated(by: Double(i) * perMin))
                }
                completion(Timeline(entries: entries,
                                    policy: .after(Date().addingTimeInterval(15 * 60))))
            } else {
                completion(Timeline(entries: [entry],
                                    policy: .after(Date().addingTimeInterval(10 * 60))))
            }
        }
    }
}

extension UIImage {
    /// 64x64 image from raw RGB bytes (twin of the app-side helper).
    static func fromRGB64(_ rgb: Data) -> UIImage? {
        guard rgb.count == 64 * 64 * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: 64, height: 64, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: 64 * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(
                                   rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Rotate a 64px frame about its center (black fill) — widget stop-motion.
    func rotated(by degrees: Double) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
                                       format: fmt).image { ctx in
            let c = ctx.cgContext
            UIColor.black.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            c.translateBy(x: 32, y: 32)
            c.rotate(by: degrees * .pi / 180)
            draw(in: CGRect(x: -32, y: -32, width: 64, height: 64))
        }
    }
}

struct WallHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WallHomeWidget",
                            provider: WallSnapshotProvider()) { entry in
            WallWidgetView(entry: entry)
        }
        .configurationDisplayName("On the wall")
        .description("What the album wall is showing.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct WallWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: WallSnapshotEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                // LEDs edge to edge — the widget IS the wall
                panel.containerBackground(.black, for: .widget)
            } else {
                HStack(spacing: 0) {
                    panel
                        .aspectRatio(1, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text("ALBUMWALL")
                                .font(.system(size: 9, weight: .heavy))
                                .kerning(1.8)
                                .foregroundStyle(fg.opacity(0.5))
                            Circle().fill(widgetSignal)
                                .frame(width: 4, height: 4)
                        }
                        Text(entry.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(fg)
                            .lineLimit(2)
                        Text(entry.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(fg.opacity(0.55))
                            .lineLimit(1)
                        Text(entry.date, style: .relative)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(fg.opacity(0.4))
                        Spacer(minLength: 2)
                        Text(displayMode)
                            .font(.system(size: 9, weight: .heavy))
                            .kerning(1.5)
                            .foregroundStyle(fg.opacity(0.75))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(fg.opacity(0.3), lineWidth: 1))
                    }
                    .padding(14)
                    Spacer(minLength: 0)
                }
                .containerBackground(bg, for: .widget)
            }
        }
    }

    private var bg: Color { scheme == .dark ? widgetInk : widgetPaper }
    private var fg: Color { scheme == .dark ? widgetPaper : widgetInk }

    private var displayMode: String {
        switch entry.mode {
        case "cd": "SPIN"
        case "ambient": "AMBIENT"
        case "off": "PANELS OFF"
        case "frame": "YOURS"
        default: "ART"
        }
    }

    private var panel: some View {
        ZStack {
            Color.black
            if let f = entry.frame {
                Image(uiImage: f)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text("WAITING")
                    .font(.system(size: 9, weight: .semibold).monospaced())
                    .kerning(2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Canvas { ctx, size in
                let step = size.width / 64
                guard step > 1.2 else { return }
                var p = Path()
                for i in 1..<64 {
                    let x = CGFloat(i) * step
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                    p.move(to: CGPoint(x: 0, y: x))
                    p.addLine(to: CGPoint(x: size.width, y: x))
                }
                ctx.stroke(p, with: .color(.black.opacity(0.4)), lineWidth: 0.7)
            }
        }
    }
}
