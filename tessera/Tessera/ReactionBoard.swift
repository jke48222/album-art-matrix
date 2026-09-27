import SwiftUI

private enum ReactionInk {
    static let ground = Color(hex: 0x0B0A09)
    static let line = Color(hex: 0x5D6F67)
    static let ready = Color(hex: 0xBDD6B4)
    static let wait = Color(hex: 0x551D1A)
    static let waitInk = Color(hex: 0xFFC0AD)
    static let go = Color(hex: 0x236C4A)
    static let goInk = Color(hex: 0xD8FFDC)
    static let error = Color(hex: 0xEC6959)
}

struct ReactionBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var phase: String { game.state["phase"].string ?? "ready" }
    private var rounds: Int { max(1, min(20, game.state["rounds"].int ?? 5)) }
    private var round: Int { max(1, min(rounds, game.state["round"].int ?? 1)) }
    private var last: Int? { game.state["last_ms"].int }
    private var kind: String { game.state["last_kind"].string ?? (last == nil ? "false_start" : "hit") }
    private var player: String { game.state["turn"].string ?? game.players.first ?? "You" }
    private var shownPlayer: String { game.state["last_player"].string ?? player }
    /// While a result is shown, turn and round already name the next turn,
    /// so the header uses the turn that produced the result.
    private var headerPlayer: String { phase == "shown" ? shownPlayer : player }
    private var headerRound: Int { phase == "shown" ? max(1, min(rounds, game.state["last_round"].int ?? round)) : round }
    private var title: String {
        if game.over { return last.map { "\($0) milliseconds" } ?? (kind == "missed" ? "Missed" : "Too early") }
        switch phase {
        case "red": return "Wait."
        case "green": return "Now. Knock or tap."
        case "shown": return last.map { "\($0) milliseconds." } ?? (kind == "missed" ? "Missed." : "Too early.")
        default: return "Ready."
        }
    }
    private var detail: String {
        switch phase {
        case "red": return "Wait for NOW and the solid target. A knock or tap before the signal uses this turn."
        case "green": return "Knock the frame or tap the target."
        case "shown":
            if game.over { return "Every turn is saved below." }
            if player == "You" && shownPlayer == "You" { return "Your turn is saved. The next signal starts automatically." }
            let saved = shownPlayer == "You" ? "Your turn is saved." : "\(shownPlayer)’s turn is saved."
            let next = player == "You" ? "You’re next." : "\(player) is next."
            return "\(saved) \(next) The next signal starts automatically."
        default: return "\(rounds) turns each. When the open circle becomes a solid target, knock the frame or tap here."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.over ? "RESULTS" : "\(headerPlayer.uppercased()), TURN \(headerRound) OF \(rounds)")
                    .font(.machine(10)).foregroundStyle(ReactionInk.ready).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Group {
                if game.over || phase == "shown" {
                    signal.accessibilityHidden(false).accessibilityElement(children: .ignore).accessibilityLabel(title)
                } else {
                    Button(action: activate) { signal }
                        .buttonStyle(.plain)
                        .accessibilityLabel(phase == "ready" ? "Start reaction game" : phase == "red" ? "Wait. Tapping now is an early start" : "Now. Tap the target")
                        .accessibilityValue(title)
                }
            }.frame(maxWidth: 360).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                Text(typeSize.isAccessibilitySize && last != nil && phase == "shown" ? "\(last ?? 0) ms" : title)
                    .font(.ui(22, .semibold)).foregroundStyle(Color.white).accessibilityLabel(title)
                Text(detail).font(.ui(14)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
            if phase == "ready" && !game.over {
                Button(action: activate) {
                    HStack { Text("Ready to begin"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.ui(16, .semibold)).foregroundStyle(ReactionInk.ground)
                        .padding(.horizontal, 18).frame(minHeight: 52)
                        .background(ReactionInk.ready, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressStyle())
            }
            Label("Phone taps include screen, input and network delay. Watch the wall and knock for direct wall timing.", systemImage: "wifi")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if (game.state["completed"].int ?? game.state["times"].object.values.reduce(0, { $0 + $1.array.count })) > 0 {
                results
            }
        }
        .onChange(of: phase) { _, next in
            if next == "green" {
                Taps.commit()
                UIAccessibility.post(notification: .announcement, argument: "Now. Knock the frame or tap.")
            } else if next == "shown" {
                UIAccessibility.post(notification: .announcement, argument: title)
            }
        }
    }

    private var signal: some View {
        ReactionSignal(phase: phase, milliseconds: last, kind: kind, over: game.over,
                       rounds: rounds, trials: trials(for: phase == "shown" ? shownPlayer : player))
            .aspectRatio(1, contentMode: .fit)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Times").font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
            ForEach(game.players, id: \.self) { name in
                let values = game.state["times"][name].array
                let valid = values.compactMap(\.int)
                let best = game.state["best"][name].int ?? valid.min()
                let mean = game.state["average"][name].int ?? (valid.isEmpty ? nil : Int((Double(valid.reduce(0, +)) / Double(valid.count)).rounded()))
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 24))
                    layout {
                        metric("Best", value: best)
                        metric("Average", value: mean)
                    }
                    if !values.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 88), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").foregroundStyle(Ink.dim)
                                    if let ms = value.int { Text("\(ms) ms").foregroundStyle(ReactionInk.ready) }
                                    else { Image(systemName: "xmark").foregroundStyle(ReactionInk.error); Text("No score").foregroundStyle(Ink.dim) }
                                }.font(.machine(10)).accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Turn \(index + 1), \(value.int.map { "\($0) milliseconds" } ?? "no score")")
                            }
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func metric(_ label: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(12)).foregroundStyle(Ink.dim)
            Text(value.map { "\($0) ms" } ?? "None").font(.display(28)).foregroundStyle(ReactionInk.ready)
        }.accessibilityElement(children: .combine)
    }
    private func trials(for name: String) -> [Int?] { game.state["times"][name].array.map(\.int) }
    private func activate() {
        guard !game.over else { return }
        if phase == "ready" { send(["go": true]) }
        else if phase == "red" || phase == "green" { send(["tap": true]) }
    }
}

