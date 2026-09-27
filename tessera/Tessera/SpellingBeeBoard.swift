import SwiftUI

struct SpellingBeeBoard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var word = ""
    @State private var submitted: String?
    @State private var alphabetical = false
    @State private var ledgerExpanded = false
    @FocusState private var typing: Bool
    private let honey = Color(hex: 0xE8B22C)
    private var centre: String { game.state["centre"].string ?? "" }
    private var letters: [String] { (game.state["letters"].string ?? "").map(String.init) }
    private var found: [JSONValue] { game.state["found"].array }
    private var foundWords: [String] { found.compactMap { $0["word"].string } }
    private var points: Int { max(0, game.state["points"].int ?? 0) }
    private var total: Int { max(1, game.state["total"].int ?? 1) }
    private var rank: String { game.over && game.won ? "Queen Bee" : game.state["rank"].string ?? "Beginner" }
    private var nextRank: String { game.state["next_rank"].string ?? "Next rank" }
    private var nextPoints: Int { max(points, game.state["next_points"].int ?? total) }
    private var validDraft: Bool { word.count >= 4 && word.contains(centre) && Set(word).isSubset(of: Set(centre + letters.joined())) }
    private var draft: Binding<String> {
        Binding(get: { word }, set: { word = String($0.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(24)) })
    }
    private var ledger: [JSONValue] {
        alphabetical ? found.sorted { ($0["word"].string ?? "").localizedStandardCompare($1["word"].string ?? "") == .orderedAscending } : found
    }
    private var visibleLedger: [JSONValue] { ledgerExpanded ? ledger : Array(ledger.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 22 : 16) {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 13 : 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { score; Spacer(minLength: 16); rankLabel }
                    VStack(alignment: .leading, spacing: 10) { score; rankLabel }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.hairline)
                        Capsule().fill(honey).frame(width: geometry.size.width * min(1, CGFloat(points) / CGFloat(total)))
                    }
                }.frame(height: 5).accessibilityHidden(true)
                if !game.over {
                    let needed = max(0, nextPoints - points)
                    Text("\(needed) \(needed == 1 ? "point" : "points") to \(nextRank)").font(.ui(12)).foregroundStyle(Ink.dim)
                }
            }
            hive
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 236)
                .frame(maxWidth: .infinity)
            if !game.over { composer }
            if let last = found.first, let latest = last["word"].string {
                HStack(spacing: 10) {
                    Image(systemName: last["pangram"].bool == true ? "sparkle" : "checkmark.circle.fill").foregroundStyle(honey)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.uppercased()).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        Text(last["pangram"].bool == true ? "Pangram, all seven letters" : "Added to your words").font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 0)
                    if let earned = last["points"].int { Text("+\(earned)").font(.machine(13)).foregroundStyle(honey) }
                }.padding(.vertical, 4).accessibilityElement(children: .combine)
            }
            wordLedger
        }.padding(20).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 24))
            .onChange(of: foundWords) { _, accepted in
                if let submitted, accepted.contains(submitted) {
                    if word == submitted { word = "" }
                    self.submitted = nil
                }
            }
            .onChange(of: game.over) { _, finished in
                if finished { ledgerExpanded = false }
            }
    }

    private var score: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(points.formatted()).font(.display(42)).foregroundStyle(honey).monospacedDigit()
            Text("points").font(.ui(14)).foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .combine)
    }
    private var rankLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rank).font(.ui(19, .semibold)).foregroundStyle(Ink.ink)
            Text("\(found.count) of \(game.state["count"].int ?? 0) words").font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }
    private var hive: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let radius = side * 0.17
            let step = radius * 1.82
            ZStack {
                ForEach(Array(letters.enumerated()), id: \.element) { index, letter in
                    let angle = Double(index) * .pi / 3 + .pi / 6
                    cell(letter, middle: false, diameter: radius * 2)
                        .offset(x: cos(angle) * step, y: sin(angle) * step)
                }
                cell(centre, middle: true, diameter: radius * 2)
            }.frame(width: side, height: side)
        }.aspectRatio(1, contentMode: .fit)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: letters)
    }
    @ViewBuilder private func cell(_ letter: String, middle: Bool, diameter: CGFloat) -> some View {
        if game.over {
            cellLabel(letter, middle: middle, diameter: diameter)
                .accessibilityLabel("\(letter.uppercased())\(middle ? ", required center letter" : "")")
        } else {
            Button { if word.count < 24 { word += letter; Taps.detent() } } label: {
                cellLabel(letter, middle: middle, diameter: diameter)
            }.buttonStyle(PressStyle(scale: 0.93))
                .accessibilityLabel(middle ? "\(letter.uppercased()), required center letter" : letter.uppercased())
                .accessibilityHint("Add this letter to your word")
        }
    }
    private func cellLabel(_ letter: String, middle: Bool, diameter: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text(letter.uppercased()).font(.ui(typeSize.isAccessibilitySize ? 29 : 32, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            if middle { Capsule().fill(Ink.ground).frame(width: 14, height: 2).accessibilityHidden(true) }
        }.foregroundStyle(middle ? Ink.ground : Ink.ink).frame(width: diameter, height: diameter)
            .background(HexagonShape().fill(middle ? honey : Color(hex: 0x1E1B16)))
            .overlay(HexagonShape().stroke(middle ? honey.opacity(0.8) : Ink.hairline, lineWidth: 1))
            .contentShape(HexagonShape())
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 16 : 8) {
            if typeSize.isAccessibilitySize {
                centreRule
                wordField
                enterButton
                HStack(spacing: 12) { editingButtons; Spacer(minLength: 0) }
            } else {
                HStack(spacing: 8) {
                    wordField
                    enterButton.frame(width: 86)
                }
                HStack(spacing: 4) {
                    centreRule
                    Spacer(minLength: 4)
                    editingButtons
                }
            }
            if !word.isEmpty && !validDraft {
                Text(word.count < 4 ? "Four letters or more." : !word.contains(centre) ? "Include the center letter, \(centre.uppercased())." : "Use only the seven letters in the hive.")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }
    }
    private var centreRule: some View {
        HStack(spacing: 6) {
            Image(systemName: "hexagon.fill").foregroundStyle(honey)
            Text("Every word needs \(centre.uppercased()).").foregroundStyle(Ink.dim)
        }.font(.ui(12)).accessibilityElement(children: .combine)
    }
    private var wordField: some View {
        TextField("Build a word", text: draft, prompt: Text("Build a word").foregroundStyle(Ink.dim))
            .font(.ui(typeSize.isAccessibilitySize ? 24 : 21, .medium)).foregroundStyle(Ink.ink)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .focused($typing).submitLabel(.send).onSubmit(submit)
            .padding(.horizontal, 14).frame(minHeight: typeSize.isAccessibilitySize ? 62 : 54)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Your Spelling Bee word")
            .accessibilityHint("Use at least four letters, including \(centre.uppercased())")
    }
    private var enterButton: some View {
        Button(action: submit) {
            HStack(spacing: 6) { Text("Enter"); Image(systemName: "arrow.up") }
                .font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(validDraft ? Ink.ground : Ink.dim)
                .background(validDraft ? honey : Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.98)).disabled(!validDraft)
    }
    @ViewBuilder private var editingButtons: some View {
        Button { if !word.isEmpty { word.removeLast() } } label: {
            Image(systemName: "delete.left").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(Ink.ink).disabled(word.isEmpty).accessibilityLabel("Delete last letter")
        Button { send(["shuffle": true]) } label: {
            Image(systemName: "shuffle").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(Ink.ink).accessibilityLabel("Shuffle the outer letters")
            .accessibilityHint("Keeps the required center letter and your draft")
    }
    private var wordLedger: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { ledgerTitle; Spacer(minLength: 8); orderButton }
                VStack(alignment: .leading, spacing: 8) { ledgerTitle; orderButton }
            }
            if found.isEmpty {
                Text("Your first word starts the collection. Four-letter words earn one point. Longer words earn one point per letter.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                if found.count > 6 {
                    Button { ledgerExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Text(ledgerExpanded ? "Show fewer" : "Show all \(found.count) words")
                            Image(systemName: ledgerExpanded ? "chevron.up" : "chevron.down")
                        }.font(.ui(12, .semibold)).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(honey)
                        .accessibilityHint(ledgerExpanded ? "Collapses the collection to six words" : "Expands the complete collection here")
                }
                ForEach(Array(visibleLedger.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if item["pangram"].bool == true { Image(systemName: "sparkle").foregroundStyle(honey).accessibilityLabel("Pangram") }
                        Text((item["word"].string ?? "").uppercased()).font(.ui(14, .medium)).foregroundStyle(Ink.ink)
                        Spacer(minLength: 0)
                        if let earned = item["points"].int { Text("\(earned)").font(.machine(11)).foregroundStyle(Ink.dim) }
                    }.frame(minHeight: 35).accessibilityElement(children: .combine)
                }
            }
        }.padding(.top, 6)
    }
    private var ledgerTitle: some View {
        Text("Your words (\(found.count))").font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
    }
    private var orderButton: some View {
        Button { alphabetical.toggle() } label: {
            Label(alphabetical ? "A to Z" : "Recent", systemImage: "arrow.up.arrow.down").font(.ui(12)).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(honey).accessibilityLabel("Order found words: \(alphabetical ? "alphabetical" : "most recent")")
    }
    private func submit() {
        guard validDraft, !game.over else { return }
        submitted = word
        typing = false
        send(["word": word])
    }
}

/// Flat-top geometry shared with the wall's seven-letter hive.
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = Double(index) * .pi / 3
            let point = CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
