// The Archive: everything the wall has worn, and it is itself a mosaic.
//
// Each thing the wall showed becomes one tessera, rendered through the same
// emitter language as the panel, so the wall's memory is made of the same
// material the wall is. Not a list with thumbnails: a dense field of frames,
// newest first, banded by day, where the unit of the grid is the unit of the
// object.
//
// Honesty note that matters: the wall's journal records what it showed
// (title, artist, art URL and when), not the 12KB frame itself. These tiles
// are therefore this app's own reduction of the same source art, not a
// recording of the exact bytes the wall lit. Close, and not the same claim.

import SwiftUI
import UIKit

// MARK: - Model

struct JournalEntry: Equatable {
    let ts: Int
    let title: String
    let artist: String
    let album: String
    let artURL: String?
    /// Recorded by the app rather than by a wall, which means the frame is
    /// held here instead of being refetchable from an address. See
    /// [[LocalJournal]] for why the two cannot be the same thing.
    var local: Bool = false

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

/// The wall wearing the same sleeve twice in a row is one thing you looked
/// at, not two rows. Consecutive repeats collapse and carry their count.
struct WornRun: Identifiable, Equatable {
    let entry: JournalEntry
    let count: Int
    let lastTs: Int
    var id: Int { entry.ts }
}

// MARK: - Store

@MainActor
@Observable
final class ArchiveStore {
    var runs: [WornRun] = []
    var loading = false
    var failed: String? = nil

    /// Observed: filling this is what tells the grid to redraw.
    private(set) var tiles: [String: UIImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let http: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg)
    }()

    func load(host: String) async {
        loading = true
        defer { loading = false }
        guard let u = URL(string: "http://\(host)/journal?limit=200") else {
            adoptLocal()
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["entries"] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            let entries: [JournalEntry] = raw.compactMap { e in
                guard let ts = e["ts"] as? Int else { return nil }
                return JournalEntry(
                    ts: ts,
                    title: e["title"] as? String ?? "Unknown",
                    artist: e["artist"] as? String ?? "",
                    album: e["album"] as? String ?? "",
                    artURL: e["art_url"] as? String
                )
            }
            .sorted { $0.ts > $1.ts }

            // A wall that answers with nothing has not worn anything yet,
            // and the app may still have. Both are the same list.
            runs = Self.collapse(Self.merge(entries, LocalJournal.entries()))
            failed = runs.isEmpty ? "Nothing here yet." : nil
        } catch {
            adoptLocal()
        }
    }

    /// No wall, or no answer from it: what the app itself has seen.
    private func adoptLocal() {
        runs = Self.collapse(LocalJournal.entries())
        failed = runs.isEmpty ? "Nothing here yet." : nil
    }

    /// Newest first, and never the same wearing twice. A sleeve can be in
    /// both lists when the app watched a wall that was also writing its own
    /// journal, and one of those is enough.
    private static func merge(_ a: [JournalEntry], _ b: [JournalEntry]) -> [JournalEntry] {
        var seen = Set<String>()
        return (a + b)
            .sorted { $0.ts > $1.ts }
            .filter { seen.insert("\($0.ts)|\($0.title)").inserted }
    }

    private static func collapse(_ entries: [JournalEntry]) -> [WornRun] {
        var out: [WornRun] = []
        for e in entries {
            if let last = out.last,
               last.entry.title == e.title, last.entry.artist == e.artist {
                out[out.count - 1] = WornRun(entry: last.entry, count: last.count + 1, lastTs: e.ts)
            } else {
                out.append(WornRun(entry: e, count: 1, lastTs: e.ts))
            }
        }
        return out
    }

    /// The tile for an entry, rendered as emitters. Nil until it arrives;
    /// the cell shows an unlit lattice until then, which is what a panel with
    /// nothing on it actually looks like.
    func tile(_ entry: JournalEntry) -> UIImage? {
        // A locally recorded sleeve carries its own frame, so there is
        // nothing to fetch and nothing to reduce: this is the bytes the app
        // actually put on its own wall.
        if entry.local {
            let key = "local:\(entry.ts)"
            if let hit = tiles[key] { return hit }
            guard !inFlight.contains(key), let px = LocalJournal.frame(entry.ts) else { return nil }
            inFlight.insert(key)
            if let img = EmitterTile.render(px, cell: 4) {
                tiles[key] = img
                inFlight.remove(key)
                return img
            }
            inFlight.remove(key)
            return nil
        }
        guard let key = entry.artURL else { return nil }
        if let hit = tiles[key] { return hit }   // observed read
        guard !inFlight.contains(key), let url = URL(string: key) else { return nil }
        inFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            let img = await Self.fetchAndRender(url, session: http)
            await MainActor.run {
                self.inFlight.remove(key)
                if let img { self.tiles[key] = img }
            }
        }
        return nil
    }

    private static func fetchAndRender(_ url: URL, session: URLSession) async -> UIImage? {
        // the session is configured to prefer its cache, so a sleeve seen
        // once is not fetched again
        guard let (data, _) = try? await session.data(from: url),
              let src = UIImage(data: data)?.cgImage else { return nil }
        // Clip.square64 is the app's one image-to-64px path; the local copy
        // this replaced STRETCHED non-square art where everything else crops.
        guard let px = Clip.square64(src) else { return nil }
        return EmitterTile.render(px, cell: 4)
    }
}

