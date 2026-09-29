// What the app last knew about the wall, written down for the widget.
//
// One JSON record in the app group, replaced whole. It used to be six loose
// UserDefaults keys, and the widget could read a new title beside an old
// frame, or a background launch could erase the title and re-stamp the time.
// The record also says who drew the frame (the wall or this phone), how the
// app last knew (live, away or standing in) and when a wall last answered,
// so the widget can say how current its picture is instead of guessing.
//
// One copy for the app, the widget and the share extension: Shared/ is a
// synchronized folder in all three targets. Foundation and CoreGraphics
// only, so the Mac-side unit tests compile it as it ships.

import CoreGraphics
import Foundation

enum WallSnapshot {
    static let group = "group.com.jalenedusei.tessera"
    /// The widget's kind, for reloading only its timelines.
    static let kind = "TesseraWall"

    /// A wall frame this old, with no newer word from the wall, is shown
    /// dimmed and dated rather than as current.
    static let staleAfter: TimeInterval = 600

    struct Record: Codable, Equatable {
        enum Source: String, Codable { case wall, phone }
        enum Link: String, Codable { case live, away, standIn }

        static let version = 2

        var v = Record.version
        /// RGB888 at the wall's own side, before white balance: exactly the
        /// bytes /frame.raw served, or the phone's own picture.
        var frame: Data? = nil
        var side: Int? = nil
        /// The setting. It drives which key is selected.
        var mode = "art"
        /// What is visible: display_mode, except during a guests session.
        var face = "art"
        /// A check on the wall worth naming (panel, calibration, onboarding,
        /// identify, tuning). Never guests.
        var check: String? = nil
        var showingTitle: String? = nil
        var showingArtist: String? = nil
        var playingTitle: String? = nil
        var playingArtist: String? = nil
        /// The weather face's place, and only for that face.
        var place: String? = nil
        /// When a counting timer ends, on the phone's clock.
        var timerEnds: Date? = nil
        var timerRinging = false
        /// "idle" or "away" while the brain's rest policy holds the wall dark.
        var rest: String? = nil
        /// Who drew `frame`.
        var source: Source = .phone
        /// How the app last knew.
        var link: Link = .away
        /// Phone time of the last /state answer from a wall.
        var seen: Date? = nil
        var written = Date()
        /// Stamped only by a wall that answered, so the widget can dial it.
        var host = ""
        /// Something is waiting in the outbox for the wall.
        var queued = false
        /// A mode change was accepted after this frame was taken.
        var outdated = false

        init() {}

