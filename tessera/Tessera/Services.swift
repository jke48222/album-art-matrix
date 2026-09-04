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
    struct Listenbrainz: Decodable { var user: String }
    struct Acoustid: Decodable {
        var key_set: Bool
        var device: String
        var mic: String?
        var tools: Bool
        var listening: Bool
        var heard_s: Int?
        var problem: String?
    }
    struct Mac: Decodable { var endpoint: String; var answering: Bool? }

    var spotify: Spotify
    var lastfm: Lastfm
    var listenbrainz: Listenbrainz?      // older walls do not send these
    var acoustid: Acoustid?
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
        if !DeveloperKeys.acoustidAPIKey.isEmpty, current.acoustid?.key_set != true {
            patch["acoustid"] = ["api_key": DeveloperKeys.acoustidAPIKey, "device": "auto"]
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
                    EarsPage(accent: accent, services: $services)
                } label: {
                    SetupRow(title: "The wall's ears", subtitle: earsLine,
                             leading: { GlyphMark(symbol: "ear") }) {
                        StateValue(earsState, done: services?.acoustid?.listening == true)
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
                otherRow(.soundcloud, "From a Mac, or out loud.")
                Rule()
                otherRow(.youtubeMusic, "From a Mac, or out loud.")
                Rule()
                otherRow(.amazonMusic, "From a Mac, or out loud.")
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
        guard let a = services?.acoustid else { return "Anything played out loud in the room." }
        if a.listening { return "Listening. Anything played out loud in the room." }
        if a.key_set && a.mic == nil { return "Key saved. Waiting for a microphone on the wall." }
        return "Anything played out loud. Needs a free key and a microphone."
    }
    private var earsState: String {
        guard let a = services?.acoustid else { return "Set up" }
        return a.listening ? "Listening" : (a.key_set ? "Waiting" : "Set up")
    }

    private var otherNote: String {
        "SoundCloud, YouTube Music and Amazon Music do not tell any phone app what they play. On a Mac running the reporter the wall reads them; out loud, the wall's ears pick them up."
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
    @State private var busy = false
    @State private var problem: String?

    private var savedUser: String { services?.listenbrainz?.user ?? "" }
    private var typedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SetupPage("ListenBrainz",
                  blurb: "The open version of Last.fm, run by the MusicBrainz people. Free, and the wall needs only your username: reading what you play needs no key at all.") {
            SetupGroup("Your account", note: "An account takes a minute. Then every scrobbler that can post there (Web Scrobbler in a computer's browser, Pano Scrobbler on Android) reaches the wall.") {
                KeyField(placeholder: "Username", text: $user)
                Rule()
                SetupRow(title: "No account yet?", subtitle: "Opens listenbrainz.org in Safari.") {
                    ActionPill(title: "Make one", filled: false) {
                        openURL(URL(string: "https://listenbrainz.org/")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall",
                         enabled: services != nil && !typedUser.isEmpty && typedUser != savedUser,
                         busy: busy,
                         done: (!savedUser.isEmpty && typedUser == savedUser) ? "Following \(savedUser)" : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem)
        }
        .onAppear { user = savedUser }
        .onChange(of: savedUser) { _, fresh in if user.isEmpty { user = fresh } }
    }

    private func save() {
        guard !typedUser.isEmpty, !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["listenbrainz": ["user": typedUser]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { Taps.commit() }
            busy = false
        }
    }
}

// MARK: - The wall's ears (AcoustID)

struct EarsPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.openURL) private var openURL
    let accent: Color
    @Binding var services: WallServices?

    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?

    private var ears: WallServices.Acoustid? { services?.acoustid }
    private var keyBaked: Bool { !DeveloperKeys.acoustidAPIKey.isEmpty }
    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var blurb: String {
        "For anything played out loud in the room, from any app or any speaker: the wall listens for a few seconds, then asks AcoustID what it heard. "
            + (keyBaked ? "Needs only a USB microphone on the wall." : "Needs a free key and a USB microphone on the wall.")
    }

    var body: some View {
        SetupPage("The wall's ears", blurb: blurb) {
            if !keyBaked {
            SetupGroup("Key", note: "AcoustID keys come with a MusicBrainz account. Sign in, register an application (any name), copy its API key.") {
                KeyField(placeholder: ears?.key_set == true ? "API key (one is on the wall)" : "API key", text: $key)
                Rule()
                SetupRow(title: "Need a key?", subtitle: "Opens acoustid.org in Safari.") {
                    ActionPill(title: "Get a key", filled: false) {
                        openURL(URL(string: "https://acoustid.org/new-application")!)
                    }
                }
                Rule()
                SaveLine(title: "Save to the wall",
                         enabled: services != nil && !typedKey.isEmpty,
                         busy: busy,
                         done: (ears?.key_set == true && typedKey.isEmpty) ? "Key on the wall" : nil,
                         accent: accent) { save() }
            }
            .padding(.top, -12)
            Problem(text: problem)
            }

            SetupGroup("On the wall", note: keyBaked ? "The key is built in. Plug a USB microphone into the wall and it is picked up on its own."
                                                     : "Plug a USB microphone into the wall and it is picked up on its own.") {
                fact("Microphone", ears?.mic ?? "None found yet", warn: ears?.mic == nil)
                Rule()
                fact("Listening tools", ears?.tools == true ? "Ready" : "Missing on the wall", warn: ears?.tools != true)
                Rule()
                fact("Listening", listeningWords, warn: ears?.listening != true)
                if let p = ears?.problem, !p.isEmpty {
                    Rule()
                    fact("Last problem", p, warn: true)
                }
                Rule()
                HStack {
                    Button("Check again") {
                        Task { services = await WallServices.read(host: wall.host) }
                    }
                    .buttonStyle(PressStyle(scale: 0.97))
                    .font(.ui(13, .medium))
                    .foregroundStyle(accent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .task { if keyBaked, ears?.key_set != true { services = await WallServices.seeded(host: wall.host) } }
    }

    private var listeningWords: String {
        guard let e = ears else { return "The wall is not answering." }
        if e.listening {
            if let s = e.heard_s { return s < 120 ? "Yes. Heard a song \(s) s ago." : "Yes. Nothing heard for a while." }
            return "Yes"
        }
        if !e.key_set { return "No. Needs the key first." }
        return "No"
    }

    private func fact(_ name: String, _ value: String, warn: Bool = false) -> some View {
        SetupRow(title: name, subtitle: nil) {
            Text(value).font(.ui(14)).foregroundStyle(warn ? Ink.signal : Ink.dim)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        guard !typedKey.isEmpty, !busy else { return }
        busy = true
        Task {
            let (fresh, why) = await ServiceSave.send(["acoustid": ["api_key": typedKey, "device": "auto"]], to: wall.host)
            if let fresh { services = fresh }
            problem = why
            if why == nil { key = ""; Taps.commit() }
            busy = false
        }
    }
}
