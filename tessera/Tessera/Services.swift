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
    struct Claude: Decodable { var key_set: Bool; var model: String; var busy: Bool; var problem: String?; var last_cost_usd: Double? }
    var claude: Claude?
    struct Spotify: Decodable { var client_id: String; var linked: Bool }
    struct Lastfm: Decodable { var user: String; var key_set: Bool? }
    struct Listenbrainz: Decodable {
        struct Listen: Decodable { var title: String; var artist: String; var at: Double }
        var user: String
        var token_set: Bool?
        var enabled: Bool?
        var last_listen: Listen?
        var queued: Int?
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
    }
    struct Mac: Decodable { var endpoint: String; var answering: Bool? }

    var spotify: Spotify
    var lastfm: Lastfm
    var listenbrainz: Listenbrainz?      // older walls do not send these
    struct Voice: Decodable {
        var enabled: Bool
        var state: String
        var wake_word: String
        var custom_available: Bool
        var problem: String?
        var last_transcribe_ms: Int?
    }
    struct AirPlay: Decodable {
        var name: String
        var running: Bool
        var enabled: Bool
        var connected_from: String?
        var last: Int?
        var problem: String?
        var output: String
    }
    var airplay: AirPlay?
    var voice: Voice?
    var hearing: Hearing?
    var mac: Mac?
    var ears: Bool
    var rejected: [String]?              // field names the wall would not take

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

            SetupGroup("Your records", note: "Keep the wall in touch with the physical collection.") {
                NavigationLink { ShelfPage(accent: accent) } label: {
                    SetupRow(title: "Discogs shelf", subtitle: "Collection, pressings and plays") {
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.faint)
                    }
                }
            }

            SetupGroup("AirPlay", note: "Choose Wall in the AirPlay picker. The wall receives the sleeve silently. You can add speakers to the same group later.") {
                SetupRow(title: "Wall", subtitle: services?.airplay?.connected_from ?? "Waiting for a device") {
                    StateValue(services?.airplay?.running == true ? "Ready" : "Off", done: services?.airplay?.running == true)
                }
                Problem(text: services?.airplay?.problem)
            }

            SetupGroup("Ask the wall", note: "Short answers, shown on the panel or spoken by a Siri Shortcut.") {
                NavigationLink {
                    ClaudePage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "Claude", subtitle: "A key for questions and the wall's tools.") {
                        StateValue(services?.claude?.key_set == true ? "Connected" : "Set up", done: services?.claude?.key_set == true)
                    }
                }
            }

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

    private var lastfmLine: String {
        lastfmOn ? "Following \(services!.lastfm.user)."
                 : "Spotify, Tidal and Deezer report through it."
    }
    private var listenbrainzLine: String {
        listenbrainzOn ? "Following \(services!.listenbrainz!.user)."
                       : "The open ledger. Username only, no key."
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
    @State private var offline = false
    private var savedUser: String { services?.listenbrainz?.user ?? "" }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tokenSet: Bool { services?.listenbrainz?.token_set == true }

    var body: some View {
        SetupPage("ListenBrainz",
                  blurb: "Read what you stream with your username. Add a user token to keep the records the wall hears in your listening history.") {
            SetupGroup("Your account", note: "Your token stays on the wall. Any phone can see whether it is set, but cannot read it back.") {
                KeyField(placeholder: "Username", text: $user)
                Rule()
                SecureField(tokenSet ? "User token is set" : "User token", text: $token)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 14)
                Rule()
                SetupRow(title: "Your user token", subtitle: "Copy it from your ListenBrainz settings.") {
                    ActionPill(title: "Open", filled: false) {
                        openURL(URL(string: "https://listenbrainz.org/settings/")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall",
                         enabled: services != nil && (typedUser != savedUser || !token.isEmpty),
                         busy: busy, done: tokenSet ? "Token saved" : nil,
                         accent: accent) { save(clearToken: false) }
                if tokenSet {
                    Rule()
                    SetupRow(title: "Stop reporting records", subtitle: "Remove the token. Queued listens stay on the wall.") {
                        ActionPill(title: "Remove", filled: false) { save(clearToken: true) }
                            .disabled(busy)
                    }
                }
            }
            .padding(.top, -12)
            SetupGroup("Records heard", note: "Half a song or four minutes earns a listen. Offline listens wait up to seven days.") {
                if let lb = services?.listenbrainz {
                    SetupRow(title: "Vinyl scrobbling",
                             subtitle: lb.enabled == true ? (tokenSet ? "Listening for records." : "Add your user token to begin.") : "Off for this build. Enable scrobble on the wall.") { EmptyView() }
                    Rule()
                    if let last = lb.last_listen {
                        SetupRow(title: last.title, subtitle: last.artist) {
                            Text(Date(timeIntervalSince1970: last.at), style: .relative)
                                .font(.caption)
                        }
                    } else {
                        SetupRow(title: "No listens yet", subtitle: "The next record heard long enough will appear here.") { EmptyView() }
                    }
                    Rule()
                    SetupRow(title: "Waiting to send", subtitle: "\(lb.queued ?? 0) listens") { EmptyView() }
                    Problem(text: lb.problem)
                } else {
                    SetupRow(title: "Connecting to the wall", subtitle: "Listening history will appear when the wall answers.") { EmptyView() }
                }
            }
            Problem(text: offline ? "The wall is offline. Showing its last known state." : problem)
        }
        .onAppear { user = savedUser }
        .task {
            while !Task.isCancelled {
                if let fresh = await WallServices.read(host: wall.host) {
                    services = fresh
                    offline = false
                } else { offline = true }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func save(clearToken: Bool) {
        guard !busy else { return }
        busy = true
        var values = ["user": typedUser]
        if clearToken { values["token"] = "" }
        else if !token.isEmpty { values["token"] = token.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task {
            let (fresh, why) = await ServiceSave.send(["listenbrainz": values], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { token = ""; Taps.commit() }
            busy = false
        }
    }
}

struct ClaudePage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?
    @State private var key = ""
    @State private var question = ""
    @State private var answer = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        SetupPage("Claude", blurb: "Ask a short question. Claude can read what is playing and your recent records, and change the wall when you ask.") {
            SetupGroup("API key", note: "Kept only on the wall. Questions go to Anthropic when you ask; no conversation history is kept here.") {
                SecureField(services?.claude?.key_set == true ? "API key is set" : "Claude API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
                Rule()
                SetupRow(title: "Get a key", subtitle: "Opens the Anthropic console.") {
                    ActionPill(title: "Open", filled: false) { openURL(URL(string: "https://console.anthropic.com/settings/keys")!) }
                }
                SaveLine(title: "Save to the wall", enabled: !key.isEmpty && services != nil,
                         busy: busy, done: services?.claude?.key_set == true ? "Key saved" : nil,
                         accent: accent) { saveKey(clear: false) }
                if services?.claude?.key_set == true {
                    SetupRow(title: "Disconnect Claude", subtitle: "Remove the key from this wall.") {
                        ActionPill(title: "Remove", filled: false) { saveKey(clear: true) }.disabled(busy)
                    }
                }
            }
            .padding(.top, -12)
            SetupGroup("Try a question", note: "Enable Ask in this build's wall config. The previous face returns after the answer finishes.") {
                KeyField(placeholder: "What is playing?", text: $question)
                SaveLine(title: "Ask the wall", enabled: !question.trimmingCharacters(in: .whitespaces).isEmpty,
                         busy: busy, done: nil, accent: accent) { ask() }
                if !answer.isEmpty { Text(answer).font(.ui(15)).padding(16) }
                Problem(text: problem ?? services?.claude?.problem)
            }
        }
    }

    private func saveKey(clear: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["claude": ["api_key": clear ? "" : key]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { key = ""; Taps.commit() }
            busy = false
        }
    }

    private func ask() {
        guard !busy, let url = URL(string: "http://\(wall.host)/ask") else { return }
        busy = true
        Task {
            defer { busy = false }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 7
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": question, "reply": "wall"])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = value["answer"] as? String else { throw URLError(.badServerResponse) }
                answer = text
                problem = nil
            } catch { problem = "The wall could not answer. Check the connection and try again." }
        }
    }
}