        // Decoded field by field with the defaults above, so a record from an
        // older or newer build still reads instead of dropping to "unreadable".
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Record()
            v = try c.decodeIfPresent(Int.self, forKey: .v) ?? d.v
            frame = try c.decodeIfPresent(Data.self, forKey: .frame)
            side = try c.decodeIfPresent(Int.self, forKey: .side)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
            face = try c.decodeIfPresent(String.self, forKey: .face) ?? mode
            check = try c.decodeIfPresent(String.self, forKey: .check)
            showingTitle = try c.decodeIfPresent(String.self, forKey: .showingTitle)
            showingArtist = try c.decodeIfPresent(String.self, forKey: .showingArtist)
            playingTitle = try c.decodeIfPresent(String.self, forKey: .playingTitle)
            playingArtist = try c.decodeIfPresent(String.self, forKey: .playingArtist)
            place = try c.decodeIfPresent(String.self, forKey: .place)
            timerEnds = try c.decodeIfPresent(Date.self, forKey: .timerEnds)
            timerRinging = try c.decodeIfPresent(Bool.self, forKey: .timerRinging) ?? false
            rest = try c.decodeIfPresent(String.self, forKey: .rest)
            source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? d.source
            link = (try? c.decodeIfPresent(Link.self, forKey: .link)) ?? d.link
            seen = try c.decodeIfPresent(Date.self, forKey: .seen)
            written = try c.decodeIfPresent(Date.self, forKey: .written) ?? .distantPast
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
            queued = try c.decodeIfPresent(Bool.self, forKey: .queued) ?? false
            outdated = try c.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
        }
    }

    enum ReadResult: Equatable {
        case record(Record)
        /// Nothing written yet: the app has not run since install.
        case missing
        /// A record exists but cannot be read: before first unlock, or damaged.
        case unreadable
    }

    /// Where the record lives. The shared one is the app group. Tests pass a
    /// temporary folder and their own defaults, so a Mac run never touches
    /// the developer's real group container.
    struct Store {
        let directory: URL
        let defaults: UserDefaults

        init(directory: URL, defaults: UserDefaults) {
            self.directory = directory
            self.defaults = defaults
        }

        static let shared: Store = {
            let files = FileManager.default
            let base = files.containerURL(forSecurityApplicationGroupIdentifier: WallSnapshot.group)?
                .appendingPathComponent("Library", isDirectory: true)
                ?? files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return Store(directory: base.appendingPathComponent("Application Support/Tessera", isDirectory: true),
                         defaults: UserDefaults(suiteName: WallSnapshot.group) ?? .standard)
        }()

        var fileURL: URL { directory.appendingPathComponent("widget-snapshot.json") }

        /// The six keys the record replaced. wall.host, wall.side and
        /// tessera.outbox share the group and are not these.
        static let legacyKeys = ["frame", "title", "artist", "mode", "host", "updated"]

        func read() -> ReadResult {
            let files = FileManager.default
            guard files.fileExists(atPath: fileURL.path) else {
                return legacy().map { .record($0) } ?? .missing
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? WallSnapshot.decoder.decode(Record.self, from: data) else {
                return .unreadable
            }
            return .record(record)
        }

        func write(_ record: Record) {
            var r = record
            r.v = Record.version
            guard let data = try? WallSnapshot.encoder.encode(r) else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                return
            }
            // The first record written retires the old keys. Checked first, so
            // later writes do not touch the shared preferences at all.
            if Self.legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
                Self.legacyKeys.forEach { defaults.removeObject(forKey: $0) }
            }
        }

        /// Merges into the record on file, and does nothing when there is
        /// none: a change to a record nobody wrote has nothing to describe.
        func update(_ mutate: (inout Record) -> Void) {
            guard case .record(var r) = read() else { return }
            mutate(&r)
            write(r)
        }

        /// The snapshot before there was a record: six loose keys. A host
        /// means a wall answered, so its frame is the wall's.
        private func legacy() -> Record? {
            let frame = defaults.data(forKey: "frame")
            let title = defaults.string(forKey: "title")
            let artist = defaults.string(forKey: "artist")
            let mode = defaults.string(forKey: "mode")
            let host = defaults.string(forKey: "host") ?? ""
            let updated = defaults.object(forKey: "updated") as? Date
            guard frame != nil || title != nil || mode != nil || updated != nil else { return nil }
            var r = Record()
            if let frame, let side = Panel.square(frame) {
                r.frame = frame
                r.side = side
            }
            r.showingTitle = title
            r.showingArtist = artist
            r.mode = mode ?? "art"
            r.face = r.mode
            r.host = host
            r.seen = host.isEmpty ? nil : updated
            r.written = updated ?? Date()
            r.source = host.isEmpty ? .phone : .wall
            r.link = .away
            return r
        }

        // MARK: Widget sizes

        /// The size WidgetKit gave each family on this phone, recorded by the
        /// provider from context.displaySize. The page and the render harness
        /// prefer it to the table in WidgetMetrics.
        func measured(_ family: String) -> CGSize? {
            guard let pair = defaults.array(forKey: "widget.measured.\(family)") as? [Double],
                  pair.count == 2, pair[0] > 0, pair[1] > 0 else { return nil }
            return CGSize(width: pair[0], height: pair[1])
        }

        func setMeasured(_ size: CGSize, for family: String) {
            guard size.width > 0, size.height > 0, measured(family) != size else { return }
            defaults.set([Double(size.width), Double(size.height)], forKey: "widget.measured.\(family)")
        }

        #if DEBUG
        /// Captures: no record and no old keys, the state of a fresh install.
        func debugRemove() {
            try? FileManager.default.removeItem(at: fileURL)
            Self.legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        }

        /// Captures: a record that exists and cannot be read.
        func debugWriteUnreadable() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data("{not json".utf8).write(to: fileURL, options: .atomic)
        }
        #endif
    }

    /// The widget measures sizes in these family names.
    static var measured: [String: CGSize] {
        var out: [String: CGSize] = [:]
        for family in ["systemSmall", "systemMedium"] {
            if let size = Store.shared.measured(family) { out[family] = size }
        }
        return out
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: Pins for captures

    #if DEBUG
    /// A capture pinned a fixture into the store. The app's session and the
    /// widget both leave it alone while this is set. Kept in the group
    /// defaults, because the widget runs in a process of its own.
    static var frozen: Bool {
        get { Store.shared.defaults.bool(forKey: "widget.debug.frozen") }
        set { Store.shared.defaults.set(newValue, forKey: "widget.debug.frozen") }
    }

    /// The clock a capture pinned (-widget-now), so "As of" times and stale
    /// flips read the same on every run.
    static var pinnedNow: Date? {
        get {
            (Store.shared.defaults.object(forKey: "widget.debug.now") as? Double)
                .map { Date(timeIntervalSince1970: $0) }
        }
        set {
            if let newValue { Store.shared.defaults.set(newValue.timeIntervalSince1970, forKey: "widget.debug.now") }
            else { Store.shared.defaults.removeObject(forKey: "widget.debug.now") }
        }
    }
    #endif

    /// Now, for reading a record. A capture's pinned clock in debug builds.
    static var now: Date {
        #if DEBUG
        if let pinned = pinnedNow { return pinned }
        #endif
        return Date()
    }

    // MARK: Asking the wall directly

    /// The widget tries the wall itself before falling back to the record.
    /// An extension's local network access can be refused without a prompt,
    /// so this failing is the normal case and must not look like an error.
    ///
    /// Both reads go out at once with short timeouts, since a widget has
    /// seconds, not minutes. The frame comes at the wall's own size (no
    /// ?side), so a live picture and a saved one are drawn the same. The
    /// state read is a peek: a widget reloading on its own is not somebody
    /// at home, and counting it as one would keep an away wall awake.
    static func fetchLive(host: String, carrying cached: Record?, timeout: TimeInterval = 2,
                          now: Date = Date()) async -> Record? {
        guard !host.isEmpty,
              let stateURL = URL(string: "http://\(host)/state?peek=1"),
              let frameURL = URL(string: "http://\(host)/frame.raw") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        async let frameReply = try? session.data(from: frameURL)
        async let stateReply = try? session.data(from: stateURL)
        guard let (frame, frameResponse) = await frameReply,
              (frameResponse as? HTTPURLResponse)?.statusCode == 200,
              let side = Panel.square(frame),
              let (state, stateResponse) = await stateReply,
              (stateResponse as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: state) as? [String: Any] else { return nil }
        return record(facts: WallFacts(json: json), frame: frame, side: side, host: host,
                      queued: cached?.queued ?? false, now: now)
    }

    /// A wall's answer as a record: the same facts the app's session keeps,
    /// so the two paths cannot name one wall two ways.
    static func record(facts: WallFacts, frame: Data?, side: Int?, host: String,
                       queued: Bool, now: Date) -> Record {
        var r = Record()
        r.frame = frame
        r.side = side
        r.mode = facts.mode
        r.face = facts.face
        r.check = facts.check
        r.showingTitle = facts.showingTitle
        r.showingArtist = facts.showingArtist
        r.playingTitle = facts.playingTitle
        r.playingArtist = facts.playingArtist
        r.place = facts.face == "weather" ? facts.place : nil
        r.timerEnds = facts.timerEnds(from: now)
        r.timerRinging = facts.timerRinging
        r.rest = facts.rest
        r.source = .wall
        r.link = .live
        r.seen = now
        r.written = now
        r.host = host
        r.queued = queued
        r.outdated = false
        return r
    }
}
