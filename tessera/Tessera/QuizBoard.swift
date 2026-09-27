import SwiftUI

struct QuizBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let playerName: String
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft = ""
    @State private var draftQuestion: Int?
    @State private var submitted: String?
    @State private var submittedQuestion: Int?
    @FocusState private var writing: Bool
    private let honey = Color(hex: 0xDCB946)
    private let mint = Color(hex: 0xA6DFB9)
    private var questionID: Int { game.state["question_id"].int ?? game.state["number"].int ?? 1 }
    private var phase: String { game.state["phase"].string ?? "question" }
    private var answered: [String: JSONValue] { game.state["answered"].object }
    private var accepted: Bool { answered[playerName] != nil }
    private var seconds: Double { finite(game.state["seconds"].double, fallback: 20) }
    private var left: Double { min(seconds, finite(game.state["seconds_left"].double, fallback: 0)) }
    private var staleDraft: Bool { !draft.isEmpty && draftQuestion != nil && draftQuestion != questionID }
    private var canAnswer: Bool { !game.over && phase == "question" && !accepted && !staleDraft && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var ranking: [String] {
        game.players.sorted { a, b in
            let sa = game.state["scores"][a].int ?? 0, sb = game.state["scores"][b].int ?? 0
            return sa == sb ? (game.players.firstIndex(of: a) ?? 0) < (game.players.firstIndex(of: b) ?? 0) : sa > sb
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if game.over { roundResult }
            else {
                questionCard
                if phase == "question" {
                    if accepted {
                        Label("Answer locked in", systemImage: "lock.fill").font(.ui(16, .semibold)).foregroundStyle(honey)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
                        Text("\(answered.count) of \(game.players.count) answered. The reveal is next.")
                            .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    } else { composer }
                } else { answerCard }
            }
            scoreRows
            if game.over { review }
        }
        .onChange(of: game.seq) { _, _ in acknowledge() }
        .onChange(of: questionID) { _, _ in acknowledge(); writing = false }
        .onChange(of: phase) { _, next in if next != "question" { writing = false } }
        .onChange(of: playerName) { _, _ in writing = false }
    }
    private var questionCard: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 15 : 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Q\(game.state["number"].int ?? 1)/\(game.state["count"].int ?? 10)").font(.machine(14)).foregroundStyle(honey)
                Spacer(minLength: 8)
                Text(phase == "question" ? "\(Int(ceil(left)))s" : "ANSWER").font(.machine(14)).foregroundStyle(Ink.ink).monospacedDigit()
                    .accessibilityLabel(phase == "question" ? "\(Int(ceil(left))) seconds remaining" : "Answer reveal")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x314146))
                    Capsule().fill(phase == "question" ? honey : mint)
                        .frame(width: geometry.size.width * (phase == "question" ? min(1, left / max(1, seconds)) : 1))
                }
            }.frame(height: 3).accessibilityHidden(true)
            Text(game.state["question"].string ?? "Waiting for the question")
                .font(.ui(typeSize.isAccessibilitySize ? 20 : 23, .semibold)).foregroundStyle(Color(hex: 0xF6E6C3))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                Text(game.state["theme"].string ?? "PUB QUIZ").font(.machine(10)).tracking(1).foregroundStyle(Color(hex: 0x87989F))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(typeSize.isAccessibilitySize ? 18 : 24)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 0 : 240, alignment: .topLeading)
            .background(Color(hex: 0x13191E), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(hex: 0x314146), lineWidth: 1))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                TextField("Your answer", text: $draft, axis: .vertical).font(.ui(17)).lineLimit(1...3)
                    .autocorrectionDisabled().textInputAutocapitalization(.sentences).submitLabel(.send).focused($writing)
                    .onSubmit(submit).onChange(of: draft) { old, new in
                        if old.isEmpty && !new.isEmpty { draftQuestion = questionID }
                        if new.count > 120 { draft = String(new.prefix(120)) }
                    }.accessibilityLabel("Your quiz answer")
                Button(action: submit) {
                    if typeSize.isAccessibilitySize { Label("Lock answer", systemImage: "lock").font(.ui(16, .semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                    else { Image(systemName: "arrow.up").font(.ui(18, .semibold)).frame(width: 44, height: 44) }
                }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground)
                    .background(canAnswer ? honey : honey.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(!canAnswer).accessibilityLabel("Submit answer")
            }.padding(12).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
            if staleDraft {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your previous answer was kept. Clear it before this question.").font(.ui(13)).foregroundStyle(Ink.dim)
                    Button("Clear previous answer") { draft = ""; draftQuestion = nil; submitted = nil }
                        .font(.ui(14, .semibold)).foregroundStyle(honey).frame(minHeight: 44)
                }
            } else {
                Text("One answer each. Lock yours before time runs out.").font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("THE ANSWER", systemImage: "checkmark.seal").font(.machine(11)).tracking(1).foregroundStyle(mint)
            Text(game.state["answer"].string ?? "Revealing the answer").font(.ui(24, .semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            if let receipt = answered[playerName] {
                Label(receipt["right"].bool == true ? "You got it." : "Your answer: \(receipt["text"].string ?? "")", systemImage: receipt["right"].bool == true ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.ui(14)).foregroundStyle(receipt["right"].bool == true ? mint : Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else { Text("No answer this time.").font(.ui(14)).foregroundStyle(Ink.dim) }
            Text("\(game.state["number"].int == game.state["count"].int ? "Final scores" : "Next question") in \(Int(ceil(finite(game.state["reveal_seconds_left"].double, fallback: 0))))s")
                .font(.ui(12)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
    private var roundResult: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("FINAL RESULT", systemImage: "flag.checkered").font(.machine(11)).tracking(1).foregroundStyle(honey)
            Text(game.state["tied"].bool == true ? "Tied" : game.winner.map { "\($0) won" } ?? "Round complete")
                .font(typeSize.isAccessibilitySize ? .ui(25, .semibold) : .display(34)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
            Text(game.state["theme"].string ?? "").font(.ui(15)).foregroundStyle(Ink.dim)
            if game.state["tied"].bool == true {
                Text("Tied: \(game.state["leaders"].strings.joined(separator: ", "))").font(.ui(15, .semibold)).foregroundStyle(honey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var scoreRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.over ? "FINAL SCORES" : "AT THE TABLE").font(.machine(10)).tracking(1.5).foregroundStyle(Ink.dim)
            ForEach(ranking, id: \.self) { who in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(who).font(.ui(15, who == playerName ? .semibold : .regular)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if phase == "question", answered[who] != nil { Image(systemName: "lock.fill").font(.ui(11)).foregroundStyle(honey).accessibilityLabel("Answer locked") }
                    Spacer(minLength: 8)
                    Text("\(game.state["scores"][who].int ?? 0)").font(.machine(16)).foregroundStyle(honey)
                }.accessibilityElement(children: .combine)
            }
        }.padding(.top, 4)
    }
    private var review: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(game.state["results"].array.enumerated()), id: \.offset) { index, result in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(index + 1). \(result["question"].string ?? "")").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                        Text(result["answer"].string ?? "").font(.ui(15)).foregroundStyle(mint)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 16)
        } label: { Label("Review the round", systemImage: "text.book.closed").font(.ui(16, .semibold)).foregroundStyle(Ink.ink).frame(minHeight: 44) }
            .tint(honey)
    }
    private func acknowledge() {
        guard let submitted, submittedQuestion == questionID, answered[playerName]?["text"].string == submitted else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { draft = ""; draftQuestion = nil }
        self.submitted = nil; submittedQuestion = nil
    }
    private func submit() {
        guard canAnswer else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = text; submittedQuestion = questionID
        send(["answer": text, "question_id": questionID])
    }
    private func finite(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite, value >= 0, value <= 120 else { return fallback }
        return value
    }
}