private struct ReactionSignal: View {
    let phase: String
    let milliseconds: Int?
    let kind: String
    let over: Bool
    let rounds: Int
    let trials: [Int?]
    private var ink: Color { phase == "red" ? ReactionInk.waitInk : phase == "green" ? ReactionInk.goInk : ReactionInk.ready }
    private var label: String { phase == "red" ? "WAIT" : phase == "green" ? "NOW" : phase == "ready" ? "READY" : milliseconds.map(String.init) ?? (kind == "missed" ? "MISSED" : "EARLY") }
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Rectangle().fill(phase == "red" ? ReactionInk.wait : phase == "green" ? ReactionInk.go : ReactionInk.ground)
                if ["ready", "red", "green"].contains(phase) {
                    Circle().strokeBorder(ink, lineWidth: max(1, s / 96)).frame(width: s * 0.25, height: s * 0.25).position(x: s * 0.5, y: s * 0.30)
                    if phase == "red" {
                        HStack(spacing: s * 4 / 64) { Rectangle().fill(ink); Rectangle().fill(ink) }
                            .frame(width: s * 10 / 64, height: s * 8 / 64).position(x: s * 0.5, y: s * 19 / 64)
                    } else if phase == "green" {
                        Circle().fill(ink).frame(width: s * 0.13, height: s * 0.13).position(x: s * 0.5, y: s * 0.30)
                        ForEach(0..<4, id: \.self) { index in
                            Rectangle().fill(ink).frame(width: s / 64, height: s * 4 / 64)
                                .offset(y: -s * 12 / 64).rotationEffect(.degrees(Double(index) * 90))
                                .position(x: s * 0.5, y: s * 0.30)
                        }
                    }
                    Text(label).font(.custom(Face.display, fixedSize: s * 0.19)).foregroundStyle(Color.white)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: s * 0.84).position(x: s * 0.5, y: s * 0.61)
                } else {
                    Text(label).font(.custom(Face.display, fixedSize: s * (milliseconds == nil ? 0.18 : 0.28)))
                        .foregroundStyle(Color.white).lineLimit(1).minimumScaleFactor(0.45).frame(width: s * 0.84)
                        .position(x: s * 0.5, y: s * 0.47)
                    Text(milliseconds == nil ? "NO SCORE" : "MS").font(.custom(Face.mono, fixedSize: s * 0.045))
                        .foregroundStyle(milliseconds == nil ? ReactionInk.error : Ink.dim).position(x: s * 0.5, y: s * 0.69)
                }
                let spacing = min(s * 0.075, s * 0.82 / CGFloat(rounds))
                let radius = max(1, min(s * 0.018, spacing * 0.28))
                ForEach(0..<rounds, id: \.self) { index in
                    let colour = index < trials.count ? (trials[index] == nil ? ReactionInk.error : ReactionInk.ready) : ReactionInk.line
                    Group {
                        if index < trials.count { Rectangle().fill(colour) }
                        else { Circle().strokeBorder(colour, lineWidth: max(1, radius * 0.5)) }
                    }.frame(width: radius * 2, height: radius * 2)
                        .position(x: s * 0.5 - CGFloat(rounds - 1) * spacing / 2 + CGFloat(index) * spacing, y: s * 0.86)
                }
                if over { Rectangle().strokeBorder(ReactionInk.ready, lineWidth: max(1, s / 64)).padding(s * 3 / 64) }
            }
        }.accessibilityHidden(true)
    }
}
