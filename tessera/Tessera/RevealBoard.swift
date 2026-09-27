import SwiftUI

struct RevealBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft = ""
    @State private var submitted: String?
    @State private var submittedCount = 0
    @FocusState private var writing: Bool
    private let honey = Color(hex: 0xF4DBA4)
    private var elapsed: Double { finite(game.state["elapsed"].double, fallback: 0) }
    private var duration: Double { max(1, finite(game.state["seconds"].double, fallback: 30)) }
    private var remaining: Int { max(0, Int(ceil(min(duration, max(0, duration - elapsed))))) }
    private var fraction: Double { min(1, max(0, elapsed / duration)) }
    private var guesses: [JSONValue] { game.state["guesses"].array }
    private var count: Int { max(0, game.state["guess_count"].int ?? guesses.count) }
    private var canGuess: Bool { !game.over && remaining > 0 && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if typeSize.isAccessibilitySize {
                if !game.over {
                    Text("\(remaining) seconds left").font(.ui(17, .semibold)).foregroundStyle(honey)
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(remaining) seconds remaining")
                }
            } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.over ? (game.won ? "Solved" : "Answer") : "Name this cover")
                        .font(.display(typeSize.isAccessibilitySize ? 29 : 35)).foregroundStyle(Ink.ink)
                    Text(game.over ? "The full cover." : "Name the album or artist as the image clears.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !game.over {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(remaining)").font(.display(43)).monospacedDigit().foregroundStyle(honey).contentTransition(.numericText())
                        Text("SECONDS").font(.machine(9)).tracking(1).foregroundStyle(Ink.dim)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("\(remaining) seconds remaining")
                }
            }
            }
            // The canvas hides itself from VoiceOver, so give the artwork its own
            // element; a label on the hidden canvas is never read.
            GameArtworkCanvas(game: game).aspectRatio(1, contentMode: .fit).frame(maxWidth: typeSize.isAccessibilitySize ? 240 : 300).frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(game.over ? "Revealed album artwork" : "Album cover, gradually becoming clearer")
                .accessibilityAddTraits(.isImage)
            if game.over { answer }
            else {
                if !typeSize.isAccessibilitySize { timeline }
                VStack(alignment: .leading, spacing: 9) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            guessField.padding(16).frame(maxWidth: .infinity)
                                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 17))
                            Button(action: submit) {
                                Label("Send guess", systemImage: "arrow.up").font(.ui(16, .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 54)
                            }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground)
                                .background(canGuess ? honey : honey.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)).disabled(!canGuess)
                        }
                    } else {
                    HStack(alignment: .center, spacing: 10) {
                        guessField
                        Button(action: submit) {
                            Image(systemName: "arrow.up").font(.ui(18, .semibold)).frame(width: 44, height: 44)
                        }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground)
                            .background(canGuess ? honey : honey.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)).disabled(!canGuess)
                            .accessibilityLabel("Send guess")
                    }.padding(10).padding(.leading, 6).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 17))
                    }
                    Text(typeSize.isAccessibilitySize ? "Use the full name." : "A complete name wins. Try again while time remains.").font(.ui(12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !guesses.isEmpty { recentGuesses }
        }
        .onChange(of: count) { _, new in
            guard let submitted, new > submittedCount, guesses.suffix(min(guesses.count, new - submittedCount)).contains(where: { $0["text"].string == submitted }) else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { draft = "" }
            self.submitted = nil
        }
        .onChange(of: game.over) { _, over in if over { writing = false } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: game.over)
    }
    private var guessField: some View {
        TextField(typeSize.isAccessibilitySize ? "Your guess" : "Album, artist or song", text: $draft, axis: .vertical)
            .font(.ui(17)).textInputAutocapitalization(.words).autocorrectionDisabled()
            .lineLimit(1...3).focused($writing).submitLabel(.send).onSubmit(submit)
            .accessibilityLabel("Your guess").accessibilityHint("Enter the full album, artist or song name")
            .onChange(of: draft) { _, new in if new.count > 120 { draft = String(new.prefix(120)) } }
    }
    private var timeline: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<20) { index in
                    Capsule().fill(Double(index) / 20 <= fraction ? honey : Ink.plaster).frame(height: index % 5 == 0 ? 15 : 8)
                }
            }.accessibilityHidden(true)
            HStack {
                Text("BLURRED"); Spacer(); Text("CLEAR")
            }.font(.machine(8)).tracking(0.6).foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Reveal progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
    private var answer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(game.won ? "RECOGNISED IN \(elapsed.formatted(.number.precision(.fractionLength(1)))) SECONDS" : "THE ANSWER", systemImage: game.won ? "checkmark.circle" : "eye")
                .font(.machine(10)).foregroundStyle(honey)
            Text(answerTitle).font(typeSize.isAccessibilitySize ? .ui(22, .semibold) : .display(31)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            if let artist = game.state["answer"]["artist"].string, !artist.isEmpty { Text(artist).font(.ui(17)).foregroundStyle(Ink.dim) }
            if let winner = game.winner { Text("Found by \(winner)").font(.ui(13, .semibold)).foregroundStyle(honey) }
        }
    }
    private var answerTitle: String {
        let album = game.state["answer"]["album"].string ?? ""
        return album.isEmpty ? game.state["answer"]["title"].string ?? "The sleeve" : album
    }
    private var recentGuesses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GUESSES").font(.machine(10)).tracking(1.5)
                Spacer()
                Text(count.formatted()).font(.machine(12))
            }.foregroundStyle(Ink.dim)
            ForEach(Array(guesses.suffix(5).reversed().enumerated()), id: \.offset) { _, guess in
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))) {
                    Text(guess["text"].string ?? "").font(.ui(15)).foregroundStyle(Ink.ink)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 12) }
                    if game.players.count > 1 { Text(guess["who"].string ?? "").font(.ui(12)).foregroundStyle(Ink.dim) }
                }.accessibilityElement(children: .combine)
            }
        }.padding(.top, 3)
    }
    private func submit() {
        guard canGuess else { return }
        let guess = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = guess; submittedCount = count
        send(["guess": guess])
    }
    private func finite(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite, value >= 0, value <= 300 else { return fallback }
        return value
    }
}
