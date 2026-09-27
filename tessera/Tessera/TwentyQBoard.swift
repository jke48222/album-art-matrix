import SwiftUI

struct TwentyQBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.gameCanInteract) private var canInteract
    @State private var pending: (question: String, answer: String)?
    @State private var showAll = false
    private let gold = Color(hex: 0xDFB965)
    private let paper = Color(hex: 0xF0E7D3)
    private let sage = Color(hex: 0x91BF97)
    private var history: [JSONValue] { game.state["history"].array }
    private var number: Int { min(20, max(1, game.state["number"].int ?? 1)) }
    private var questionID: String? { game.state["question_id"].string }
    private var thinking: Bool { game.state["thinking"].bool == true }
    private var problem: String? { game.state["problem"].string }
    private var canAnswer: Bool { !game.over && !thinking && problem == nil && questionID != nil }
    private var label: String {
        game.over ? (game.won ? "FOUND IT" : "SECRET KEPT") : thinking ? "THINKING" : problem != nil ? "TRY AGAIN" : game.state["is_guess"].bool == true ? "A GUESS" : "QUESTION"
    }
    private var question: String {
        if game.over { return game.won ? game.state["answer"].string ?? "Found it." : "You kept your secret." }
        return game.state["question"].string ?? (problem != nil ? "Your answers are safe." : "Finding the next question.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if typeSize.isAccessibilitySize { accessibleCard }
            else { questionCard.frame(maxWidth: 320).frame(maxWidth: .infinity) }
            if !game.over {
                if canAnswer {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: 10) { answerButtons }
                    } else {
                        HStack(spacing: 9) { answerButtons }
                    }
                    Text("Or knock once for yes; whistle for no.").font(.ui(12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else if thinking {
                    HStack(spacing: 10) {
                        ProgressView().tint(gold)
                        Text(history.isEmpty ? "Think of a thing. The first question is on its way." : "Answer recorded. Finding the next question.")
                            .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                }
                if let problem {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(problem).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        if game.state["can_retry"].bool == true {
                            Button { if canInteract { send(["retry": true]) } } label: {
                                Label("Try next question again", systemImage: "arrow.clockwise")
                                    .font(.ui(15, .semibold)).frame(minHeight: 48)
                            }.buttonStyle(.plain).foregroundStyle(gold).disabled(!canInteract)
                        }
                    }
                }
            }
            if !history.isEmpty { conversation }
        }
        .onChange(of: game.state["receipt"].int) { _, _ in
            if let pending, game.state["last_answer"]["question_id"].string == pending.question {
                self.pending = nil
            }
        }
        .onChange(of: questionID) { _, _ in pending = nil }
        .onChange(of: game.over) { _, over in if over { showAll = false; pending = nil } }
    }

    private var questionCard: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                Color(hex: 0x100E0C)
                Text(String(format: "%02d", number)).font(.custom(Face.display, fixedSize: side * 0.14)).foregroundStyle(gold)
                    .position(x: side * 0.5, y: side * 0.15)
                Text(label).font(.custom(Face.monoMedium, fixedSize: side * 0.032)).tracking(1.4).foregroundStyle(Ink.dim)
                    .position(x: side * 0.5, y: side * 0.295)
                if thinking || (problem != nil && !game.over) {
                    HStack(spacing: side * 0.065) {
                        ForEach(0..<3) { _ in Circle().fill(thinking ? gold : Ink.dim).frame(width: side * 0.034, height: side * 0.034) }
                    }.position(x: side * 0.5, y: side * 0.51)
                    if problem != nil {
                        Text("Your answers are safe.").font(.custom(Face.ui, fixedSize: side * 0.04)).foregroundStyle(paper)
                            .position(x: side * 0.5, y: side * 0.71)
                    }
                } else {
                    Text(question).font(.custom(Face.uiMedium, fixedSize: side * 0.075)).foregroundStyle(paper)
                        .multilineTextAlignment(.center).lineLimit(8).minimumScaleFactor(0.58)
                        .frame(width: side * 0.84, height: side * 0.43)
                        .position(x: side * 0.5, y: side * 0.585)
                }
                Canvas { context, _ in
                    for index in 0..<20 {
                        let rect = CGRect(x: side * (0.07 + Double(index) * 0.86 / 19), y: side * 0.9, width: max(1, side * 0.021), height: side * 0.026)
                        context.fill(Path(roundedRect: rect, cornerRadius: side * 0.004), with: .color(index < history.count ? gold : Color(hex: 0x373026)))
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 21))
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(number) of 20. \(question)")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: questionID)
    }
    private var accessibleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number) of 20").font(.custom(Face.monoMedium, size: 10, relativeTo: .caption2)).foregroundStyle(gold)
                .accessibilityLabel("\(label), question \(number) of 20")
            Text(question).font(.custom(Face.uiMedium, size: 17, relativeTo: .body)).foregroundStyle(paper)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).background(Color(hex: 0x100E0C), in: RoundedRectangle(cornerRadius: 21))
    }
    @ViewBuilder private var answerButtons: some View {
        answerButton("Yes", value: "yes", symbol: "checkmark", colour: sage)
        answerButton("Sort of", value: "sort of", symbol: "minus", colour: gold)
        answerButton("No", value: "no", symbol: "xmark", colour: paper)
    }
    private func answerButton(_ title: String, value: String, symbol: String, colour: Color) -> some View {
        Button {
            guard canAnswer, canInteract, let questionID else { return }
            pending = (questionID, value)
            send(["answer": value, "question_id": questionID])
        } label: {
            HStack(spacing: 6) { Image(systemName: symbol); Text(title) }
                .font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(pending?.answer == value ? Ink.ground : colour)
                .background(pending?.answer == value ? colour : Ink.plaster, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.97)).disabled(!canInteract)
            .accessibilityLabel("Answer \(title.lowercased())")
            .accessibilityHint("Answers question \(number)")
    }
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("The conversation").font(.ui(19, .semibold)).foregroundStyle(paper)
                Spacer(minLength: 8)
                Text(String(history.count)).font(.machine(12)).foregroundStyle(gold)
            }
            ForEach(Array(history.enumerated().reversed().prefix(showAll ? 20 : 5)), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(String(format: "%02d", index + 1))  \(item["q"].string ?? "")")
                        .font(.ui(15)).foregroundStyle(paper).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: item["a"].string == "yes" ? "checkmark" : item["a"].string == "no" ? "xmark" : "minus")
                        Text((item["a"].string ?? "").capitalized)
                    }.font(.ui(12, .semibold)).foregroundStyle(item["a"].string == "yes" ? sage : gold)
                }.padding(.vertical, 3).accessibilityElement(children: .combine)
            }
            if history.count > 5 {
                Button { showAll.toggle() } label: {
                    Label(showAll ? "Show fewer" : "All \(history.count) answers", systemImage: showAll ? "chevron.up" : "chevron.down")
                        .font(.ui(13, .semibold)).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(gold)
            }
        }.padding(.top, 4)
    }
}
