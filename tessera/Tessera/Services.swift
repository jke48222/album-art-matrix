// Connecting what you play from, with nothing but this phone.
//
// Every service is set up the same way: whatever it needs (an app id, a key,
// a username) is typed or pasted here and handed to the wall, which keeps it
// and starts using it at once. No file on the wall is edited by hand and no
// computer is in the path. The wall reports back what it has, never the
// secrets themselves: a key comes back as "set", an account as its name.

import SwiftUI
import UIKit

// MARK: - What the wall says about its services

struct WallServices: Decodable {
    struct Spotify: Decodable {
        var client_id: String
        var linked: Bool
        var state: String?
        var problem: String?
        var checked_at: Double?
        var retry_after: Double?
        var account_name: String?
        var can_retry: Bool?
    }

    /// Reading needs the username. Writing, the records the ear names, needs
    /// the user token; the rest is the wall's scrobbler saying how that goes.

    /// The wall's ears: a microphone read all the time, Shazam naming the
    /// last few seconds when the room is loud enough. Levels are dB below
    /// the microphone's ceiling, so they are negative and louder is higher.
    struct Hearing: Decodable {
        struct Heard: Decodable {
            var title: String
            var artist: String
            var album: String
            var at_s: Int?          // where in the song the record is now
            var length_s: Int?
        }
        /// A song from the ear's past: heard faintly and waiting, the last
        /// one it put on the wall, or one of the recent few.
        struct Past: Decodable {
            var title: String
            var artist: String
            var album: String
            var heard_s: Int?       // pending: seconds since the faint hearing
            var named_s: Int?       // last_heard: seconds since it went up
            var ended_s: Int?       // last_heard: seconds since it was let go
            var why: String?        // last_heard: why it was let go
            var ago_s: Int?         // recent: seconds since it was named
            var times: Int?         // recent: how many times running
        }
        var on: Bool
        var tools: Bool
        var device: String?
        var mic: String?
        var listening: Bool
        var state: String           // off, no_tools, no_mic, quiet, listening, asking, heard
        var level_db: Double?
        var floor_db: Double?
        var gate_db: Double?
        var gate_open: Bool
        var loud_s: Int?
        var quiet_s: Int?
        var window_s: Double?       // the clip the next ask will send
        var misses: Int?
        var heard_s: Int?
        struct Rejected: Decodable { var reason: String; var ago_s: Int? }
        var match_source: String?
        var last_rejected: Rejected?
        var heard: Heard?
        var pending: Past?          // heard once, no catalogue record: not on the wall yet
        var last_heard: Past?
        var recent: [Past]?
        var attempts: Int?
        var matches: Int?
        var problem: String?
        /// The switch: knocks and whistles the ear has heard.
        struct Knock: Decodable {
            struct Knocks: Decodable { var candidates: Int?; var doubles: Int? }
            struct Whistles: Decodable { var count: Int? }
            var knock: Bool?
            var whistle: Bool?
            var toggles: Int?
            var knocks: Knocks?
            var whistles: Whistles?
        }
        struct Taught: Decodable { var songs: Int?; var landmarks: Int?; var min_score: Int? }
        struct Teacher: Decodable { var by_ear: Bool?; var learning: String? }
        var knock: Knock?
        var taught: Taught?
        var teacher: Teacher?
    }
    struct Mac: Decodable { var endpoint: String; var answering: Bool? }
    /// Ask the wall: whether a Claude key is on the wall and how asking has gone.


