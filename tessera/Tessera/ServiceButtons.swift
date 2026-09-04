// The services, wearing their own marks.
//
// Apple Music's mark is Apple's own, lifted from the badge Apple's badge
// service hands out. The rest are the services' published glyphs, each on a
// tile in the colour the service uses for itself. None is redrawn or
// reproportioned: a brand mark you have improved is a brand mark you have
// broken.

import MediaPlayer
import SwiftUI
import UIKit

enum Service: CaseIterable {
    case appleMusic, spotify, lastfm, tidal, deezer, soundcloud, youtubeMusic, amazonMusic

    var name: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .lastfm: "Last.fm"
        case .tidal: "Tidal"
        case .deezer: "Deezer"
        case .soundcloud: "SoundCloud"
        case .youtubeMusic: "YouTube Music"
        case .amazonMusic: "Amazon Music"
        }
    }

    var asset: String {
        switch self {
        case .appleMusic: "AppleMusicMark"
        case .spotify: "SpotifyMark"
        case .lastfm: "LastfmMark"
        case .tidal: "TidalMark"
        case .deezer: "DeezerMark"
        case .soundcloud: "SoundCloudMark"
        case .youtubeMusic: "YouTubeMusicMark"
        case .amazonMusic: "AmazonMusicMark"
        }
    }

    static var appleMusicAuthorized: Bool {
        MPMediaLibrary.authorizationStatus() == .authorized
    }
    static var appleMusicRefused: Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .denied, .restricted: true
        default: false
        }
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// A service's mark at row size. One footprint for all, so the rows line up.
struct ServiceMark: View {
    let service: Service
    var side: CGFloat = 32

    var body: some View {
        Image(service.asset)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A mark for a service with no published glyph worth borrowing: a plain tile
/// in the same footprint, carrying a symbol, so the rows still line up.
struct GlyphMark: View {
    let symbol: String
    var side: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(Ink.dim.opacity(0.18))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.48, weight: .semibold))
                    .foregroundStyle(Ink.ink)
            }
            .accessibilityHidden(true)
    }
}

/// The small trailing pill a row uses to ask for one thing. Filled when it is
/// the thing to do next, outlined when it undoes something already done.
struct ActionPill: View {
    let title: String
    var filled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(13, .semibold))
                .foregroundStyle(filled ? Ink.ground : Ink.ink)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    Capsule().fill(filled ? Ink.ink : Color.clear)
                }
                .overlay {
                    Capsule().strokeBorder(filled ? .clear : Ink.hairline, lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }
}