/// Small shared emitter rasteriser, so a tile anywhere in the app is drawn
/// with the same rules as the wall.
enum EmitterTile {
    /// Finished tiles by content digest. The raster below is quick, but the
    /// studio's kept strip and the archive grid ask for the same frames on
    /// every body evaluation; the second ask should cost a hash, not a
    /// drawing. NSCache so the system can shed them under pressure.
    private static let done: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    /// FNV-1a over the whole buffer. Data.hashValue only reads a prefix,
    /// and dark-topped frames taught us exactly what that costs.
    static func digest(_ px: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in px { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Circle coverage across one cell, supersampled once per cell size and
    /// shared by all 4,096 emitters of every tile at that size.
    private static var masks: [Int: [Double]] = [:]
    private static func mask(_ cell: Int) -> [Double] {
        if let m = masks[cell] { return m }
        let r = Double(cell) * 0.35
        let mid = Double(cell) / 2
        let ss = 4
        var m = [Double](repeating: 0, count: cell * cell)
        for y in 0..<cell {
            for x in 0..<cell {
                var hit = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let dx = Double(x) + (Double(sx) + 0.5) / Double(ss) - mid
                        let dy = Double(y) + (Double(sy) + 0.5) / Double(ss) - mid
                        if dx * dx + dy * dy <= r * r { hit += 1 }
                    }
                }
                m[y * cell + x] = Double(hit) / Double(ss * ss)
            }
        }
        masks[cell] = m
        return m
    }

