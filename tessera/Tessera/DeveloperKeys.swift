// The developer's own keys, baked in once, so a person only ever signs in.
//
// Only what is safe to publish belongs in this file. This repository is
// public, so anything here is readable by anyone, forever.
//
// The Spotify app id is safe: every app with a "Sign in with Spotify" button
// was registered once by its developer, and the id that came back is public
// by design, because the sign-in uses PKCE and there is no secret to keep.
//
// A Last.fm API key is NOT the same thing, whatever this comment used to
// say. It is a credential bound to the developer's Last.fm account, sent in
// the clear by clients but not meant to be published: a copied key burns the
// owner's rate limit and can get it revoked for someone else's abuse. So it
// is empty here. Make one at https://www.last.fm/api/accounts and type it
// into Tessera's Services page, which keeps it in services.json on the wall
// and never in the repository.
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
    static let lastfmAPIKey = ""

    // A wall with no account of its own can be handed one here, so setting it
    // up takes no typing. Empty in the repository, which is public: an account
    // name is not a secret but it is nobody else's business either. Fill them
    // in for a local build, or type them into the Services pages once.
    static let lastfmUser = ""
    static let listenbrainzUser = ""

    static var any: Bool {
        !(spotifyClientID.isEmpty && lastfmAPIKey.isEmpty
          && lastfmUser.isEmpty && listenbrainzUser.isEmpty)
    }
}