    /// AirPlay: whether shairport-sync is there and who is sending.
    struct Airplay: Decodable {
        struct Receiver: Decodable {
            var installed: Bool?
            var version: String?
            var on: Bool?
            var name: String?
            var port: Int?
            var running: Bool?
            var up_s: Int?
            var restarts: Int?
            var external: Bool?
            var problem: String?
        }
        var receiver: Receiver?
        var running: Bool?
        var pipe_exists: Bool?
        var reading: Bool?
        var state: String?
        var connected_from: String?
        var user_agent: String?
        var last: String?
        var error: String?
    }
    /// Imagine: which image model draws, whether its key is on the wall, the bill.
    struct Images: Decodable {
        struct Last: Decodable { var id: String; var prompt: String; var usd: Double?; var ts: Int? }
        var ready: Bool
        var provider: String?
        var model: String?
        var model_used: String?
        var quality: String?
        var images: Int?
        var cost_usd: Double?
        var last: Last?
        var busy: Bool?
        var problem: String?
    }
    /// Posters: whether a TMDB key is on the wall and what it last found.
    struct Tmdb: Decodable {
        struct Last: Decodable { var title: String; var kind: String?; var year: Int?; var at: Int? }
        var key_set: Bool
        var posters: Int?
        var known: Int?
        var last: Last?
        var problem: String?
    }
    /// Pictures: whether a Google key and search engine are on the wall for
    /// "show me", and what it last found.
    struct Google: Decodable {
        struct Last: Decodable { var title: String; var source: String? }
        var key_set: Bool
        var cx_set: Bool
        var pictures: Int?
        var last: Last?
        var problem: String?
    }
    /// The shelf: whose Discogs collection the wall knows, and how the sync went.


    var spotify: Spotify
    var lastfm: Lastfm
    var listenbrainz: Listenbrainz?      // older walls do not send these
    var discogs: Discogs?
    var tmdb: Tmdb?
    var google: Google?
    var images: Images?
    var airplay: Airplay?
    var hearing: Hearing?
    var mac: Mac?
    var claude: Claude?
    var ears: Bool
    var source_order: [String]?
    var rejected: [String]?              // field names the wall would not take

    private enum Keys: String, CodingKey {
        case spotify, lastfm, listenbrainz, discogs, tmdb, google, images, airplay, hearing, mac, claude, ears, source_order, rejected
    }

    /// Each block is read on its own: a wall running a different brain
    /// (an older one, or another builder's) may shape one of them another
    /// way, and that must not grey out every page. What cannot be read
    /// reads as "not set up", and the rest of the wall stays reachable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        spotify = (try? c.decode(Spotify.self, forKey: .spotify)) ?? Spotify(client_id: "", linked: false)
        lastfm = (try? c.decode(Lastfm.self, forKey: .lastfm)) ?? Lastfm(user: "", key_set: nil)
        listenbrainz = try? c.decode(Listenbrainz.self, forKey: .listenbrainz)
        discogs = try? c.decode(Discogs.self, forKey: .discogs)
        tmdb = try? c.decode(Tmdb.self, forKey: .tmdb)
        google = try? c.decode(Google.self, forKey: .google)
        images = try? c.decode(Images.self, forKey: .images)
        airplay = try? c.decode(Airplay.self, forKey: .airplay)
        hearing = try? c.decode(Hearing.self, forKey: .hearing)
        mac = try? c.decode(Mac.self, forKey: .mac)
        claude = try? c.decode(Claude.self, forKey: .claude)
        ears = (try? c.decode(Bool.self, forKey: .ears)) ?? false
        source_order = try? c.decode([String].self, forKey: .source_order)
        rejected = try? c.decode([String].self, forKey: .rejected)
    }

    private static func call(host: String, path: String, body: [String: Any]? = nil) async -> WallServices? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ["spotify", "lastfm", "listenbrainz", "hearing", "claude", "airplay", "images", "discogs"].contains(where: { object[$0] is [String: Any] }) else { return nil }
        return try? JSONDecoder().decode(WallServices.self, from: data)
    }

    static func read(host: String) async -> WallServices? {
        await call(host: host, path: "/services")
    }

    static func retrySpotify(host: String) async -> WallServices? {
        await call(host: host, path: "/spotify/retry", body: [:])
    }

    static func retryLastfm(host: String) async -> WallServices? {
        await call(host: host, path: "/lastfm/retry", body: [:])
    }

    static func retryListenBrainz(host: String) async -> WallServices? {
        await call(host: host, path: "/listenbrainz/retry", body: [:])
    }

    /// Hand the wall new details. Comes back with what the wall now has,
    /// or nil when the wall did not answer.
    static func save(host: String, _ patch: [String: Any]) async -> WallServices? {
        await call(host: host, path: "/services", body: patch)
    }

    static func unlinkSpotify(host: String) async -> WallServices? {
        await call(host: host, path: "/spotify/unlink", body: [:])
    }

    /// What the wall has, after quietly handing it any developer key it is
    /// missing (DeveloperKeys). Account names are always an explicit choice;
    /// an intentionally disconnected account must stay disconnected.
    static func seeded(host: String) async -> WallServices? {
        guard let current = await read(host: host) else { return nil }
        var patch: [String: Any] = [:]
        if !DeveloperKeys.spotifyClientID.isEmpty,
           current.spotify.client_id.isEmpty {
            patch["spotify"] = ["client_id": DeveloperKeys.spotifyClientID]
        }
        var lastfm: [String: String] = [:]
        if !DeveloperKeys.lastfmAPIKey.isEmpty, current.lastfm.key_set != true {
            lastfm["api_key"] = DeveloperKeys.lastfmAPIKey
        }
        if !lastfm.isEmpty { patch["lastfm"] = lastfm }
        if patch.isEmpty { return current }
        return await save(host: host, patch) ?? current
    }
}

