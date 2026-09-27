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

    /// Ask the wall: whether a Claude key is on the wall and how asking has gone.


    /// AirPlay: whether shairport-sync is there and who is sending.

    /// Imagine: which image model draws, whether its key is on the wall, the bill.

    /// Posters: whether a TMDB key is on the wall and what it last found.

    /// Pictures: whether a Google key and search engine are on the wall for
    /// "show me", and what it last found.
    struct Google: Decodable {
        var state: String?
        var verified: Bool?
        var checking: Bool?
        var checked_at: Double?
        /// frame: the wall kept the square it made, at GET /pictures/last.png.
        struct Last: Decodable { var title: String; var source: String?; var art_url: String?; var credit: String?; var at: Double?; var frame: Bool? }
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

    /// What one call to the wall came to. `status` is nil only when the wall
    /// did not answer at all, so a save the wall refused (a 503 when its disk
    /// write failed) is not reported as a wall that is not answering.
    struct Outcome {
        var services: WallServices?
        var status: Int?
        var error: String?          // the wall's own words for a refusal
    }

    private static func exchange(host: String, path: String, body: [String: Any]? = nil) async -> Outcome {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return Outcome() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return Outcome() }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            return Outcome(status: status, error: (object?["error"] as? String).map { String($0.prefix(240)) })
        }
        guard let object,
              ["spotify", "lastfm", "listenbrainz", "hearing", "claude", "airplay", "images", "discogs"].contains(where: { object[$0] is [String: Any] }) else { return Outcome(status: status) }
        return Outcome(services: try? JSONDecoder().decode(WallServices.self, from: data), status: status)
    }

    private static func call(host: String, path: String, body: [String: Any]? = nil) async -> WallServices? {
        await exchange(host: host, path: path, body: body).services
    }

    static func read(host: String) async -> WallServices? {
        await call(host: host, path: "/services")
    }

    static func retrySpotify(host: String) async -> WallServices? {
        await call(host: host, path: "/spotify/retry", body: [:])
    }

    static func retryMac(host: String) async -> WallServices? {
        await call(host: host, path: "/mac/retry", body: [:])
    }

    /// The whole outcome, not just the services: a refused check (a 400
    /// that names what to type instead) carries the wall's own words.
    static func checkPosters(host: String, title: String = "") async -> Outcome {
        await exchange(host: host, path: "/posters/check", body: ["title": title])
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
        await submit(host: host, patch).services
    }

    /// A save with how it went, for pages that say what failed.
    static func submit(host: String, _ patch: [String: Any]) async -> Outcome {
        await exchange(host: host, path: "/services", body: patch)
    }

    static func unlinkSpotify(host: String) async -> Outcome {
        await exchange(host: host, path: "/spotify/unlink", body: [:])
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
        let outcome = await WallServices.submit(host: host, patch)
        guard let fresh = outcome.services else { return (nil, failure(outcome)) }
        if let r = fresh.rejected, !r.isEmpty {
            return (fresh, "The wall did not take " + r.joined(separator: ", ") + ". Check for typos.")
        }
        return (fresh, nil)
    }

    /// A wall that answered but did not save is not a wall that is away.
    /// The wall's 503 means its own disk write failed.
    static func failure(_ outcome: WallServices.Outcome) -> String {
        switch outcome.status {
        case nil: return "The wall is not answering right now."
        case 503: return "The wall could not save this. Try again."
        case 200: return "The wall's reply could not be read. Try again."
        default: return "The wall did not accept this change. Try again."
        }
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

// MARK: - Posters: the TMDB key, so what the Mac watches gets its poster

// MARK: - Images: the drawer and its key, for pictures from words

// MARK: - AirPlay: the wall as a receiver, and what is coming in
