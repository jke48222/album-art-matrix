import SwiftUI

struct SlidingBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var frameReady = false

    private let sage = Color(hex: 0xC5D3AC)
    private var n: Int { game.state["n"].int == 4 ? 4 : 3 }
    private var tiles: [Int] { game.state["tiles"].ints }
    private var gap: Int { game.state["gap"].int ?? -1 }
    private var valid: Bool { tiles.count == n * n && Set(tiles) == Set(0..<(n * n)) && (0..<tiles.count).contains(gap) && tiles[gap] == n * n - 1 }
    private var legal: Set<Int> {
        guard valid, !game.over else { return [] }
        return Set(tiles.indices.filter { abs($0 / n - gap / n) + abs($0 % n - gap % n) == 1 })
    }
    private var placed: Int { tiles.enumerated().filter { $0.offset == $0.element && $0.element != n * n - 1 }.count }
    private var moves: Int { max(0, game.state["moves"].int ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !typeSize.isAccessibilitySize {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(game.over ? "Back together." : "Piece by piece.").font(.display(typeSize.isAccessibilitySize ? 29 : 33)).foregroundStyle(Ink.ink)
                    Text(game.over ? "Every piece in its place." : "A familiar sleeve. A different perspective.").font(.ui(14)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 10)
                Text("\(n) × \(n)").font(.machine(13)).foregroundStyle(sage)
            }
            }
            if valid {
                board.frame(maxWidth: typeSize.isAccessibilitySize ? 260 : 320).frame(maxWidth: .infinity)
                if typeSize.isAccessibilitySize {
                    Text("\(moves) \(moves == 1 ? "move" : "moves") · \(placed)/\(n * n - 1) home")
                        .font(.ui(15, .semibold)).foregroundStyle(sage)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(moves) moves. \(placed) of \(n * n - 1) tiles in the correct position.")
                } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(moves.formatted()).font(.display(35)).foregroundStyle(Ink.ink).contentTransition(.numericText())
                        Text(moves == 1 ? "MOVE" : "MOVES").font(.machine(10)).tracking(1.3).foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("\(placed) of \(n * n - 1) tiles home").font(.ui(14, .semibold)).foregroundStyle(sage)
                        ProgressView(value: Double(placed), total: Double(n * n - 1)).tint(sage).frame(maxWidth: 150)
                            .accessibilityLabel("Tiles in the correct position").accessibilityValue("\(placed) of \(n * n - 1)")
                    }
                }
                }
                if !game.over {
                    Text(typeSize.isAccessibilitySize ? "Tap beside the gap." : "Tap a highlighted tile beside the empty space. The numbers show where each piece belongs.")
                        .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            undoControl
                            numbersControl
                        }
                    } else {
                        HStack(spacing: 18) {
                            undoControl
                            Spacer(minLength: 0)
                            numbersControl.fixedSize()
                        }
                    }
                } else {
                    sleeve
                }
            } else {
                MessageNotice(title: "Getting the puzzle ready", detail: "Waiting for the complete tile arrangement from your wall.", symbol: "square.grid.3x3", tint: sage)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: moves)
    }

    private var undoControl: some View {
        Button { send(["undo": true]) } label: {
            Label("Undo", systemImage: "arrow.uturn.backward").font(.ui(14)).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(sage)
            .disabled(game.state["can_undo"].bool != true)
            .accessibilityLabel("Undo last slide")
            .accessibilityHint("Restores the previous arrangement and counts as one move")
    }
    private var numbersControl: some View {
        Toggle(isOn: Binding(get: { game.state["numbers"].bool ?? true }, set: { send(["numbers": $0]) })) {
            Text("Numbers").font(.ui(14)).fixedSize(horizontal: false, vertical: true)
        }.tint(sage).frame(minHeight: 44).accessibilityLabel("Show tile numbers")
    }

    private var board: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack(alignment: .topLeading) {
                GameArtworkCanvas(game: game, onAvailabilityChange: { frameReady = $0 }).accessibilityHidden(true)
                if !game.over && frameReady {
                    ForEach(tiles.indices, id: \.self) { pos in
                        let box = tileRect(pos, side: side)
                        if pos == gap {
                            Color.clear.frame(width: box.width, height: box.height).contentShape(Rectangle())
                                .position(x: box.midX, y: box.midY)
                                .accessibilityElement().accessibilityLabel("Empty space, row \(pos / n + 1), column \(pos % n + 1)")
                        } else {
                            Button { guard legal.contains(pos) else { return }; Taps.detent(intensity: 0.3); send(["tile": pos]) } label: {
                                Color.clear.frame(width: box.width, height: box.height).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!legal.contains(pos))
                                .position(x: box.midX, y: box.midY)
                                .accessibilityLabel("Tile \(tiles[pos] + 1), row \(pos / n + 1), column \(pos % n + 1)\(tiles[pos] == pos ? ", in place" : "")")
                                .accessibilityHint(legal.contains(pos) ? "Slides into the empty space at row \(gap / n + 1), column \(gap % n + 1)" : "Only tiles beside the empty space can move")
                        }
                    }
                }
            }
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: game.over ? .ignore : .contain)
            .accessibilityLabel(game.over ? "Completed album artwork" : "Sliding picture puzzle")
    }
    private func tileRect(_ pos: Int, side: CGFloat) -> CGRect {
        // Use the production 512px renderer's quantized edges for hit testing.
        let edges = (0...n).map { CGFloat((Double($0) * 512 / Double(n)).rounded(.toNearestOrEven)) / 512 * side }
        let row = pos / n, col = pos % n
        return CGRect(x: edges[col], y: edges[row], width: edges[col + 1] - edges[col], height: edges[row + 1] - edges[row])
    }
    private var sleeve: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(game.state["sleeve"]["album"].string?.nonEmpty ?? game.state["sleeve"]["title"].string ?? "Your sleeve")
                .font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
            if let artist = game.state["sleeve"]["artist"].string, !artist.isEmpty {
                Text(artist).font(.ui(15)).foregroundStyle(Ink.dim)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