extension WallSession {
    /// A wall just answered: make sure it has the app's own keys. Once per
    /// sighting, and nothing at all while no key is baked in.
    func seedWall() {
        guard DeveloperKeys.any else { return }
        let h = host
        Task { _ = await WallServices.seeded(host: h) }
    }
}

/// One place that hands details to the wall and says what happened, in words.
enum ServiceSave {
    static func send(_ patch: [String: Any], to host: String) async -> (WallServices?, String?) {
        guard let fresh = await WallServices.save(host: host, patch) else {
            return (nil, "The wall is not answering right now.")
        }
        if let r = fresh.rejected, !r.isEmpty {
            return (fresh, "The wall did not take " + r.joined(separator: ", ") + ". Check for typos.")
        }
        return (fresh, nil)
    }
}

// MARK: - Small parts the pages share

/// A row's state at its trailing edge, leading somewhere: green when done.
struct StateValue: View {
    let text: String
    var done: Bool
    init(_ text: String, done: Bool = false) { self.text = text; self.done = done }
    var body: some View {
        HStack(spacing: 8) {
            if done {
                Done(text: text)
            } else {
                Text(text).font(.ui(14)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Chevron()
        }
    }
}

/// A field for a key, an id or a username: machine face, nothing corrected.
struct KeyField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.machine(13))
            .foregroundStyle(Ink.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
    }
}

/// The inline save line under a group of fields.
struct SaveLine: View {
    let title: String
    let enabled: Bool
    let busy: Bool
    let done: String?
    let accent: Color
    var action: () -> Void

