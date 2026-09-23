import SwiftUI

/// A single reading of the song for every home. A disconnected wall carries
/// a frozen position, never a clock that silently pretends it is still live.
struct PlaybackIdentity: Equatable {
    enum Status: Equatable { case playing, paused, audioPlaying, audioPaused, displayed, lastPlayed, preview, offline, searching, empty }

    let title: String
    let artist: String
    let album: String
    let hasSong: Bool
    let status: Status
    let elapsed: Double?
    let duration: Double?
    let advances: Bool

    init(state: WallState, link: LinkState, at date: Date = Date()) {
        func clean(_ string: String?) -> String {
            (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let song = clean(state.title)
        hasSong = !song.isEmpty
        title = hasSong ? song : Self.emptyTitle(mode: state.mode, link: link)
        artist = clean(state.artist)
        let record = clean(state.album)
        album = record.caseInsensitiveCompare(artist) == .orderedSame ? "" : record
        let hasPosition = Self.validSeconds(state.songAt) != nil && state.songStamped != nil
        switch link {
        case .offline: status = .offline
        case .searching: status = .searching
        case .standIn: status = .preview
        case .live:
            let musicFace = ["art", "cd", "nine", "lyrics"].contains(state.mode)
            if !hasSong { status = .empty }
            else if !hasPosition { status = musicFace ? .displayed : .lastPlayed }
            else if state.songPlaying { status = musicFace ? .playing : .audioPlaying }
            else { status = musicFace ? .paused : .audioPaused }
        }
        advances = hasSong && hasPosition && state.songPlaying && (link.isLive || link.isStandIn)
        duration = hasSong ? Self.validSeconds(state.songOf).flatMap { $0 > 0 ? $0 : nil } : nil
        if hasSong {
            let end: Date
            switch link {
            case .offline(let since): end = min(date, since)
            case .searching: end = state.songStamped ?? date
            default: end = date
            }
            elapsed = state.songPosition(at: end)
        } else {
            elapsed = nil
        }
    }

    var fraction: Double? {
        guard let elapsed, let duration else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    var statusLabel: String {
        switch status {
        case .playing: "Now playing"
        case .paused: "Paused"
        case .audioPlaying: "Audio playing"
        case .audioPaused: "Audio paused"
        case .displayed: "On the wall"
        case .lastPlayed: "Last played"
        case .preview: "Phone preview"
        case .offline: hasSong ? "Last known track" : "Wall offline"
        case .searching: "Finding your wall"
        case .empty: "Room for music"
        }
    }

    var statusSymbol: String {
        switch status {
        case .playing, .audioPlaying: "play.fill"
        case .paused, .audioPaused: "pause.fill"
        case .displayed: "square.grid.3x3.fill"
        case .lastPlayed: "clock.arrow.circlepath"
        case .preview: "iphone"
        case .offline: "wifi.slash"
        case .searching: "antenna.radiowaves.left.and.right"
        case .empty: "music.note"
        }
    }

    var context: String {
        switch status {
        case .offline: "Playback will update when your wall reconnects."
        case .searching: "Your wall and its music will appear here."
        case .preview: hasSong ? (advances ? "Playing on this phone." : "On this phone.") : "Play music to preview it here."
        default: hasSong ? "" : "Play something you love."
        }
    }

    var accessibilitySummary: String {
        [statusLabel, title, artist, album].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func clock(_ seconds: Double?) -> String {
        guard let seconds = validSeconds(seconds) else { return "—:—" }
        let total = Int(seconds.rounded(.down))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func validSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max / 2) else { return nil }
        return value
    }

    private static func emptyTitle(mode: String, link: LinkState) -> String {
        if case .offline = link { return "Your room, on hold." }
        if case .searching = link { return "Finding your wall." }
        switch mode {
        case "off": return "The wall is asleep."
        case "weather": return "A window to the weather."
        case "ambient": return "A little atmosphere."
        case "clock", "timer": return "Take your time."
        case "frame", "clip", "video", "imagine": return "Your wall, your canvas."
        case "game": return "Ready to play."
        default: return "A quiet moment."
        }
    }
}

/// MD Vinyl's object-first hierarchy, with readable type beyond the record.
/// Reference: https://mobbin.com/screens/b766b650-9cf6-4de7-a2bb-202db47e086c
/// Clock scheduling: https://developer.apple.com/documentation/swiftui/timelineview
struct NowPlayingIdentity: View {
    let state: WallState
    let link: LinkState
    var accent: Color = Ink.tile
    var ink: Color = Ink.ink
    var secondary: Color = Ink.dim
    var compact = false
    var showsStatus = true
    var showsProgress = true

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var song: PlaybackIdentity { PlaybackIdentity(state: state, link: link) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            if showsStatus {
                Label(song.statusLabel, systemImage: song.statusSymbol)
                    .font(.machine(compact ? 9 : 10))
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(secondary)
                    .labelStyle(.titleAndIcon)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                Text(song.title)
                    .font(.display(compact ? 26 : 34))
                    .tracking(-0.7)
                    .foregroundStyle(ink)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if song.hasSong {
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.ui(compact ? 14 : 17, .medium))
                            .foregroundStyle(ink.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !song.album.isEmpty && !compact {
                        Text(song.album)
                            .font(.ui(13))
                            .foregroundStyle(secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    }
                } else {
                    Text(song.context)
                        .font(.ui(compact ? 12 : 14))
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(song.accessibilitySummary)

            if showsProgress, song.hasSong {
                PlaybackProgress(state: state, link: link, accent: accent,
                                 secondary: secondary, compact: compact)
                    .padding(.top, compact ? 2 : 4)
            }
            if !compact, let owned = state.owned, song.hasSong, !owned.line.isEmpty {
                Label(owned.line, systemImage: "opticaldisc")
                    .font(.ui(12))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let left = state.sleepRemaining, left > 0 {
                Label("Sleep in \(PlaybackIdentity.clock(Double(left)))", systemImage: "moon.zzz")
                    .font(.machine(10))
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.22), value: state.title)
    }
}

/// This is a reading, not a seek control. Timer text alone updates each second;
/// it stops when playback pauses, the wall disconnects, or the app backgrounds.
struct PlaybackProgress: View {
    let state: WallState
    let link: LinkState
    var accent: Color = Ink.tile
    var secondary: Color = Ink.dim
    var compact = false
    @Environment(\.scenePhase) private var scenePhase

    private var running: Bool {
        scenePhase == .active && PlaybackIdentity(state: state, link: link).advances
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !running)) { context in
            let song = PlaybackIdentity(state: state, link: link, at: context.date)
            VStack(spacing: compact ? 5 : 9) {
                if let fraction = song.fraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(secondary.opacity(0.18))
                            Capsule().fill(accent).frame(width: max(0, geometry.size.width * fraction))
                            Circle().fill(accent)
                                .frame(width: 6, height: 6)
                                .offset(x: max(0, min(geometry.size.width - 6, geometry.size.width * fraction - 3)))
                        }
                    }
                    .frame(height: 3)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(PlaybackIdentity.clock(song.elapsed))
                    Spacer(minLength: 8)
                    if let duration = song.duration, let elapsed = song.elapsed {
                        Text("−" + PlaybackIdentity.clock(max(0, duration - elapsed)))
                    } else {
                        Text(song.elapsed == nil ? "Position unavailable" : "Duration unavailable")
                    }
                }
                .font(.machine(compact ? 9 : 10, medium: false))
                .monospacedDigit()
                .foregroundStyle(secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback progress")
            .accessibilityValue(progressDescription(song))
        }
    }

    private func progressDescription(_ song: PlaybackIdentity) -> String {
        guard let elapsed = song.elapsed else { return "Position unavailable" }
        let position = "\(PlaybackIdentity.clock(elapsed)) elapsed"
        let total = song.duration.map { " of \(PlaybackIdentity.clock($0))" } ?? ""
        return position + total + ". " + song.statusLabel
    }
}