    /// duty dims the lit emitters the way the wall's brightness would; the
    /// unlit lattice stays put. One rasteriser, so the finish thumbnails and
    /// the archive tiles cannot drift apart again.
    ///
    /// Rastered by hand into a byte buffer rather than drawn: the old body
    /// issued 4,096 CGContext ellipse fills with a fresh CGColor each, and
    /// with the kept strip re-rendering per body evaluation that held the
    /// main thread at 60 percent CPU until the watchdog shot the app.
    static func render(_ px: [UInt8], cell: CGFloat, duty: Double = 1) -> UIImage? {
        guard px.count == 64 * 64 * 3 else { return nil }
        let cellI = max(1, Int(cell.rounded()))
        let d = max(0.05, min(1.0, duty))

        let key = "\(digest(px))|\(cellI)|\(Int(d * 100))" as NSString
        if let hit = done.object(forKey: key) { return hit }

        let side = 64 * cellI
        let m = mask(cellI)
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        buf.withUnsafeMutableBufferPointer { out in
            px.withUnsafeBufferPointer { pin in
                for i in 0..<(64 * 64) {
                    let o = i * 3
                    let lit = pin[o] >= 8 || pin[o + 1] >= 8 || pin[o + 2] >= 8
                    let er = lit ? Double(pin[o]) * d : 12.75
                    let eg = lit ? Double(pin[o + 1]) * d : 12.75
                    let eb = lit ? Double(pin[o + 2]) * d : 12.75
                    let x0 = (i % 64) * cellI
                    let y0 = (i / 64) * cellI
                    for yy in 0..<cellI {
                        var at = ((y0 + yy) * side + x0) * 4
                        let mrow = yy * cellI
                        for xx in 0..<cellI {
                            let cov = m[mrow + xx]
                            out[at] = UInt8(min(255, er * cov))
                            out[at + 1] = UInt8(min(255, eg * cov))
                            out[at + 2] = UInt8(min(255, eb * cov))
                            out[at + 3] = 255
                            at += 4
                        }
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cg = CGImage(width: side, height: side,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let img = UIImage(cgImage: cg)
        done.setObject(img, forKey: key, cost: side * side * 4)
        return img
    }

    /// A panel with nothing on it: the lattice, unlit.
    static var empty: UIImage? = {
        render([UInt8](repeating: 0, count: 64 * 64 * 3), cell: 4)
    }()
}

// MARK: - Screen

struct ArchiveScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(ArchiveStore.self) private var store
    @State private var opened: WornRun? = nil
    @Namespace private var zoom

    let accent: Color

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: []) {
                head
                if store.runs.isEmpty {
                    emptyState
                } else {
                    counts
                    ForEach(days, id: \.0) { (day, runs) in
                        band(day: day, runs: runs)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.load(host: wall.host) }
        .overlay { detail }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("WORN")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(Ink.ink)
            Text(store.runs.isEmpty ? " " : "everything the wall has carried")
                .font(.ui(13))
                .foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    /// The shape of the listening, before the sleeves themselves. It goes
    /// above the grid because it is the one thing here you cannot get by
    /// scrolling: the grid is the record, this is what the record adds up to.
    @ViewBuilder private var counts: some View {
        let stats = WornStats.read(store.runs)
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                WornClockBand(stats: stats, accent: accent)
                WornCount(stats: stats, accent: accent)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    /// Newest day first; inside a day, newest first.
    private var days: [(String, [WornRun])] {
        var order: [String] = []
        var map: [String: [WornRun]] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE d MMMM"
        for run in store.runs {
            let key = fmt.string(from: run.entry.date)
            if map[key] == nil { order.append(key); map[key] = [] }
            map[key]?.append(run)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func band(day: String, runs: [WornRun]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(day.uppercased())
                    .font(.machine(9))
                    .kerning(0.8)
                    .foregroundStyle(Ink.faint)
                Rectangle().fill(Ink.hairline).frame(height: 1)
            }
            .padding(.horizontal, 6)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(runs) { run in
                    Tile(run: run, image: store.tile(run.entry), accent: accent)
                        .matchedGeometryEffect(id: run.id, in: zoom)
                        .onTapGesture {
                            Taps.detent(intensity: 0.5)
                            withAnimation(Motion.settle) { opened = run }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let empty = EmitterTile.empty {
                Image(uiImage: empty)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: 104, height: 104)
            }
            Text(store.failed ?? "Nothing here yet.")
                .font(.displayMid(17))
                .foregroundStyle(Ink.ink)
        }
        .padding(.horizontal, 6)
        .padding(.top, 30)
    }

    @ViewBuilder private var detail: some View {
        if let run = opened {
            WornDetail(run: run, image: store.tile(run.entry), accent: accent, zoom: zoom) {
                withAnimation(Motion.settle) { opened = nil }
            } wearAgain: {
                wall.replay(ts: run.entry.ts)
                withAnimation(Motion.settle) { opened = nil }
            }
        }
    }
}

// MARK: - Pieces

private struct Tile: View {
    let run: WornRun
    let image: UIImage?
    let accent: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).interpolation(.high).resizable()
                } else if let empty = EmitterTile.empty {
                    Image(uiImage: empty).interpolation(.high).resizable()
                } else {
                    Color.black
                }
            }
            .aspectRatio(1, contentMode: .fit)

            if run.count > 1 {
                Text("\(run.count)")
                    .font(.machine(9))
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.75))
                    .padding(5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(run.entry.title) by \(run.entry.artist)\(run.count > 1 ? ", worn \(run.count) times" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

private struct WornDetail: View {
    let run: WornRun
    let image: UIImage?
    let accent: Color
    let zoom: Namespace.ID
    var close: () -> Void
    var wearAgain: () -> Void

    var body: some View {
        ZStack {
            Ink.ground.opacity(0.93)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let image {
                        Image(uiImage: image).interpolation(.high).resizable()
                    } else {
                        Color.black
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .matchedGeometryEffect(id: run.id, in: zoom)

                VStack(alignment: .leading, spacing: 6) {
                    Text(run.entry.title)
                        .font(.display(25))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(run.entry.artist)
                        .font(.ui(15, .medium))
                        .foregroundStyle(Ink.dim)
                    Text(when)
                        .font(.machine(10))
                        .foregroundStyle(Ink.faint)
                        .padding(.top, 2)
                }

                HStack(spacing: 18) {
                    Button(action: wearAgain) {
                        Text("Wear it again")
                            .font(.ui(15, .semibold))
                            .foregroundStyle(Ink.ground)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)

                    Button(action: close) {
                        Text("Close")
                            .font(.ui(15, .medium))
                            .foregroundStyle(Ink.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(26)
        }
        .transition(.opacity)
    }

    private var when: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let first = f.string(from: Date(timeIntervalSince1970: TimeInterval(run.lastTs)))
        let last = f.string(from: run.entry.date)
        if run.count > 1 { return "\(run.count) times · \(first) to \(last)".lowercased() }
        return last.lowercased()
    }
}
