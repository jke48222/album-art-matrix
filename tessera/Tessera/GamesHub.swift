import SwiftUI

struct GamesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    var body: some View {
        NavigationStack {
            GamesSheetBody(accent: accent)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

struct GamesSheetBody: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @State private var cards: [GameCard] = []
    @State private var status: GameStatus?
    @State private var selection: String?
    @State private var query = ""
    @State private var category = "All"
    @State private var loaded = false
    @State private var problem: String?
    private let mint = Color(hex: 0xBDD6B4)
    private var visible: [GameCard] {
        cards.filter { (category == "All" || $0.category == category) &&
            (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
             "\($0.title) \($0.blurb) \($0.category)".localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }
    private var featured: [GameCard] { visible.filter { ["wordle", "sudoku"].contains($0.name) } }
    private var remaining: [GameCard] { visible.filter { !["wordle", "sudoku"].contains($0.name) } }

    var body: some View {
        MessagePage(title: "Games", eyebrow: "A LITTLE FRIENDLY COMPETITION", tint: mint) {
            hero
            if let game = status?.game {
                Button { selection = game.name } label: { activeGame(game) }
                    .buttonStyle(PressStyle(scale: 0.985))
            }
            if !wall.link.isLive {
                MessageNotice(title: "Your wall is offline", detail: "Reconnect to start or return to a game. Your current board stays on the wall.", symbol: "wifi.slash", tint: mint)
            }
            if let problem { MessageProblem(text: problem) }
            if !loaded && problem == nil {
                HStack(spacing: 12) { ProgressView(); Text("Finding your games…").font(.ui(14)).foregroundStyle(Ink.dim) }
                    .padding(.vertical, 30)
            } else if cards.isEmpty {
                MessageNotice(title: "No games available", detail: "Pull to refresh when games are enabled on your wall.", symbol: "square.grid.2x2", tint: mint)
            } else {
                catalogueControls
                if visible.isEmpty {
                    MessageNotice(title: "No games match", detail: "Try a different name or category.", symbol: "magnifyingglass", tint: mint)
                }
                ForEach(featured) { card in
                    Button { selection = card.name } label: { feature(card) }
                        .buttonStyle(PressStyle(scale: 0.985))
                }
                ForEach(["Puzzles", "Music", "Arcade", "Together"], id: \.self) { group in
                    let games = remaining.filter { $0.category == group }
                    if !games.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group).font(.display(25)).foregroundStyle(Ink.ink).padding(.bottom, 15)
                            ForEach(games) { card in
                                Button { selection = card.name } label: { row(card) }
                                    .buttonStyle(.plain)
                                if card.id != games.last?.id { Divider().overlay(Ink.faint.opacity(0.15)).padding(.leading, 76) }
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await load(host: wall.host) }
        .navigationDestination(item: $selection) { name in
            if let card = cards.first(where: { $0.name == name }) {
                GameDestination(card: card, status: $status)
            } else if status?.game?.name == name {
                GameScreen(accent: GameMotif.colour(name), name: name, status: $status)
            }
        }
        .task(id: "\(wall.host)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            let host = wall.host
            await load(host: host)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-game-page"), i + 1 < args.count { selection = args[i + 1] }
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, host == wall.host else { return }
                if selection == nil, let next = await GameLink.status(host: host), host == wall.host, !Task.isCancelled, selection == nil { status = next }
            }
        }
        .onChange(of: wall.host) { _, _ in selection = nil; cards = []; status = nil; loaded = false; problem = nil }
    }
    private var hero: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Make room\nfor play.").font(typeSize.isAccessibilitySize ? .ui(29, .semibold) : .display(42))
                    .foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Text("A small challenge.\nA good reason to stay a while.").font(.ui(15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                VStack(spacing: 14) {
                    GameMotif(name: "wordle").frame(width: 106, height: 64).rotationEffect(.degrees(-9))
                    GameMotif(name: "sudoku").frame(width: 84, height: 64).rotationEffect(.degrees(9))
                }.accessibilityHidden(true)
            }
        }.padding(.bottom, 7)
    }
    private var catalogueControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                TextField("Find a game", text: $query).font(.ui(15)).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).accessibilityLabel("Search games")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Clear search") }
            }.padding(.horizontal, 14).frame(minHeight: 50).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(["All", "Puzzles", "Music", "Arcade", "Together"], id: \.self) { name in
                        Button { category = name } label: {
                            Text(name).font(.ui(13, .semibold)).padding(.horizontal, 17).frame(minHeight: 44)
                                .foregroundStyle(category == name ? Ink.ground : Ink.dim)
                                .background(category == name ? mint : Ink.plaster, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(category == name ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
    private func feature(_ card: GameCard) -> some View {
        let colour = GameMotif.colour(card.name)
        return VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.name == "wordle" ? "FIVE LETTERS. SIX CHANCES." : "A MOMENT OF CLARITY.")
                        .font(.machine(9)).tracking(0.6).foregroundStyle(colour).fixedSize(horizontal: false, vertical: true)
                    Text(card.title).font(.display(33)).foregroundStyle(Ink.ink)
                }
                Spacer(minLength: 8)
                if !typeSize.isAccessibilitySize { GameMotif(name: card.name).frame(width: 108, height: 66).accessibilityHidden(true) }
            }
            Text(card.blurb).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(card.playerLabel).font(.ui(12)).foregroundStyle(Ink.dim)
                Spacer()
                HStack(spacing: 7) { Text("Let's play").font(.ui(14, .semibold)); Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)) }
                    .foregroundStyle(colour)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(colour.opacity(0.085), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(colour.opacity(0.23), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 25))
    }
    private func row(_ card: GameCard) -> some View {
        HStack(spacing: 14) {
            GameMotif(name: card.name).scaleEffect(0.52).frame(width: 62, height: 60)
                .background(GameMotif.colour(card.name).opacity(0.08), in: RoundedRectangle(cornerRadius: 15)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title).font(.ui(17, .semibold)).foregroundStyle(Ink.ink)
                Text(card.blurb).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(2)
                Text(card.playerLabel).font(.machine(9)).foregroundStyle(GameMotif.colour(card.name))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
        }.padding(.vertical, 15).contentShape(Rectangle())
    }
    private func activeGame(_ game: GameStatus.Game) -> some View {
        HStack(spacing: 15) {
            if status?.on_wall != false && wall.state.displayedMode == "game" {
                WallBoard().frame(width: 72, height: 72)
            } else { GameMotif(name: game.name).frame(width: 108, height: 64).scaleEffect(0.66).frame(width: 76, height: 58).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 6) {
                Text(game.over ? "YOUR LAST GAME" : "PICK UP WHERE YOU LEFT OFF").font(.machine(9)).foregroundStyle(mint)
                Text(game.title).font(.ui(20, .semibold)).foregroundStyle(Ink.ink)
                Text(game.over ? "See your result" : "Return to your board").font(.ui(13)).foregroundStyle(Ink.dim)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right").foregroundStyle(mint)
        }.padding(16).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 22))
    }
    private func load(host: String) async {
        do {
            let result = try await GameLink.catalogue(host: host)
            let next = await GameLink.status(host: host)
            guard !Task.isCancelled, host == wall.host else { return }
            cards = result; if selection == nil, let next { status = next }; loaded = true; problem = next == nil ? "Couldn’t read the current game. Pull to refresh." : nil
        } catch {
            guard !Task.isCancelled, host == wall.host else { return }
            loaded = true; problem = "Couldn't read games from the wall. Pull to refresh."
        }
    }
}

