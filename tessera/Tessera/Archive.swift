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

// MARK: - Store

@MainActor
@Observable
final class ArchiveStore {
    var runs: [WornRun] = []
    var loading = false
    var failed: String? = nil
    private(set) var lastLoaded: Date?
    private(set) var localOnly = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var sourceHost = ""
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    private(set) var unavailableTiles: Set<String> = []

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
        let id = UUID(); requestID = id
        if sourceHost != host { runs = []; lastLoaded = nil; sourceHost = host }
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            guard let url = URL(string: "http://\(host)/journal?limit=200"), url.host != nil else {
                throw URLError(.badURL)
            }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["entries"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            let entries = raw.compactMap { item -> JournalEntry? in
                guard let ts = item["ts"] as? Int, ts > 0 else { return nil }
                return JournalEntry(ts: ts, title: item["title"] as? String ?? "Untitled",
                                    artist: item["artist"] as? String ?? "",
                                    album: item["album"] as? String ?? "", artURL: item["art_url"] as? String)
            }
            guard !Task.isCancelled, requestID == id, sourceHost == host else { return }
            runs = ArchiveIndex.collapse(ArchiveIndex.merge(entries, LocalJournal.entries()))
            failed = nil; localOnly = entries.isEmpty && !runs.isEmpty; lastLoaded = Date()
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            if runs.isEmpty { runs = ArchiveIndex.collapse(LocalJournal.entries()); localOnly = !runs.isEmpty }
            failed = runs.isEmpty ? "The wall’s journal is unavailable." : "Showing saved history. The wall isn’t answering."
        }
    }

    func retryImages() {
        retryAfter.removeAll(); unavailableTiles.removeAll()
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
        guard !inFlight.contains(key), Date() >= retryAfter[key, default: .distantPast],
              let url = URL(string: key) else { return nil }
        inFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            let img = await Self.fetchAndRender(url, session: http)
            await MainActor.run {
                self.inFlight.remove(key)
                if let img {
                    if self.tiles.count >= 240 { self.tiles.removeAll(keepingCapacity: true) }
                    self.tiles[key] = img; self.unavailableTiles.remove(key)
                } else {
                    self.retryAfter[key] = Date().addingTimeInterval(30)
                    self.unavailableTiles.insert(key)
                }
            }
        }
        return nil
    }

    nonisolated private static func fetchAndRender(_ url: URL, session: URLSession) async -> UIImage? {
        // the session is configured to prefer its cache, so a sleeve seen
        // once is not fetched again
        let data: Data
        let text = url.absoluteString
        if text.hasPrefix("data:image/"), let separator = text.range(of: ";base64,"), text.utf8.count <= 28_000_000 {
            guard let decoded = Data(base64Encoded: String(text[separator.upperBound...])) else { return nil }
            data = decoded
        } else {
            guard ["http", "https"].contains(url.scheme ?? ""),
                  let (bytes, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            data = bytes
        }
        guard let src = UIImage(data: data)?.cgImage else { return nil }
        // Clip.squareFrame is the app's one image-to-panel path; the copy
        // this replaced STRETCHED non-square art where everything else crops.
        guard let px = Clip.squareFrame(src, side: 64) else { return nil }
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
    /// The shelf renders off the main thread while the archive renders on
    /// it; the dictionary is not safe to share without this.
    private static let maskLock = NSLock()
    private static func mask(_ cell: Int) -> [Double] {
        maskLock.lock(); defer { maskLock.unlock() }
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
        guard let n = Panel.square(px.count) else { return nil }
        // The emitter shrinks as the wall grows: a tile in a dense grid is
        // the same size on screen whether it holds 4,096 emitters or 36,864,
        // and a 768 pixel raster is more than that tile can show either way.
        let cellI = max(1, min(Int(cell.rounded()), 768 / n))
        let d = max(0.05, min(1.0, duty))

        let key = "\(digest(px))|\(cellI)|\(Int(d * 100))" as NSString
        if let hit = done.object(forKey: key) { return hit }

        let side = n * cellI
        let m = mask(cellI)
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        buf.withUnsafeMutableBufferPointer { out in
            px.withUnsafeBufferPointer { pin in
                for i in 0..<(n * n) {
                    let o = i * 3
                    let lit = pin[o] >= 8 || pin[o + 1] >= 8 || pin[o + 2] >= 8
                    let er = lit ? Double(pin[o]) * d : 12.75
                    let eg = lit ? Double(pin[o + 1]) * d : 12.75
                    let eb = lit ? Double(pin[o + 2]) * d : 12.75
                    let x0 = (i % n) * cellI
                    let y0 = (i / n) * cellI
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
        render(Panel.blank(), cell: 4)
    }()
}

// MARK: - Screen

struct ArchiveScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var opened: WornRun?
    @State private var query = ""
    @State private var showStats = false
    let accent: Color

    private var visible: [WornRun] { ArchiveIndex.matching(store.runs, query: query) }
    private var days: [Date] {
        Array(Set(visible.map { Calendar.current.startOfDay(for: $0.entry.date) })).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header
                if !store.runs.isEmpty {
                    search
                    statistics
                }
                if let problem = store.failed { connectionNotice(problem) }
                if store.runs.isEmpty { empty }
                else if visible.isEmpty {
                    ContentUnavailableView.search(text: query).foregroundStyle(Ink.ink)
                } else {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(dayTitle(day)).font(.displayMid(21)).foregroundStyle(Ink.ink)
                                Spacer(minLength: 8)
                                Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.machine(9)).foregroundStyle(Ink.dim)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 22) {
                                ForEach(visible.filter { Calendar.current.isDate($0.entry.date, inSameDayAs: day) }) { run in
                                    Button { opened = run; Taps.detent() } label: {
                                        ArchiveTile(run: run, image: store.tile(run.entry), accent: accent)
                                    }
                                    .buttonStyle(PressStyle(scale: 0.98))
                                    .accessibilityLabel("\(run.entry.title), \(run.entry.artist), \(run.count) recorded appearance\(run.count == 1 ? "" : "s")")
                                    .accessibilityHint("Show artwork and put it back on the wall")
                                }
                            }
                        }
                    }
                    Text("Cover previews are rebuilt from the original artwork. Local entries keep their actual panel pixels.")
                        .font(.ui(11)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden).clipped()
        .background(Ink.ground.opacity(0.96).ignoresSafeArea())
        .refreshable { store.retryImages(); await store.load(host: wall.host) }
        .task(id: wall.host) { await store.load(host: wall.host) }
        .sheet(item: $opened) { run in WornDetail(run: run, accent: accent).environment(wall).environment(store) }
        .sheet(isPresented: $showStats) { ListeningStatsPage(runs: store.runs, accent: accent) }
        .onChange(of: store.runs) { _, runs in
            #if DEBUG
            if CommandLine.arguments.contains("-archive-detail"), opened == nil { opened = runs.first }
            #endif
        }
        .onAppear {
            #if DEBUG
            showStats = CommandLine.arguments.contains("-archive-stats")
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("YOUR COLLECTION OF MOMENTS").font(.machine(8)).tracking(1.1).foregroundStyle(accent.toned(forDark: true))
                Spacer()
                if store.loading { ProgressView().tint(accent).accessibilityLabel("Refreshing history") }
            }
            Text("Archive").font(.display(typeSize.isAccessibilitySize ? 20 : 38)).foregroundStyle(Ink.ink)
            Text(store.localOnly ? "Saved on this phone." : "Every sleeve leaves a trace.")
                .font(.ui(14)).foregroundStyle(Ink.dim)
        }
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.dim)
            TextField("Song, artist or album", text: $query).font(.ui(15)).foregroundStyle(Ink.ink)
                .autocorrectionDisabled().submitLabel(.search).accessibilityLabel("Search history")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .foregroundStyle(Ink.dim).accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16).padding(.trailing, query.isEmpty ? 16 : 0).frame(minHeight: 50)
        .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 15))
    }

    private var statistics: some View {
        let stats = WornStats.read(store.runs)
        return Button { showStats = true } label: {
            Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Insights", systemImage: "chart.bar.xaxis").font(.ui(16, .semibold)).foregroundStyle(accent.toned(forDark: true))
                    Text("\(stats.sleeves) sleeves · \(stats.artists) artists").font(.ui(12)).foregroundStyle(Ink.dim)
                }
            } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.sleeves)").font(.display(32)).foregroundStyle(Ink.ink)
                    Text(stats.sleeves == 1 ? "sleeve" : "sleeves").font(.ui(12)).foregroundStyle(Ink.dim)
                }
                Rectangle().fill(Ink.hairline).frame(width: 1, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.artists)").font(.display(32)).foregroundStyle(Ink.ink)
                    Text(stats.artists == 1 ? "artist" : "artists").font(.ui(12)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 21, weight: .medium))
                    Label("Insights", systemImage: "chevron.right").font(.ui(12, .medium))
                }.foregroundStyle(accent.toned(forDark: true))
            }
            }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(PressStyle(scale: 0.98)).accessibilityLabel("Listening insights. \(stats.sleeves) sleeves, \(stats.artists) artists")
    }

    private func connectionNotice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "wifi.slash").font(.ui(13)).foregroundStyle(Ink.dim)
            Button("Try again") { Task { store.retryImages(); await store.load(host: wall.host) } }
                .font(.ui(14, .semibold)).foregroundStyle(accent.toned(forDark: true)).frame(minHeight: 44)
                .disabled(store.loading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: store.loading ? "square.stack" : "square.stack.3d.up")
                .font(.system(size: 52, weight: .ultraLight)).foregroundStyle(accent.toned(forDark: true)).padding(.vertical, 24)
            Text(store.loading ? "Opening the archive" : store.failed == nil ? "Your first sleeve awaits." : "History is out of reach.")
                .font(.displayMid(29)).foregroundStyle(Ink.ink)
            Text(store.loading ? "Gathering the things your wall has worn." : store.failed == nil ? "Play something on the wall. Its artwork will find a home here." : "Reconnect to your wall, then pull down to refresh.")
                .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}

