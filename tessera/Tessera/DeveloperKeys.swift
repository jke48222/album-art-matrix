// The developer's own keys, baked in once, so a person only ever signs in.
//
// Every app with a "Sign in with Spotify" button was registered with Spotify
// once by its developer; the app id that came back is public by design (the
// sign-in uses PKCE, so there is no secret to keep). Last.fm and AcoustID
// hand out per-app keys the same way. They are pasted here once, and the app
// hands them to any wall it meets that is missing them (WallServices.seeded).
//
// Empty means "not made yet": the Services pages then walk through making
// them by hand, so nothing breaks while the keys do not exist.
//
// Spotify Development Mode, February 2026 rules: the developer's account
// must be Premium, one app id per account, and every account that signs in
// must be on the app's user list in the dashboard (five at most). The
// developer's own account is on it by default.

enum DeveloperKeys {
    static let spotifyClientID = "9d6085a739ed432d9f5da56c598cf39b"
    static let lastfmAPIKey = "65b7c071aeddf5b282ff47e07807035b"
    static let acoustidAPIKey = "g5uJUFuFdP"

    // The owner's own accounts, handed to a wall that has none, so setting
    // up a fresh wall takes no typing at all. Not developer keys: clear them
    // for a build meant for someone else. Either can still be changed on
    // the wall from the Services pages.
    static let lastfmUser = "youfoundjalen"
    static let listenbrainzUser = "youfoundjalen"

    static var any: Bool {
        !(spotifyClientID.isEmpty && lastfmAPIKey.isEmpty && acoustidAPIKey.isEmpty
          && lastfmUser.isEmpty && listenbrainzUser.isEmpty)
    }
}
