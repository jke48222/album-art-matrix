import Foundation

/// Every settings entry resolves to its existing feature destination. Search
/// indexes those routes, so a result never creates a second set of controls.
enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case light, time, sun, sleep, wake, idle, services, voice, hearing, shelf, teach
    case ask, note, show, earworm, imagine, weather, games
    case design, lockScreen, widgets, homeKit, guests, colour, panel, health, addresses, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .time: "Time & alarms"
        case .sun: "Follow the sun"
        case .sleep: "Sleep"
        case .wake: "Wake up"
        case .idle: "Between songs"
        case .services: "Services"
        case .voice: "Voice"
        case .hearing: "Hearing & gestures"
        case .shelf: "The shelf"
        case .teach: "Song library"
        case .ask: "Ask the wall"
        case .note: "Notes"
        case .show: "Show me"
        case .earworm: "Earworm"
        case .imagine: "Imagine"
        case .weather: "Weather"
        case .games: "Games"
        case .design: "App design"
        case .lockScreen: "Lock Screen"
        case .widgets: "Home Screen"
        case .homeKit: "HomeKit"
        case .guests: "Guests"
        case .colour: "True colour"
        case .panel: "Panel check"
        case .health: "Wall health"
        case .addresses: "Connection"
        case .about: "About Tessera"
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .time: "clock"
        case .sun: "sunset"
        case .sleep: "moon.zzz"
        case .wake: "sunrise"
        case .idle: "pause.circle"
        case .services: "music.note"
        case .voice: "waveform"
        case .hearing: "ear.badge.waveform"
        case .shelf: "opticaldisc"
        case .teach: "music.mic"
        case .ask: "text.bubble"
        case .note: "note.text"
        case .show: "photo.on.rectangle"
        case .earworm: "ear.badge.waveform"
        case .imagine: "paintbrush.pointed"
        case .weather: "cloud.sun"
        case .games: "dice"
        case .design: "iphone"
        case .lockScreen: "lock.iphone"
        case .widgets: "apps.iphone"
        case .homeKit: "homekit"
        case .guests: "qrcode"
        case .colour: "camera.aperture"
        case .panel: "checkerboard.rectangle"
        case .health: "waveform.path.ecg"
        case .addresses: "network"
        case .about: "info.circle"
        }
    }

    var section: SettingsSection {
        switch self {
        case .light, .time, .sun, .sleep, .wake, .idle: .rhythm
        case .services, .voice, .hearing, .shelf, .teach: .music
        case .ask, .note, .show, .earworm, .imagine, .weather, .games: .explore
        case .design, .lockScreen, .widgets, .homeKit, .guests: .home
        case .colour, .panel, .health, .addresses, .about: .care
        }
    }

    var detail: String {
        switch self {
        case .light: "Wall brightness"
        case .time: "Clock, timer and daily alarm"
        case .sun: "Dim after sunset, brighten at sunrise"
        case .sleep: "Fade to off on a timer"
        case .wake: "Wake-up fade and time"
        case .idle: "Idle, away and off"
        case .services: "Your music and connected accounts"
        case .voice: "Wake word and listening history"
        case .hearing: "Room recognition, knocks and whistles"
        case .shelf: "Your record collection, from Discogs"
        case .teach: "Songs you add for recognition"
        case .ask: "Ask a question, see the answer on the wall"
        case .note: "Short messages on the wall"
        case .show: "Find a cover or a video"
        case .earworm: "Find the song in your head"
        case .imagine: "Turn a few words into a picture"
        case .weather: "Forecast and the weather face"
        case .games: "Play on the wall and the phone"
        case .design: "Room, Panel or iPod"
        case .lockScreen: "The wall on the Lock Screen"
        case .widgets: "The wall on your Home Screen"
        case .homeKit: "Scenes and the Home app"
        case .guests: "Share your Wi-Fi with a code"
        case .colour: "Calibrate the panel with your camera"
        case .panel: "Check every light"
        case .health: "Power, heat and picture updates"
        case .addresses: "The wall’s address and a connection check"
        case .about: "Version, openings and tuning"
        }
    }

    private var aliases: String {
        switch self {
        case .light: "dim intensity led"
        case .time: "countdown snooze repeat minutes seconds"
        case .sun: "sunrise sunset location automatic night"
        case .sleep: "bedtime shutdown fade timer"
        case .wake: "morning dawn schedule"
        case .idle: "nothing playing pause presence leave black hold ambient drift weather standby power resume"
        case .services: "apple spotify lastfm listenbrainz anthropic api key account login connect mac reporter"
        case .voice: "microphone speech assistant"
        case .hearing: "music recognition shazam sound microphone knock whistle gate"
        case .shelf: "vinyl discogs records archive collection"
        case .teach: "teach recognition identify library learning songs"
        case .ask: "question answer ai claude prompt"
        case .note: "text message temporary duration expiry ticker"
        case .show: "artwork search film video album"
        case .earworm: "lyrics identify song words"
        case .imagine: "generate picture image ai"
        case .weather: "forecast temperature celsius fahrenheit city"
        case .games: "play fun controller"
        case .design: "classic panel ipod room 3d click wheel look layout style appearance theme home view"
        case .lockScreen: "dynamic island live activity notification"
        case .widgets: "widget widgets home screen small medium add glance"
        case .homeKit: "automation siri smart home"
        case .guests: "wifi password qr guest network"
        case .colour: "color white balance calibration green camera"
        case .panel: "pixel dead test rgb"
        case .health: "diagnostics fps cpu memory heat throttling uptime power voltage undervoltage storage disk renderer frozen stuck temperature"
        case .addresses: "address ip hostname network offline reconnect local network permission wifi check queue waiting log mac"
        case .about: "version build credits acknowledgements licence license fonts legal privacy opening intro sting film mark first run setup onboarding again tuning advanced tessera"
        }
    }

    static func results(for query: String) -> [Self] {
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return allCases }
        return allCases.filter { item in
            let haystack = normalized("\(item.title) \(item.detail) \(item.aliases) \(item.section.title)")
            return words.allSatisfy { haystack.contains($0) }
        }.sorted { a, b in
            let aExact = normalized(a.title).hasPrefix(words.joined(separator: " "))
            let bExact = normalized(b.title).hasPrefix(words.joined(separator: " "))
            return aExact == bExact ? allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! : aExact
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case rhythm, music, explore, home, care
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rhythm: "Light & rhythm"
        case .music: "Sound & services"
        case .explore: "Create & explore"
        case .home: "Around your home"
        case .care: "Care & connection"
        }
    }
    var entries: [SettingsDestination] { SettingsDestination.allCases.filter { $0.section == self } }
}