private struct ArchiveTile: View {
    let run: WornRun
    let image: UIImage?
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArchiveArtwork(image: image)
                .overlay(alignment: .bottomTrailing) {
                    if run.count > 1 {
                        Text("×\(run.count)").font(.machine(10)).foregroundStyle(Ink.ink)
                            .padding(7).background(Ink.ground.opacity(0.92), in: RoundedRectangle(cornerRadius: 7)).padding(8)
                    }
                }
            Text(run.entry.title).font(.ui(15, .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
            Text(run.entry.artist.isEmpty ? "Unknown artist" : run.entry.artist).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(2)
            Text(run.entry.date.formatted(.dateTime.hour().minute())).font(.machine(9)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct ArchiveArtwork: View {
    let image: UIImage?
    var body: some View {
        ZStack {
            Ink.plaster
            if let image { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() }
            else { Image(systemName: "photo").font(.system(size: 32, weight: .light)).foregroundStyle(Ink.dim) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.ink.opacity(0.09), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct WornDetail: View {
    @Environment(WallSession.self) private var wall
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let run: WornRun
    let accent: Color
    @State private var sending = false
    @State private var sent = false
    @State private var problem: String?
    @State private var replayTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ArchiveArtwork(image: store.tile(run.entry))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(run.entry.title).font(.display(32)).foregroundStyle(Ink.ink)
                        Text(run.entry.artist).font(.ui(18, .medium)).foregroundStyle(Ink.dim)
                        if !run.entry.album.isEmpty { Text(run.entry.album).font(.ui(14)).foregroundStyle(Ink.dim) }
                    }
                    HStack(alignment: .top) {
                        Label(run.entry.date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        Spacer()
                        Text("\(run.count) appearance\(run.count == 1 ? "" : "s")")
                    }.font(.ui(12)).foregroundStyle(Ink.dim)
                    Text(run.entry.local ? "These are the panel pixels saved by this phone." : "A preview of the original cover. The wall applies its current finish when you show it again.")
                        .font(.ui(13)).foregroundStyle(Ink.dim)
                    Button {
                        sending = true; problem = nil
                        replayTask = Task {
                            let ok = await wall.replay(entry: run.entry)
                            guard !Task.isCancelled else { return }
                            sending = false; sent = ok
                            if !ok { problem = "Couldn’t put this sleeve on the wall. Reconnect and try again." }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if sending { ProgressView().tint(Ink.ground) }
                            else { Image(systemName: sent ? "checkmark" : "arrow.up.right.square") }
                            Text(sending ? "Sending to the wall" : sent ? "Requested on the wall" : "Put on the wall").font(.ui(16, .semibold))
                        }.foregroundStyle(Ink.ground).frame(maxWidth: .infinity, minHeight: 54)
                            .background(accent.toned(forDark: true), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(PressStyle()).disabled(sending || sent || (!wall.link.isLive && !(run.entry.local && wall.link.isStandIn)))
                    if !wall.link.isLive && !wall.link.isStandIn {
                        Label("Reconnect to show this sleeve.", systemImage: "wifi.slash").font(.ui(13)).foregroundStyle(Ink.dim)
                    }
                    if let problem { Text(problem).font(.ui(13)).foregroundStyle(Ink.signal).accessibilityLabel(problem) }
                }.padding(24)
            }.background(Ink.ground)
                .navigationTitle("From the archive").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
            .onDisappear { replayTask?.cancel() }
    }
}
