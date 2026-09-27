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
    struct Lastfm: Decodable { var user: String; var key_set: Bool? }
    /// Reading needs the username. Writing, the records the ear names, needs
    /// the user token; the rest is the wall's scrobbler saying how that goes.
    struct Listenbrainz: Decodable {
        struct Listen: Decodable {
            var title: String
            var artist: String
            var album: String?
            var at: Int             // unix seconds the play started
            var kind: String?
        }
        struct Playing: Decodable {
            var title: String
            var artist: String
            var heard_s: Int
            var needs_s: Int
            var listened: Bool
        }
        var user: String
        var token_set: Bool?
        var valid: Bool?
        var user_name: String?
        var playing: Playing?
        var last_listen: Listen?
        var queued: Int?
        var submitted: Int?
        var problem: String?
    }
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
    struct Claude: Decodable {
        struct Last: Decodable { var q: String; var a: String; var s: Double?; var usd: Double?; var ts: Int? }
        var ready: Bool?
        var key_set: Bool?
        var workspace_set: Bool?
        var history: [Last]?
        /// A key is on the wall, whichever word the wall uses for it.
        var isReady: Bool { ready ?? key_set ?? false }
        var model: String?
        var answers: Int?
        var cost_usd: Double?
        var last: Last?
        var problem: String?
    }

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
    struct Discogs: Decodable {
        var user: String
        var token_set: Bool?
        var releases: Int?
        var synced_at: Double?
        var syncing: Bool?
        var problem: String?
    }

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

    /// Hand the wall new details. Comes back with what the wall now has,
    /// or nil when the wall did not answer.
    static func save(host: String, _ patch: [String: Any]) async -> WallServices? {
        await call(host: host, path: "/services", body: patch)
    }

    static func unlinkSpotify(host: String) async -> WallServices? {
        await call(host: host, path: "/spotify/unlink", body: [:])
    }

    /// What the wall has, after quietly handing it any developer key it is
    /// missing (DeveloperKeys). A person only ever signs in or types a name.
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
        if !DeveloperKeys.lastfmUser.isEmpty, current.lastfm.user.isEmpty {
            lastfm["user"] = DeveloperKeys.lastfmUser
        }
        if !lastfm.isEmpty { patch["lastfm"] = lastfm }
        if !DeveloperKeys.listenbrainzUser.isEmpty, (current.listenbrainz?.user ?? "").isEmpty {
            patch["listenbrainz"] = ["user": DeveloperKeys.listenbrainzUser]
        }
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

struct LastfmPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var user = ""
    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?

    private var savedUser: String { services?.lastfm.user ?? "" }
    private var keyBaked: Bool { !DeveloperKeys.lastfmAPIKey.isEmpty }
    private var keySet: Bool { services?.lastfm.key_set == true }
    private var on: Bool { !savedUser.isEmpty && keySet }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil, !typedUser.isEmpty else { return false }
        return typedUser != savedUser || (!keyBaked && !typedKey.isEmpty)
    }

    private var blurb: String {
        "One account that Spotify, Tidal and Deezer report to on their own. The wall reads it a few seconds behind the music. Free; "
            + (keyBaked ? "needs only your username." : "needs your username and a key.")
    }
    private var accountNote: String {
        keyBaked ? "Your username is the last part of your profile address on last.fm."
                 : "Last.fm hands any account a key: on the key page, name the application anything and leave the rest empty, then copy the API key it shows. Not the shared secret."
    }

    var body: some View {
        SetupPage("Last.fm", blurb: blurb) {
            SetupGroup("Your account", note: accountNote) {
                KeyField(placeholder: "Username", text: $user)
                Rule()
                if !keyBaked {
                    KeyField(placeholder: keySet ? "API key (one is on the wall)" : "API key", text: $key)
                    Rule()
                    SetupRow(title: "Need a key?", subtitle: "Opens last.fm in Safari.") {
                        ActionPill(title: "Get a key", filled: false) {
                            openURL(URL(string: "https://www.last.fm/api/account/create")!)
                        }
                    }
                    Rule()
                }
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: on && !canSave ? "Following \(savedUser)" : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem)

            SetupGroup("Send your players to it", note: "Nothing here needs Premium or an app id. On a computer, the Web Scrobbler browser extension adds YouTube Music, SoundCloud and Amazon Music.") {
                SetupRow(title: "Spotify", subtitle: "Linked on last.fm, under Applications.",
                         leading: { ServiceMark(service: .spotify) }) {
                    ActionPill(title: "Link", filled: false) {
                        openURL(URL(string: "https://www.last.fm/settings/applications")!)
                    }
                }
                Rule()
                SetupRow(title: "Tidal", subtitle: "In Tidal: Settings, then Connect to Last.fm. Desktop, web and iPhone.",
                         leading: { ServiceMark(service: .tidal) }) { EmptyView() }
                Rule()
                SetupRow(title: "Deezer", subtitle: "Linked on deezer.com, under Sharing. Covers the phone too.",
                         leading: { ServiceMark(service: .deezer) }) {
                    ActionPill(title: "Link", filled: false) {
                        openURL(URL(string: "https://www.deezer.com/account/share")!)
                    }
                }
            }
        }
        .onAppear { user = savedUser }
        .onChange(of: savedUser) { _, fresh in if user.isEmpty { user = fresh } }
    }

    private func save() {
        guard canSave, !busy else { return }
        var patch: [String: Any] = ["user": typedUser]
        if keyBaked, !keySet { patch["api_key"] = DeveloperKeys.lastfmAPIKey }
        else if !typedKey.isEmpty { patch["api_key"] = typedKey }   // empty would clear the one on the wall
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["lastfm": patch], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { key = ""; Taps.commit() }
            busy = false
        }
    }
}

