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
    struct Spotify: Decodable { var client_id: String; var linked: Bool }
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
    var images: Images?
    var airplay: Airplay?
    var hearing: Hearing?
    var mac: Mac?
    var claude: Claude?
    var ears: Bool
    var rejected: [String]?              // field names the wall would not take

    private enum Keys: String, CodingKey {
        case spotify, lastfm, listenbrainz, discogs, tmdb, images, airplay, hearing, mac, claude, ears, rejected
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
        images = try? c.decode(Images.self, forKey: .images)
        airplay = try? c.decode(Airplay.self, forKey: .airplay)
        hearing = try? c.decode(Hearing.self, forKey: .hearing)
        mac = try? c.decode(Mac.self, forKey: .mac)
        claude = try? c.decode(Claude.self, forKey: .claude)
        ears = (try? c.decode(Bool.self, forKey: .ears)) ?? false
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
        return try? JSONDecoder().decode(WallServices.self, from: data)
    }

    static func read(host: String) async -> WallServices? {
        await call(host: host, path: "/services")
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
           current.spotify.client_id != DeveloperKeys.spotifyClientID {
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

struct ServicesPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?
    @Binding var musicConnected: Bool
    @Binding var musicRefused: Bool

    var body: some View {
        SetupPage("Services",
                  blurb: "Connect what you play from. Apple Music is read on this phone. Everything else is read by the wall, and set up from here.") {
            SetupGroup("Connected here", note: nil) {
                appleRow
            }
            .padding(.top, -12)

            SetupGroup("Read by the wall", note: wallNote) {
                NavigationLink {
                    SpotifyPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Spotify", subtitle: spotifyLine,
                             leading: { ServiceMark(service: .spotify) }) {
                        StateValue(spotifyState, done: services?.spotify.linked == true)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    LastfmPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Last.fm", subtitle: lastfmLine,
                             leading: { ServiceMark(service: .lastfm) }) {
                        StateValue(lastfmOn ? "Connected" : "Set up", done: lastfmOn)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    ListenBrainzPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "ListenBrainz", subtitle: listenbrainzLine,
                             leading: { GlyphMark(symbol: "waveform") }) {
                        StateValue(listenbrainzOn ? "Connected" : "Set up", done: listenbrainzOn)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    HearingPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "The wall's ears", subtitle: earsLine,
                             leading: { GlyphMark(symbol: "ear") }) {
                        StateValue(earsState, done: services?.hearing?.listening == true)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    ClaudePage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Claude", subtitle: claudeLine,
                             leading: { GlyphMark(symbol: "text.bubble") }) {
                        StateValue(services?.claude?.isReady == true ? "Connected" : "Set up",
                                   done: services?.claude?.isReady == true)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    DiscogsPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Discogs", subtitle: discogsLine,
                             leading: { GlyphMark(symbol: "opticaldisc") }) {
                        StateValue(discogsOn ? "Connected" : "Set up", done: discogsOn)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    PostersPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Posters", subtitle: postersLine,
                             leading: { GlyphMark(symbol: "tv") }) {
                        StateValue(services?.tmdb?.key_set == true ? "Connected" : "Set up",
                                   done: services?.tmdb?.key_set == true)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    ImagesPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Images", subtitle: imagesLine,
                             leading: { GlyphMark(symbol: "paintbrush") }) {
                        StateValue(services?.images?.ready == true ? "Connected" : "Set up",
                                   done: services?.images?.ready == true)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
                Rule()
                NavigationLink {
                    AirPlayPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "AirPlay", subtitle: airplayLine,
                             leading: { GlyphMark(symbol: "airplayaudio") }) {
                        StateValue(airplayState.text, done: airplayState.done)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
            }

            SetupGroup("Other players", note: otherNote) {
                otherRow(.tidal, "Reports through Last.fm. In Tidal: Settings, then Connect to Last.fm.")
                Rule()
                SetupRow(title: "Deezer", subtitle: "Reports through Last.fm once linked in Safari.",
                         leading: { ServiceMark(service: .deezer) }) {
                    ActionPill(title: "Link", filled: false) {
                        openURL(URL(string: "https://www.deezer.com/account/share")!)
                    }
                }
                Rule()
                otherRow(.soundcloud, "In a computer's browser with Web Scrobbler, from a Mac, or out loud.")
                Rule()
                otherRow(.youtubeMusic, "In a computer's browser with Web Scrobbler, from a Mac, or out loud.")
                Rule()
                otherRow(.amazonMusic, "In a computer's browser with Web Scrobbler, from a Mac, or out loud.")
            }

            SetupGroup("A Mac, if you use one", note: "Optional. A Mac running the reporter passes along whatever it plays: Spotify's app, TIDAL, a browser tab on YouTube Music.") {
                NavigationLink {
                    AddressesPage(accent: accent, onChange: {})
                } label: {
                    SetupRow(title: "Your Mac", subtitle: macLine,
                             leading: { GlyphMark(symbol: "desktopcomputer") }) {
                        Value("Addresses")
                    }
                }
                .buttonStyle(PressStyle(scale: 0.99))
            }
        }
        .task { services = await WallServices.seeded(host: wall.host) }
    }

    private var appleRow: some View {
        SetupRow(title: musicRefused ? "Apple Music is off in Settings" : "Apple Music",
                 subtitle: musicRefused ? "Allow it there and it comes back."
                                        : "What you play on this phone.",
                 leading: { ServiceMark(service: .appleMusic) }) {
            if musicRefused {
                ActionPill(title: "Open Settings") { Service.openSettings() }
            } else if musicConnected {
                Done(text: "Connected")
            } else {
                ActionPill(title: "Connect") {
                    StandIn.requestMusicAccess { [weak wall] in
                        wall?.push.restart()
                        musicConnected = Service.appleMusicAuthorized
                        musicRefused = Service.appleMusicRefused
                    }
                }
            }
        }
    }

    private func otherRow(_ svc: Service, _ line: String) -> some View {
        SetupRow(title: svc.name, subtitle: line, leading: { ServiceMark(service: svc) }) { EmptyView() }
    }

    // MARK: Words for the rows

    private var lastfmOn: Bool {
        guard let lf = services?.lastfm else { return false }
        return !lf.user.isEmpty && lf.key_set == true
    }
    private var listenbrainzOn: Bool { !(services?.listenbrainz?.user ?? "").isEmpty }
    private var airplayState: (text: String, done: Bool) {
        guard let a = services?.airplay else { return ("Set up", false) }
        switch a.state {
        case "playing": return ("Playing", true)
        case "paused": return ("Paused", true)
        default: return (a.running == true ? "Ready" : "Set up", a.running == true)
        }
    }
    private var airplayLine: String {
        guard let a = services?.airplay else { return "The wall as an AirPlay receiver called Wall." }
        if let from = a.connected_from, !from.isEmpty, a.state != "idle" {
            return "From \(from)" + (a.last.map { ": \($0)" } ?? "") + "."
        }
        if a.running == true { return "Ready. Pick Wall in the AirPlay menu." }
        return "The wall as an AirPlay receiver called Wall. Needs shairport-sync on the Pi."
    }
    private var imagesLine: String {
        guard let i = services?.images else { return "Say \"create a purple elephant\" and one appears." }
        if let p = i.problem, i.ready { return p }
        if i.ready {
            let n = i.images ?? 0
            let who = i.provider == "google" ? "Imagen" : "OpenAI"
            return n == 0 ? "\(who), ready. Say \"create a purple elephant\"." : "\(who). \(n) drawn so far."
        }
        return "Say \"create a purple elephant\" and one appears."
    }
    private var postersLine: String {
        guard let t = services?.tmdb else { return "What the Mac watches, as its poster on the wall." }
        if let p = t.problem, t.key_set { return p }
        if t.key_set {
            if let l = t.last { return "Last: \(l.title)" + (l.year.map { ", \($0)" } ?? "") + "." }
            return "Ready. Play an episode in a browser on the Mac."
        }
        return "What the Mac watches, as its poster on the wall."
    }
    private var discogsOn: Bool {
        guard let d = services?.discogs else { return false }
        return !d.user.isEmpty && d.token_set == true
    }
    private var discogsLine: String {
        guard let d = services?.discogs else { return "Your record shelf, so the wall knows what you own on vinyl." }
        if let p = d.problem, discogsOn { return p }
        if discogsOn {
            let n = d.releases ?? 0
            return n == 0 ? "Reading \(d.user)'s shelf." : "\(n) record\(n == 1 ? "" : "s") on \(d.user)'s shelf."
        }
        return "Your record shelf, so the wall knows what you own on vinyl."
    }

    private var wallNote: String {
        services == nil
            ? "The wall is not answering, so these cannot be set right now."
            : "Set up from this phone. The wall keeps the details."
    }

    private var spotifyReady: Bool {
        !DeveloperKeys.spotifyClientID.isEmpty || !(services?.spotify.client_id ?? "").isEmpty
    }
    private var spotifyLine: String {
        guard let sp = services?.spotify else { return "Any device." }
        if sp.linked { return "The wall follows this account on any device." }
        if spotifyReady { return "Sign in once. Free accounts go through Last.fm." }
        return "Any device. Set up in a couple of minutes."
    }
    private var spotifyState: String {
        guard let sp = services?.spotify else { return spotifyReady ? "Sign in" : "Set up" }
        return sp.linked ? "Connected" : (spotifyReady ? "Sign in" : "Set up")
    }

    private var claudeLine: String {
        guard let c = services?.claude else { return "Ask the wall anything; the answer is drawn on the panel." }
        if let p = c.problem, c.isReady { return p }
        if c.isReady { return "Ask the wall, by voice or Siri. \(c.answers ?? 0) answered." }
        return "Ask the wall anything; the answer is drawn on the panel."
    }

    private var lastfmLine: String {
        lastfmOn ? "Following \(services!.lastfm.user)."
                 : "Spotify, Tidal and Deezer report through it."
    }
    private var listenbrainzLine: String {
        guard listenbrainzOn, let lb = services?.listenbrainz else {
            return "The open ledger. Username only, no key."
        }
        return lb.valid == true ? "Following \(lb.user). The ear's records are written there."
                                : "Following \(lb.user)."
    }

    private var earsLine: String {
        guard let h = services?.hearing else { return "Anything played out loud in the room, named by Shazam." }
        if let heard = h.heard { return "Hearing \(heard.artist), \(heard.title)." }
        if !h.on { return "Off. Anything played out loud in the room, when on." }
        if h.listening { return h.gate_open ? "Listening to the room." : "Listening. The room is quiet." }
        if h.mic == nil { return "Waiting for a microphone on the wall." }
        return "Anything played out loud in the room."
    }
    private var earsState: String {
        guard let h = services?.hearing else { return "Set up" }
        if h.heard != nil { return "Heard" }
        if !h.on { return "Off" }
        return h.listening ? "Listening" : (h.mic == nil ? "No mic" : "Waiting")
    }

    private var otherNote: String {
        "SoundCloud, YouTube Music and Amazon Music have no way to tell any phone app what they play. In a computer's browser, the free Web Scrobbler extension reports them to Last.fm or ListenBrainz, and the wall reads those. On a Mac running the reporter the wall reads them directly; out loud, the wall's ears pick them up."
    }

    private var macLine: String {
        guard let m = services?.mac, !m.endpoint.isEmpty else { return "Not set." }
        switch m.answering {
        case true: return "Answering at \(m.endpoint)."
        case false: return "Not answering at \(m.endpoint)."
        default: return m.endpoint
        }
    }
}

// MARK: - Spotify

struct SpotifyPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var clientID = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var copied: String?
    @State private var spotify = SpotifyLink()

    private static let redirects = ["tessera://spotify", "http://127.0.0.1:8888/callback"]

    private var linked: Bool { services?.spotify.linked == true }
    private var baked: Bool { !DeveloperKeys.spotifyClientID.isEmpty }
    private var lastfmOn: Bool {
        guard let lf = services?.lastfm else { return false }
        return !lf.user.isEmpty && lf.key_set == true
    }
    private var savedID: String { services?.spotify.client_id ?? "" }
    private var typedID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var blurb: String {
        baked ? "The wall follows what this account plays, on any device: phone, laptop, speaker. Sign in once."
              : "The wall follows what this account plays, on any device. It needs an app id of your own: Spotify's word for a key that says which app is asking. Made once, in Safari, on this phone."
    }

    var body: some View {
        SetupPage("Spotify", blurb: blurb) {
            if linked {
                SetupGroup("Connected", note: "Disconnect forgets the account on the wall. The app id stays, so signing in again is one tap.") {
                    SetupRow(title: "Any device", subtitle: "Phone, laptop, speaker: the wall follows this account.",
                             leading: { ServiceMark(service: .spotify) }) {
                        ActionPill(title: busy ? "One moment" : "Disconnect", filled: false) { unlink() }
                            .disabled(busy)
                    }
                }
                .padding(.top, -12)
            } else if baked {
                SetupGroup("Premium accounts", note: "Once. Spotify asks which account; the wall gets the keys and follows it from then on. Spotify allows this route only for Premium accounts.") {
                    SetupRow(title: "Sign in to Spotify",
                             subtitle: spotify.problem ?? (services == nil ? "The wall is not answering right now." : "Any device this account plays on."),
                             leading: { ServiceMark(service: .spotify) }) {
                        ActionPill(title: spotify.busy ? "Signing in" : "Sign in") { signIn() }
                            .disabled(spotify.busy || services == nil)
                    }
                }
                .padding(.top, -12)
                Problem(text: problem)

                SetupGroup("Free accounts", note: "Spotify refuses its own API to free accounts, but it reports to Last.fm on any plan, and the wall reads Last.fm within seconds. Two steps, both free.") {
                    SetupRow(title: "Link Spotify on last.fm", subtitle: "Settings, then Applications, then Connect.",
                             leading: { ServiceMark(service: .lastfm) }) {
                        ActionPill(title: "Link", filled: false) {
                            openURL(URL(string: "https://www.last.fm/settings/applications")!)
                        }
                    }
                    Rule()
                    NavigationLink {
                        LastfmPage(accent: accent, services: $services)
                    } label: {
                        SetupRow(title: "Tell the wall your Last.fm name",
                                 subtitle: lastfmOn ? "Done. Following \(services!.lastfm.user)." : "One field.",
                                 leading: { GlyphMark(symbol: "person") }) {
                            StateValue(lastfmOn ? "Connected" : "Set up", done: lastfmOn)
                        }
                    }
                    .buttonStyle(PressStyle(scale: 0.99))
                }
            } else {
                SetupGroup("1. Make the app id", note: "Free, about two minutes, and it needs Spotify Premium. Spotify allows one app id per account and five listeners on it, which is plenty for a wall. Name it anything.") {
                    SetupRow(title: "Spotify for Developers", subtitle: "Opens in Safari. Sign in, then Create app.") {
                        ActionPill(title: "Open") {
                            openURL(URL(string: "https://developer.spotify.com/dashboard")!)
                        }
                    }
                }
                .padding(.top, -12)

                SetupGroup("2. Give it these two addresses", note: "Under Redirect URIs, add both, exactly as written. Copy one, paste it into the form, come back for the other.") {
                    ForEach(Self.redirects, id: \.self) { uri in
                        HStack(spacing: 12) {
                            Text(uri)
                                .font(.machine(13))
                                .foregroundStyle(Ink.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer()
                            if copied == uri {
                                Done(text: "Copied")
                            } else {
                                ActionPill(title: "Copy", filled: false) { copy(uri) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        if uri != Self.redirects.last { Rule() }
                    }
                }

                SetupGroup("3. Paste the Client ID", note: "It is on the app's settings page. Not the client secret: the wall never needs that, and should never have it.") {
                    KeyField(placeholder: "Client ID", text: $clientID)
                    Rule()
                    SaveLine(title: "Save to the wall",
                             enabled: !typedID.isEmpty && typedID != savedID && services != nil,
                             busy: busy,
                             done: (!savedID.isEmpty && typedID == savedID) ? "On the wall" : nil,
                             accent: accent) { save() }
                }

                if !savedID.isEmpty {
                    SetupGroup("4. Sign in", note: "Once. Spotify asks which account; the wall gets the keys and follows it from then on.") {
                        SetupRow(title: "Sign in to Spotify", subtitle: spotify.problem ?? "Any device this account plays on.",
                                 leading: { ServiceMark(service: .spotify) }) {
                            ActionPill(title: spotify.busy ? "Signing in" : "Sign in") { signIn() }
                                .disabled(spotify.busy)
                        }
                    }
                }

                Problem(text: problem)
                Text("No Premium? Link Spotify to Last.fm instead; that route needs no app id.")
                    .font(.ui(12)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { clientID = savedID }
        .onChange(of: savedID) { _, fresh in if clientID.isEmpty { clientID = fresh } }
    }

    private func copy(_ uri: String) {
        UIPasteboard.general.string = uri
        copied = uri
        Taps.detent(intensity: 0.4)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == uri { copied = nil }
        }
    }

    private func save() {
        let id = typedID
        guard !id.isEmpty, !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["spotify": ["client_id": id]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit() }
            busy = false
        }
    }

    private func signIn() {
        Task {
            // A baked-in id reaches the wall on its own; make sure before the
            // tokens go over, since the wall refreshes them with that id.
            if baked, savedID != DeveloperKeys.spotifyClientID {
                services = await WallServices.seeded(host: wall.host)
            }
            let id = baked ? DeveloperKeys.spotifyClientID : savedID
            guard !id.isEmpty else { problem = "The wall is not answering right now."; return }
            if await spotify.connect(clientID: id, wall: wall.host) {
                services = await WallServices.read(host: wall.host)
                Taps.commit()
            }
        }
    }

    private func unlink() {
        busy = true
        Task {
            if let fresh = await WallServices.unlinkSpotify(host: wall.host) {
                services = fresh
                Taps.commit()
            } else {
                problem = "The wall is not answering right now."
            }
            busy = false
        }
    }
}

// MARK: - Last.fm

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
    @State private var syncing = false
    @State private var problem: String?
    @State private var shelf: ShelfList?

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
    private var shelfState: (text: String, done: Bool) {
        guard let dg else { return ("Set up", false) }
        if dg.token_set != true || dg.user.isEmpty { return ("Needs your token", false) }
        if let p = dg.problem { return (p, false) }
        if dg.syncing == true || syncing { return ("Reading", false) }
        let n = dg.releases ?? 0
        return (n == 0 ? "Empty" : "\(n) record\(n == 1 ? "" : "s")", n > 0)
    }
    private var shelfNote: String {
        guard let at = dg?.synced_at else { return "Nothing read yet." }
        return "Read \(ago(Int(at))). Read again every six hours, and whenever you change the details above."
    }
    private var releases: [ShelfList.Release] {
        (shelf?.releases ?? []).sorted { a, b in
            if a.plays != b.plays { return a.plays > b.plays }
            return (a.added ?? "") > (b.added ?? "")
        }
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

            SetupGroup("The shelf", note: shelfNote) {
                SetupRow(title: "Records the wall knows", subtitle: "Every release in your main collection folder.") {
                    HStack(spacing: 10) {
                        StateValue(shelfState.text, done: shelfState.done)
                        if tokenSet && !savedUser.isEmpty {
                            ActionPill(title: syncing ? "Reading" : "Read again", filled: false) { sync() }
                        }
                    }
                }
                ForEach(releases, id: \.release_id) { r in
                    Rule()
                    releaseRow(r)
                }
            }

            SetupGroup("On the wall", note: "The Shelf knob under Tuning turns the corner mark off. The pressing shows in the app under the song whenever a shelf album is on, from any source.") {
                EmptyView()
            }
        }
        .onAppear { user = savedUser }
        .onChange(of: savedUser) { _, fresh in if user.isEmpty { user = fresh } }
        .task {
            if let list = await ShelfList.read(host: wall.host) { shelf = list }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
                if syncing || shelf == nil || (shelf?.releases.count ?? 0) != (services?.discogs?.releases ?? 0) {
                    if let list = await ShelfList.read(host: wall.host) { shelf = list }
                }
                if syncing, services?.discogs?.syncing != true { syncing = false }
            }
        }
    }

    private func releaseRow(_ r: ShelfList.Release) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.ui(15)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(pressingLine(r)).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(r.plays == 0 ? "" : r.plays == 1 ? "played once" : "played \(r.plays)x")
                .font(.machine(10)).foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if let u = URL(string: r.url) { openURL(u) } }
    }

    private func pressingLine(_ r: ShelfList.Release) -> String {
        var bits: [String] = [r.artists.joined(separator: ", ")]
        if let y = r.year, y > 0 { bits.append(String(y)) }
        let lab = [r.label, r.catno].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if !lab.isEmpty { bits.append(lab) }
        if let f = r.formats?.first, f != "Vinyl" { bits.append(f) }
        return bits.joined(separator: "  ·  ")
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
            let (fresh, why) = await ServiceSave.send(["discogs": patch], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit(); token = ""; syncing = true }
            busy = false
        }
    }

    private func sync() {
        guard !syncing else { return }
        syncing = true
        let h = wall.host
        Task {
            _ = await ShelfList.sync(host: h)
            Taps.commit()
        }
    }
}


/// The shelf as GET /shelf describes it: every release, with how often it
/// has played on the wall.
struct ShelfList: Decodable {
    struct Release: Decodable {
        var release_id: Int
        var title: String
        var artists: [String]
        var year: Int?
        var label: String?
        var catno: String?
        var formats: [String]?
        var cover: String?
        var country: String?
        var url: String
        var plays: Int
        var added: String?
    }
    var releases: [Release]

    static func read(host: String) async -> ShelfList? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/shelf") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ShelfList.self, from: data)
    }

    static func sync(host: String) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/shelf/sync") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
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
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    private var ap: WallServices.Airplay? { services?.airplay }

    private var stateLine: (String, Bool) {
        guard let ap else { return ("The wall is not answering.", false) }
        if ap.running != true { return ("shairport-sync is not running on the Pi.", false) }
        switch ap.state {
        case "playing": return ("Playing" + (ap.last.map { ": \($0)" } ?? ""), true)
        case "paused": return ("Paused" + (ap.last.map { ": \($0)" } ?? ""), true)
        default: return ("Ready. Nothing coming in.", true)
        }
    }

    var body: some View {
        SetupPage("AirPlay",
                  blurb: "The wall is an AirPlay receiver called Wall. Pick it in the AirPlay menu on this phone, a Mac or an Apple TV, alone or in a group with a speaker, and the wall is handed the exact title, artwork and position of whatever plays. No account and no key. The wall does not have to make a sound.") {
            SetupGroup("Coming in", note: nil) {
                SetupRow(title: "State", subtitle: stateLine.0) {
                    StateValue(stateLine.1 ? "On" : "Off", done: stateLine.1)
                }
                if let from = ap?.connected_from, !from.isEmpty {
                    Rule()
                    SetupRow(title: "From", subtitle: from + (ap?.user_agent.map { " (\($0))" } ?? "")) { EmptyView() }
                }
                if let e = ap?.error, ap?.running != true {
                    Rule()
                    SetupRow(title: "The wall says", subtitle: e) { EmptyView() }
                }
            }
            .padding(.top, -12)

            SetupGroup("On the Pi", note: "shairport-sync does the receiving; the wall reads what it writes. Installing it takes sudo, so it is done at the Pi, following docs/AIRPLAY.md in the project.") {
                SetupRow(title: "shairport-sync", subtitle: ap?.running == true ? "Running." : "Not running.") {
                    StateValue(ap?.running == true ? "Installed" : "Not yet", done: ap?.running == true)
                }
                Rule()
                SetupRow(title: "The metadata pipe", subtitle: ap?.pipe_exists == true
                         ? (ap?.reading == true ? "Open, the wall is reading it." : "There. The wall opens it when a stream begins.")
                         : "Not there yet.") {
                    StateValue(ap?.pipe_exists == true ? "There" : "Not yet", done: ap?.pipe_exists == true)
                }
                Rule()
                SetupRow(title: "The guide", subtitle: "docs/AIRPLAY.md on GitHub. Opens in Safari.") {
                    ActionPill(title: "Open", filled: false) {
                        openURL(URL(string: "https://github.com/jke48222/album-art-matrix/blob/main/docs/AIRPLAY.md")!)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                if let fresh = await WallServices.read(host: wall.host) { services = fresh }
            }
        }
    }
}
