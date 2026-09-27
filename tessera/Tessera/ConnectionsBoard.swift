import SwiftUI

struct ConnectionsBoard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    private var words: [String] { game.state["words"].strings }
    private var picked: [String] { game.state["picked"].strings }
    private var found: [JSONValue] { game.state["found"].array }
    private var groups: [JSONValue] { game.over ? game.state["groups"].array : found }
    private var mistakesLeft: Int { min(4, max(0, game.state["mistakes_left"].int ?? 4)) }
    private let tint = Color(hex: 0xB498D0)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { heading; Spacer(minLength: 16); progressCount }
                VStack(alignment: .leading, spacing: 10) { heading; progressCount }
            }
            VStack(spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in solvedGroup(group) }
                if !game.over {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                        ForEach(words, id: \.self) { word in wordTile(word) }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: found.count)
            if !game.over {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { chances; Spacer(minLength: 8); selectionCount }
                    VStack(alignment: .leading, spacing: 10) { chances; selectionCount }
                }
                HStack(spacing: 10) {
                    Button { send(["shuffle": true]) } label: {
                        Image(systemName: "shuffle").font(.system(size: 18, weight: .medium)).frame(width: 52, height: 52)
                    }.buttonStyle(.plain).foregroundStyle(Ink.ink)
                        .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityLabel("Shuffle remaining words").accessibilityHint("Keeps your selected words")
                    Button { send(["clear": true]) } label: {
                        Text("Clear").font(.ui(15, .semibold)).frame(minWidth: 54, minHeight: 52)
                    }.buttonStyle(.plain).foregroundStyle(Ink.dim).disabled(picked.isEmpty)
                    Button { if picked.count == 4 { send(["submit": true]) } } label: {
                        HStack(spacing: 8) { Text("Connect"); Image(systemName: "arrow.right") }
                            .font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(picked.count == 4 ? Ink.ground : Ink.dim)
                            .background(picked.count == 4 ? tint : Ink.plaster, in: RoundedRectangle(cornerRadius: 15))
                    }.buttonStyle(PressStyle(scale: 0.98)).disabled(picked.count != 4)
                        .accessibilityLabel("Submit four selected words")
                }
                Text("Find four words with something in common.").font(.ui(13)).foregroundStyle(Ink.dim)
            } else {
                Label(game.won ? "Every connection found" : "All four groups, revealed", systemImage: game.won ? "checkmark.seal.fill" : "eye")
                    .font(.ui(14, .semibold)).foregroundStyle(tint)
            }
        }.padding(18).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 24))
            .onChange(of: mistakesLeft) { previous, current in if current < previous { Taps.error() } }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Short words that wrap between each other at any text size. The
            // navigation title above already names the game.
            Text(game.over ? "All groups" : "Find the groups")
                .font(typeSize.isAccessibilitySize ? .ui(25, .semibold) : .displayMid(30)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(game.over ? (game.won ? "ALL FOUND" : "REVEALED") : "4 GROUPS OF 4")
                .font(.machine(8)).tracking(0.6).foregroundStyle(tint).accessibilityHidden(true)
        }
    }
    private var progressCount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(found.count)").font(.display(32)).foregroundStyle(tint)
            Text("/4").font(.ui(15)).foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(found.count) of four groups found")
    }
    private var selectionCount: some View {
        Text("\(picked.count) of 4 selected").font(.ui(12, .medium)).foregroundStyle(Ink.dim)
    }
    private var chances: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Image(systemName: index < mistakesLeft ? "circle.fill" : "xmark")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(index < mistakesLeft ? Ink.ink : Ink.dim)
                    .frame(width: 10, height: 12)
            }
            Text("\(mistakesLeft) left").font(.ui(12)).foregroundStyle(Ink.dim).padding(.leading, 3)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(mistakesLeft) mistakes remaining")
    }
    private func wordTile(_ word: String) -> some View {
        let selected = picked.contains(word)
        return Button { send(["pick": word]) } label: {
            VStack(spacing: 4) {
                Text(word.uppercased()).font(.ui(typeSize.isAccessibilitySize ? 15 : 12, .semibold))
                    .multilineTextAlignment(.center).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).accessibilityHidden(true) }
            }.padding(.horizontal, 4).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 98 : 72)
                .foregroundStyle(selected ? Ink.ground : Ink.ink)
                .background(selected ? Ink.ink : Ink.plaster, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Ink.ink : Ink.hairline.opacity(0.6), lineWidth: 0.7))
        }.buttonStyle(PressStyle(scale: 0.96))
            .accessibilityLabel(word).accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityHint(selected ? "Remove from your group" : "Add to your group of four")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func solvedGroup(_ group: JSONValue) -> some View {
        let colorName = group["colour"].string ?? "purple"
        let difficulty = group["difficulty"].int ?? (["yellow", "green", "blue", "purple"].firstIndex(of: colorName) ?? 3) + 1
        let solved = group["solved"].bool ?? found.contains(where: { $0["theme"].string == group["theme"].string })
        let title = group["theme"].string ?? "Connection"
        let list = group["words"].strings.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", difficulty)).font(.machine(9))
                Text(title).font(.ui(15, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: solved ? "checkmark.circle.fill" : "eye").font(.system(size: 13, weight: .medium))
            }
            Text(list).font(.ui(12, .medium)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Ink.ground).padding(14).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(groupTint(colorName), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(solved ? "Found" : "Revealed"), difficulty \(difficulty) of four. \(title): \(list)")
    }
    private func groupTint(_ name: String) -> Color {
        switch name {
        case "yellow": Color(hex: 0xDBB958)
        case "green": Color(hex: 0x91BF97)
        case "blue": Color(hex: 0x8BAEDA)
        default: Color(hex: 0xB498D0)
        }
    }
}