private struct GameDestination: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let card: GameCard
    @Binding var status: GameStatus?
    @AppStorage("games.player") private var player = ""
    @State private var names: [String] = []
    @State private var starting = false
    @State private var problem: String?
    @State private var generation = UUID()
    private var tint: Color { GameMotif.colour(card.name) }
    private var cleanNames: [String] { names.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) } }
    private var valid: Bool { cleanNames.count >= card.minimumPlayers && cleanNames.allSatisfy { !$0.isEmpty } && Set(cleanNames.map { $0.lowercased() }).count == cleanNames.count }
    var body: some View {
        Group {
            if status?.game?.name == card.name {
                GameScreen(accent: tint, name: card.name, status: $status)
            } else {
                MessagePage(title: card.title, eyebrow: card.category.uppercased(), tint: tint) {
                    GameMotif(name: card.name).frame(height: 110).frame(maxWidth: .infinity)
                        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 26)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.title).font(.display(typeSize.isAccessibilitySize ? 30 : 42)).foregroundStyle(Ink.ink)
                        Text(card.blurb).font(.ui(18)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        Text("The board lives on your wall. Play here, together in the room.").font(.ui(14)).foregroundStyle(Ink.dim)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(names.count == 1 ? "Your name" : "Who's playing?").font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                        ForEach(names.indices, id: \.self) { i in
                            HStack {
                                Text("\(i + 1)").font(.machine(13)).foregroundStyle(tint).frame(width: 25)
                                TextField("Player \(i + 1)", text: $names[i]).font(.ui(17)).textContentType(.nickname)
                                    .accessibilityLabel("Player \(i + 1) name")
                                    .onChange(of: names[i]) { _, value in if value.count > 24 { names[i] = String(value.prefix(24)) } }
                                if names.count > card.minimumPlayers {
                                    Button { names.remove(at: i) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }.accessibilityLabel("Remove player \(i + 1)")
                                }
                            }.padding(.horizontal, 12).frame(minHeight: 54).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 15))
                        }
                        if names.count < card.maximumPlayers { Button("Add another player", systemImage: "plus") { names.append("") }.font(.ui(14, .semibold)).frame(minHeight: 44) }
                        if !valid { Text("Give each player a different name.").font(.ui(13)).foregroundStyle(Ink.dim) }
                    }.disabled(starting)
                    if let existing = status?.game, !existing.over {
                        MessageNotice(title: "A game is already open", detail: "Starting \(card.title) will end \(existing.title) and count it as played.", symbol: "arrow.triangle.2.circlepath", tint: tint)
                    }
                    if !wall.link.isLive { MessageNotice(title: "Reconnect to play", detail: "Your player names stay here while the wall is offline.", symbol: "wifi.slash", tint: tint) }
                    if let problem { MessageProblem(text: problem) }
                    Button(action: start) {
                        HStack { if starting { ProgressView().tint(Ink.ground) }; Text(starting ? "Getting your game ready…" : "Start \(card.title)").font(.ui(16, .semibold)); Spacer(); Image(systemName: "arrow.right") }
                            .padding(19).foregroundStyle(Ink.ground).background(tint, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(PressStyle()).disabled(!valid || starting || !wall.link.isLive)
                }
            }
        }
        .onAppear { if names.isEmpty { names = [player.isEmpty ? "You" : player] + Array(repeating: "", count: max(0, card.minimumPlayers - 1)) } }
        .onDisappear { generation = UUID(); starting = false }
        .onChange(of: wall.host) { _, _ in generation = UUID(); starting = false; problem = nil }
    }
    private func start() {
        guard valid, !starting, wall.link.isLive else { return }
        let host = wall.host, token = UUID(), players = cleanNames
        generation = token; starting = true; problem = nil
        var body: [String: Any] = ["name": card.name, "players": players]
        if let session = status?.session_id { body["session_id"] = session }
        Task {
            do {
                let result = try await GameLink.perform(host: host, "start", body)
                guard host == wall.host, generation == token else { return }
                player = players.first ?? "You"; status = result; Taps.commit()
            } catch {
                guard host == wall.host, generation == token else { return }
                problem = error.localizedDescription
                let latest = await GameLink.status(host: host)
                guard host == wall.host, generation == token else { return }
                if let latest { status = latest }
            }
            starting = false
        }
    }
}