// MARK: - ListenBrainz

struct ListenBrainzPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var user = ""
    @State private var token = ""
    @State private var busy = false
    @State private var problem: String?

    private var lb: WallServices.Listenbrainz? { services?.listenbrainz }
    private var savedUser: String { lb?.user ?? "" }
    private var tokenSet: Bool { lb?.token_set == true }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil else { return false }
        if !typedToken.isEmpty { return true }
        return !typedUser.isEmpty && typedUser != savedUser
    }
    private var doneLine: String? {
        guard !savedUser.isEmpty, typedUser == savedUser, typedToken.isEmpty else { return nil }
        return tokenSet ? "Following \(savedUser), writing records" : "Following \(savedUser)"
    }
    /// The records row's state: what the wall's scrobbler says of the token.
    private var recordsState: (text: String, done: Bool) {
        guard let lb else { return ("Set up", false) }
        if lb.token_set != true { return ("Needs your token", false) }
        switch lb.valid {
        case .some(true): return ("On" + (lb.user_name.map { " as \($0)" } ?? ""), true)
        case .some(false): return ("Token refused", false)
        default: return (lb.problem ?? "Checking", false)
        }
    }
    private var recordsSubtitle: String {
        guard let lb else { return "The wall is not answering." }
        if let n = lb.submitted, n > 0 { return n == 1 ? "One listen written so far." : "\(n) listens written so far." }
        if lb.token_set == true { return "Nothing written yet. Play a record." }
        return "Paste your user token above."
    }

    var body: some View {
        SetupPage("ListenBrainz",
                  blurb: "The open version of Last.fm, run by the MusicBrainz people. Free. Your username lets the wall read what you play; your user token lets it write down the records it hears.") {
            SetupGroup("Your account", note: "An account takes a minute. Then every scrobbler that can post there (Web Scrobbler in a computer's browser, Pano Scrobbler on Android) reaches the wall.") {
                KeyField(placeholder: "Username", text: $user)
                Rule()
                KeyField(placeholder: tokenSet ? "User token (one is on the wall)" : "User token", text: $token)
                Rule()
                SetupRow(title: "Your token", subtitle: "On your ListenBrainz settings page, under User token. Opens in Safari.") {
                    ActionPill(title: "Open settings", filled: false) {
                        openURL(URL(string: "https://listenbrainz.org/settings/")!)
                    }
                }
                Rule()
                SetupRow(title: "No account yet?", subtitle: "Opens listenbrainz.org in Safari.") {
                    ActionPill(title: "Make one", filled: false) {
                        openURL(URL(string: "https://listenbrainz.org/")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: doneLine, accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem)

            SetupGroup("The wall's records",
                       note: "Every record the ear names goes into your listening history like a streamed song: half the song or four minutes, whichever comes first. Listens the wall could not send wait and go later.") {
                SetupRow(title: "Writing records", subtitle: recordsSubtitle) {
                    StateValue(recordsState.text, done: recordsState.done)
                }
                if let p = lb?.playing {
                    Rule()
                    SetupRow(title: p.title,
                             subtitle: p.artist + (p.listened ? ", counted" : ", \(p.heard_s) of \(p.needs_s) s heard")) {
                        EmptyView()
                    }
                }
                if let l = lb?.last_listen {
                    Rule()
                    SetupRow(title: "Last written", subtitle: "\(l.title), \(l.artist), \(ago(l.at))") {
                        EmptyView()
                    }
                }
                if let q = lb?.queued, q > 0 {
                    Rule()
                    SetupRow(title: "Waiting to send",
                             subtitle: q == 1 ? "One listen, until the network is back." : "\(q) listens, until the network is back.") {
                        EmptyView()
                    }
                }
            }
        }
        .onAppear { user = savedUser }
        .onChange(of: savedUser) { _, fresh in if user.isEmpty { user = fresh } }
        .task {
            // the records group is live while the page is up: the scrobbler's
            // state changes as a record plays, and a token check takes a moment
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }

    private func ago(_ unix: Int) -> String {
        let s = Int(Date().timeIntervalSince1970) - unix
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        var patch: [String: String] = [:]
        if !typedUser.isEmpty { patch["user"] = typedUser }
        if !typedToken.isEmpty { patch["token"] = typedToken }
        Task {
            let (fresh, why) = await ServiceSave.send(["listenbrainz": patch], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); token = "" }
            busy = false
        }
    }
}


// MARK: - Claude: the key that lets the wall answer questions

struct ClaudePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var key = ""
    @State private var workspace = ""
    @State private var busy = false
    @State private var problem: String?

    private var claude: WallServices.Claude? { services?.claude }
    private var ready: Bool { claude?.isReady == true }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedWorkspace: String { workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil else { return false }
        if typedKey.hasPrefix("sk-ant-") && typedKey.count > 20 { return true }
        return typedWorkspace.hasPrefix("wrkspc_") && typedWorkspace.count > 10
    }
    private var needsWorkspace: Bool {
        (claude?.problem ?? "").contains("workspace") && claude?.workspace_set != true
    }

    var body: some View {
        SetupPage("Claude",
                  blurb: "Say the wake word and ask the wall anything: what played at dinner, how long until sunset, what this record is about. The words go to Claude with the wall's own state, and the answer is drawn on the panel. A Siri Shortcut can ask too and speak the answer back.") {
            SetupGroup("Your key", note: "An Anthropic API key. It is kept on the wall and used for nothing but these questions; each answer costs about a cent.") {
                KeyField(placeholder: ready ? "API key (one is on the wall)" : "API key, sk-ant-...", text: $key)
                Rule()
                KeyField(placeholder: claude?.workspace_set == true ? "Workspace id (one is on the wall)" : "Workspace id, wrkspc_... (only if the wall asks)", text: $workspace)
                Rule()
                SetupRow(title: "Need a key?", subtitle: "Opens the Anthropic console in Safari. A key made inside a workspace needs nothing else; a key made at the organisation level also needs that workspace's id, from Settings, Workspaces.") {
                    ActionPill(title: "Get a key", filled: false) {
                        openURL(URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: (ready && typedKey.isEmpty && typedWorkspace.isEmpty) ? (claude?.workspace_set == true ? "Key and workspace on the wall" : "Key on the wall") : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem ?? (needsWorkspace
                ? "Your key was made at the organisation level, so the wall also needs the workspace id it spends from. In the Anthropic console: Settings, Workspaces, open one, copy its id (wrkspc_...) and paste it above."
                : claude?.problem))

            SetupGroup("Asking", note: "Say the wake word, wait for the line, then talk. Commands (off, clock, lyrics, brighter, a timer, show me a cover) are done on the wall itself; anything else is a question. Ask from this phone under Settings, Ask the wall. Shortcut recipes for Siri are in docs/ASK.md.") {
                SetupRow(title: "Model", subtitle: claude?.model ?? "claude-opus-5") { EmptyView() }
                Rule()
                SetupRow(title: "Answered", subtitle: answeredLine) { EmptyView() }
                if let last = claude?.last {
                    Rule()
                    SetupRow(title: "Last question", subtitle: "\(last.q)  ·  \(last.a)") { EmptyView() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }

    private var answeredLine: String {
        let n = claude?.answers ?? 0
        let usd = claude?.cost_usd ?? 0
        if n == 0 { return "Nothing asked yet." }
        return String(format: "%d question%@, about $%.2f so far.", n, n == 1 ? "" : "s", usd)
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        var patch: [String: String] = [:]
        if !typedKey.isEmpty { patch["api_key"] = typedKey }
        if !typedWorkspace.isEmpty { patch["workspace"] = typedWorkspace }
        Task {
            let (fresh, why) = await ServiceSave.send(["claude": patch], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); key = ""; workspace = "" }
            busy = false
        }
    }
}


// MARK: - Discogs: the shelf, so the wall knows what is owned on vinyl

struct DiscogsPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var user = ""
    @State private var token = ""
    @State private var busy = false
    @State private var problem: String?

    private var dg: WallServices.Discogs? { services?.discogs }
    private var savedUser: String { dg?.user ?? "" }
    private var tokenSet: Bool { dg?.token_set == true }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard services != nil else { return false }
        if !typedToken.isEmpty { return true }
        return !typedUser.isEmpty && typedUser != savedUser
    }
    private var doneLine: String? {
        guard !savedUser.isEmpty, typedUser == savedUser, typedToken.isEmpty else { return nil }
        return tokenSet ? "Reading \(savedUser)'s shelf" : "Username on the wall"
    }
    var body: some View {
        SetupPage("Discogs",
                  blurb: "Discogs is where a record collection is written down, pressing by pressing. With your username and a personal access token the wall reads your shelf. A streamed song from an album you own gets a small record in the sleeve's corner, and when one of your records plays, the pressing and what copies are going for show under the song.") {
            SetupGroup("Your account", note: "Free. The token is kept on the wall and used only to read your collection and look up your pressings.") {
                KeyField(placeholder: "Username", text: $user)
                Rule()
                KeyField(placeholder: tokenSet ? "Personal access token (one is on the wall)" : "Personal access token", text: $token)
                Rule()
                SetupRow(title: "Your token", subtitle: "Discogs settings, Developers, Generate new token. Opens in Safari.") {
                    ActionPill(title: "Open settings", filled: false) {
                        openURL(URL(string: "https://www.discogs.com/settings/developers")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall", enabled: canSave, busy: busy,
                         done: doneLine, accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem)

            SetupGroup("Your collection", note: "Browse your records, see their pressing details and read the latest collection in The shelf.") {
                NavigationLink { ShelfPage(accent: accent) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "opticaldisc").foregroundStyle(accent.toned(forDark: true))
                        Text("Open The shelf").font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(Ink.dim)
                    }.frame(minHeight: 48)
                }
            }
        }
        .onAppear { user = savedUser }
        .onChange(of: savedUser) { _, fresh in if user.isEmpty { user = fresh } }
        .onChange(of: wall.host) { _, _ in
            user = ""; token = ""; busy = false; problem = nil; services = nil
        }
        .task(id: wall.host) {
            let host = wall.host
            while !Task.isCancelled {
                if let fresh = await WallServices.read(host: host), !Task.isCancelled, wall.host == host { services = fresh }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        var patch: [String: String] = [:]
        if !typedUser.isEmpty { patch["user"] = typedUser }
        if !typedToken.isEmpty { patch["token"] = typedToken }
        let host = wall.host
        Task {
            let (fresh, why) = await ServiceSave.send(["discogs": patch], to: host)
            guard !Task.isCancelled, wall.host == host else { return }
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); token = "" }
            busy = false
        }
    }

}


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