    var body: some View {
        HStack {
            Button(busy ? "Saving" : title, action: action)
                .buttonStyle(PressStyle(scale: 0.97))
                .font(.ui(13, .semibold))
                .foregroundStyle(enabled ? accent : Ink.faint)
                .disabled(!enabled || busy)
            Spacer()
            if let done { Done(text: done) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// What just went wrong, in the warning colour, or nothing.
struct Problem: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.ui(13))
                .foregroundStyle(Ink.signal)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - The hub


// MARK: - ListenBrainz



// MARK: - Claude: the key that lets the wall answer questions



// MARK: - Discogs: the shelf, so the wall knows what is owned on vinyl



// MARK: - Pictures: a Google key and search engine, so "show me" searches Google Images

struct PicturesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var key = ""
    @State private var cx = ""
    @State private var busy = false
    @State private var problem: String?

    private var google: WallServices.Google? { services?.google }
    private var ready: Bool { google?.key_set == true && google?.cx_set == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedCx: String { cx.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil, !typedKey.isEmpty || !typedCx.isEmpty else { return false }
        let keyOK = typedKey.isEmpty ? google?.key_set == true : typedKey.count >= 30
        let cxOK = typedCx.isEmpty ? google?.cx_set == true : typedCx.count >= 8
        return keyOK && cxOK
    }
    private var foundLine: String {
        guard let g = google else { return "" }
        if !ready { return "Without a key the wall searches the web, then Wikipedia." }
        let n = g.pictures ?? 0
        if n == 0 { return "Ready. Say \"show me the Eiffel Tower\"." }
        return n == 1 ? "One picture found so far." : "\(n) pictures found so far."
    }

    var body: some View {
        SetupPage("Pictures",
                  blurb: "\"Show me the Eiffel Tower\" puts a picture of it on the wall. With a Google key and a search engine of your own it searches Google Images; without them it searches the web through DuckDuckGo, then Wikipedia.") {
            SetupGroup("Your Google key", note: "Free for a hundred searches a day. An API key from the Google Cloud console with the Custom Search API turned on, and the id of a Programmable Search Engine set to search the entire web with image search on. Both kept on the wall.") {
                KeyField(placeholder: google?.key_set == true ? "API key (one is on the wall)" : "API key", text: $key)
                Rule()
                KeyField(placeholder: google?.cx_set == true ? "Search engine id (one is on the wall)" : "Search engine id", text: $cx)
                Rule()
                SetupRow(title: "Need them?", subtitle: "Opens Programmable Search Engine in Safari. Make an engine that searches the entire web with image search on; its id is on the Basics page, and the API key is under Custom Search JSON API, Get a key.") {
                    ActionPill(title: "Get them", filled: false) {
                        openURL(URL(string: "https://programmablesearchengine.google.com/controlpanel/all")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: (ready && typedKey.isEmpty && typedCx.isEmpty) ? "On the wall" : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem ?? google?.problem)

            SetupGroup("On the wall", note: "Google first when it is set up, the web otherwise, then the lead image of the thing's Wikipedia page, then an open photo library. A picture stays up for ten minutes.") {
                SetupRow(title: "Found", subtitle: foundLine) { EmptyView() }
                if let l = google?.last {
                    Rule()
                    SetupRow(title: "Last picture", subtitle: l.title + (l.source.map { ", from \($0)" } ?? "")) {
                        EmptyView()
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        var patch: [String: Any] = [:]
        if !typedKey.isEmpty { patch["api_key"] = typedKey }
        if !typedCx.isEmpty { patch["cx"] = typedCx }
        Task {
            let (fresh, why) = await ServiceSave.send(["google": patch], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); key = ""; cx = "" }
            busy = false
        }
    }
}

// MARK: - Posters: the TMDB key, so what the Mac watches gets its poster

struct PostersPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?

    private var tmdb: WallServices.Tmdb? { services?.tmdb }
    private var ready: Bool { tmdb?.key_set == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil else { return false }
        let hex = typedKey.count == 32 && typedKey.allSatisfy { $0.isHexDigit }
        return hex || (typedKey.hasPrefix("eyJ") && typedKey.count > 40)
    }
    private var foundLine: String {
        guard let t = tmdb, t.key_set else { return "Paste your key above." }
        let n = t.posters ?? 0
        if n == 0 { return "Nothing looked up yet. Play an episode or a film in a browser on the Mac." }
        return n == 1 ? "One poster found so far." : "\(n) posters found so far."
    }

    var body: some View {
        SetupPage("Posters",
                  blurb: "When the Mac watches an episode or a film in a browser, macOS names it but offers the browser's icon as the picture, so the wall used to look away. With a key for The Movie Database the wall finds the show's poster and wears that instead, and the night's viewing goes in the journal as a show.") {
            SetupGroup("Your key", note: "Free. An API key (32 characters) or a read access token from your TMDB account settings, under API. Kept on the wall and used only to look up names.") {
                KeyField(placeholder: ready ? "TMDB key (one is on the wall)" : "TMDB API key or read access token", text: $key)
                Rule()
                SetupRow(title: "Need a key?", subtitle: "Opens TMDB's API settings in Safari. An account takes a minute; the key is under Create.") {
                    ActionPill(title: "Get a key", filled: false) {
                        openURL(URL(string: "https://www.themoviedb.org/settings/api")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: (ready && typedKey.isEmpty) ? "Key on the wall" : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem ?? tmdb?.problem)

            SetupGroup("On the wall", note: "The Mac's reporter passes the name of a show along; the wall asks TMDB for television first, then films, and keeps what it finds for a month. A name TMDB does not know leaves the wall as it was.") {
                SetupRow(title: "Found", subtitle: foundLine) { EmptyView() }
                if let l = tmdb?.last {
                    Rule()
                    SetupRow(title: "Last poster", subtitle: l.title + (l.year.map { ", \($0)" } ?? "") + (l.kind == "movie" ? ", a film" : ", a series")) {
                        EmptyView()
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["tmdb": ["api_key": typedKey]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); key = "" }
            busy = false
        }
    }
}


// MARK: - Images: the drawer and its key, for pictures from words

struct ImagesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?

    private var im: WallServices.Images? { services?.images }
    private var ready: Bool { im?.ready == true }
    private var provider: String { im?.provider ?? "openai" }
    private var quality: String { im?.quality ?? "medium" }
    private var modelLine: String {
        guard let im else { return "" }
        if let used = im.model_used, !used.isEmpty, used != im.model {
            return "\(used) (asked for \(im.model ?? ""), which this key cannot reach)"
        }
        return im.model ?? ""
    }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { services != nil && typedKey.count >= 20 }
    private var costLine: String {
        guard let im else { return "" }
        let n = im.images ?? 0
        if n == 0 { return "Nothing drawn yet." }
        return "\(n) drawn, about $\(String(format: "%.2f", im.cost_usd ?? 0)) in all."
    }

    var body: some View {
        SetupPage("Images",
                  blurb: "\"Create a purple elephant\" draws one on the panel. Claude writes the words out as a prompt made for a panel this size, an image model draws it, and the picture stays up for ten minutes. Every picture is kept on the wall, with its words, under Imagine in Settings.") {
            SetupGroup("Who draws", note: provider == "google"
                       ? "Google's Imagen through the Gemini API. About four cents a picture."
                       : "OpenAI's gpt-image-1 at low quality, which is plenty for a panel. About a cent a picture.") {
                ChoiceRow(title: "OpenAI", subtitle: "gpt-image-1", value: "openai", selected: provider, accent: accent) { pick($0) }
                Rule()
                ChoiceRow(title: "Google", subtitle: "Imagen 4", value: "google", selected: provider, accent: accent) { pick($0) }
            }
            .padding(.top, -12)

            SetupGroup("Your key", note: "Kept on the wall and used only to draw. Change the drawer above and paste that drawer's key.") {
                KeyField(placeholder: ready ? "API key (one is on the wall)" : (provider == "google" ? "Gemini API key" : "OpenAI API key, sk-..."), text: $key)
                Rule()
                SetupRow(title: "Need a key?", subtitle: provider == "google" ? "Opens Google AI Studio in Safari." : "Opens the OpenAI platform in Safari.") {
                    ActionPill(title: "Get a key", filled: false) {
                        openURL(URL(string: provider == "google" ? "https://aistudio.google.com/apikey"
                                                                : "https://platform.openai.com/api-keys")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: (ready && typedKey.isEmpty) ? "Key on the wall" : nil,
                         accent: accent) { save() }
            }
            Problem(text: problem ?? im?.problem)

            SetupGroup("Quality", note: provider == "google"
                       ? "Imagen Ultra draws every picture; the quality choice is OpenAI's."
                       : "Medium is a good picture in well under a minute, about four cents on gpt-image-1. High is the most detailed the model makes and takes minutes, about seventeen cents. Low is a cent and rough. The wall shows every picture being drawn either way.") {
                ChoiceRow(title: "Medium", subtitle: "Good and quick", value: "medium", selected: quality, accent: accent) { pick(quality: $0) }
                Rule()
                ChoiceRow(title: "High", subtitle: "Every detail, minutes to draw", value: "high", selected: quality, accent: accent) { pick(quality: $0) }
                Rule()
                ChoiceRow(title: "Low", subtitle: "Quick and rough", value: "low", selected: quality, accent: accent) { pick(quality: $0) }
            }

            SetupGroup("So far", note: "One picture every ten seconds at most.") {
                SetupRow(title: "Drawing with", subtitle: modelLine) { EmptyView() }
                Rule()
                SetupRow(title: "Drawn", subtitle: costLine) { EmptyView() }
                if let l = im?.last {
                    Rule()
                    SetupRow(title: "Last", subtitle: l.prompt) { EmptyView() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }

    private func pick(_ who: String) {
        guard who != provider else { return }
        Taps.detent(intensity: 0.4)
        Task {
            let (fresh, why) = await ServiceSave.send(["images": ["provider": who]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
        }
    }

    private func pick(quality q: String) {
        guard q != quality else { return }
        Taps.detent(intensity: 0.4)
        Task {
            let (fresh, why) = await ServiceSave.send(["images": ["quality": q]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
        }
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["images": ["api_key": typedKey, "provider": provider]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); key = "" }
            busy = false
        }
    }
}


// MARK: - AirPlay: the wall as a receiver, and what is coming in

struct AirPlayPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @Binding var services: WallServices?
    @State private var name = ""

    private var ap: WallServices.Airplay? { services?.airplay }
    private var rx: WallServices.Airplay.Receiver? { ap?.receiver }
    private var typedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var receiving: (String, Bool) {
        guard let ap else { return ("The wall is not answering.", false) }
        if let rx {
            if rx.on == false { return ("Off. Turn it on below.", false) }
            if rx.installed == false { return ("Not installed on the Pi yet: pi/install-airplay.sh.", false) }
            if rx.external != true && rx.running != true { return (rx.problem ?? "Starting.", false) }
        } else if ap.running != true {
            return ("No receiver on this wall.", false)
        }
        switch ap.state {
        case "playing": return ("Playing" + (ap.last.map { ": \($0)" } ?? ""), true)
        case "paused": return ("Paused" + (ap.last.map { ": \($0)" } ?? ""), true)
        default: return ("Ready. Pick \u{201C}\(rx?.name ?? "Wall")\u{201D} in the AirPlay menu.", true)
        }
    }

    var body: some View {
        SetupPage("AirPlay",
                  blurb: "The wall is an AirPlay speaker. Pick it in the AirPlay menu on an iPhone, iPad, Mac or Apple TV and the wall is handed the exact title, artwork and position of whatever plays, from any app. No account and no key. The wall makes no sound of its own, so play to it together with your speaker.") {
            SetupGroup("Now", note: nil) {
                SetupRow(title: "Receiving", subtitle: receiving.0) {
                    StateValue(receiving.1 ? "On" : "Off", done: receiving.1)
                }
                if let from = ap?.connected_from, !from.isEmpty, ap?.state != "idle" {
                    Rule()
                    SetupRow(title: "From", subtitle: from) { EmptyView() }
                }
            }
            .padding(.top, -12)

            SetupGroup("The speaker", note: "Classic AirPlay, run by the wall itself, so every iPhone, iPad, Mac and Apple TV can choose it. Grouping it with HomePods in the Home app needs AirPlay 2, which needs root on the Pi; see docs/AIRPLAY.md.") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Be an AirPlay speaker").font(.ui(15)).foregroundStyle(Ink.ink)
                        Text(speakerLine).font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { rx?.on ?? true },
                                             set: { v in wall.send(["airplay_receiver": v]); Taps.detent(intensity: 0.4); refreshSoon() }))
                        .labelsHidden().tint(accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Rule()
                KeyField(placeholder: rx?.name ?? "Wall", text: $name)
                Rule()
                SaveLine(title: "Use this name", enabled: !typedName.isEmpty && typedName != rx?.name,
                         busy: false, done: typedName.isEmpty ? (rx?.name).map { "Shown as \u{201C}\($0)\u{201D}" } : nil,
                         accent: accent) { rename() }
                if let v = rx?.version {
                    Rule()
                    SetupRow(title: "shairport-sync", subtitle: v.components(separatedBy: "-").first ?? v) { EmptyView() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var speakerLine: String {
        guard let rx else { return "" }
        if rx.external == true { return "Run by the Pi's own shairport-sync." }
        if rx.running == true { return "Up" + (rx.up_s.map { ", \(duration($0))" } ?? "") + ", port \(rx.port ?? 5000)" }
        if rx.on == false { return "Off" }
        return rx.problem ?? "Starting"
    }

    private func duration(_ s: Int) -> String { s < 90 ? "\(s) s" : s < 5400 ? "\(s / 60) min" : "\(s / 3600) h" }

    private func refreshSoon() {
        let h = wall.host
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if let fresh = await WallServices.read(host: h) { services = fresh }
        }
    }

    private func rename() {
        guard !typedName.isEmpty else { return }
        wall.send(["airplay_name": String(typedName.prefix(40))])
        Taps.commit()
        name = ""
        refreshSoon()
    }
}
