import SwiftUI

struct GameScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let accent: Color
    let name: String
    @Binding var status: GameStatus?
    @AppStorage("games.player") private var player = ""
    @State private var typed = ""
    @State private var chosenPlayer = ""
    @State private var speech = SpeechMove()
    @State private var problem: String?
    @State private var sending = false
    @State private var readFailed = false
    @State private var version = 0
    @State private var operation = UUID()
    @State private var confirmEnd = false
    @State private var activeRequest: Task<GameStatus, Error>?
    @State private var pendingCommands = GameCommandBuffer()
    @State private var pendingSteer = GameSteeringBuffer()
    @State private var pendingCourtCommand: [String: Any]?
    @State private var pendingCourtSession: String?
    @State private var clipTransport = GameClipTransport()
    @FocusState private var typing: Bool
    private var game: GameStatus.Game? { status?.game?.name == name ? status?.game : nil }
    private var me: String { !chosenPlayer.isEmpty ? chosenPlayer : game?.players.first(where: { $0 == player }) ?? game?.players.first ?? "You" }
    /// In a shared Wordle the wall credits each guess to whoever's turn it
    /// is, whoever sends it, so the phone plays as that person too.
    private var wordleTurn: String? {
        guard let g = game, g.name == "wordle", g.players.count > 1, let turn = g.state["turn"].string, g.players.contains(turn) else { return nil }
        return turn
    }
    private var onWall: Bool { wall.state.displayedMode == "game" && status?.on_wall != false }
    private var canSend: Bool { wall.link.isLive && !readFailed && !sending && game != nil }
    private var canSteer: Bool { wall.link.isLive && !readFailed && scenePhase == .active && game != nil }
    private var pollingInterval: Double {
        guard onWall, game?.over == false else { return 1 }
        switch name {
        case "whistlebird", "pong", "snake", "tetris": return 0.1
        case "quiz", "pictionary", "heardle", "twentyq": return 0.25
        case "reaction": return 0.08
        case "reveal": return 0.25
        default: return 1
        }
    }
    private var wordless: Set<String> { ["wordle", "sudoku", "connections", "spellingbee", "letterboxed", "strands", "crossword", "contexto", "heardle", "quiz", "pictionary", "reveal", "sliding", "reaction", "whistlebird", "twentyq", "pong", "snake", "tetris"] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let g = game {
                    if onWall {
                        WallStrip(colour: accent, message: g.over ? "Your finished board." : "Your moves appear here and on the wall.",
                                  compact: ["connections", "spellingbee", "letterboxed", "strands", "crossword", "contexto", "sliding", "reveal", "reaction", "whistlebird", "heardle", "twentyq", "quiz", "pictionary", "pong", "snake", "tetris"].contains(g.name))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            MessageNotice(title: "Your board is saved", detail: "The wall is showing something else. Bring this game back when you're ready.", symbol: "square.grid.3x3", tint: accent)
                            Button("Return game to wall", systemImage: "arrow.up.right") { perform("resume", [:]) }
                                .font(.ui(14, .semibold)).frame(minHeight: 44).disabled(!canSend)
                        }
                    }
                    if !wall.link.isLive || readFailed {
                        // The wall pauses Snake and Tetris after a few seconds
                        // without hearing from the phone.
                        MessageNotice(title: "Waiting for your wall", detail: ["snake", "tetris"].contains(g.name) ? "The round pauses on the wall until your phone reconnects." : "Your board and draft are kept here. Moves resume when the connection returns.", symbol: "wifi.slash", tint: accent)
                    }
                    if g.players.count > 1 {
                        Picker("Playing as", selection: $chosenPlayer) {
                            ForEach(g.players, id: \.self) { person in Text(person).tag(person) }
                        }.pickerStyle(.menu).tint(accent).disabled(sending || wordleTurn != nil)
                    }
                    board(g).id(status?.session_id ?? "\(g.name)-\(g.state["started"].int ?? 0)")
                        .environment(\.gameSessionID, status?.session_id)
                        .environment(\.gameCanInteract, canSteer && onWall && scenePhase == .active)
                        .disabled(!(["whistlebird", "pong", "snake", "tetris"].contains(g.name) ? canSteer : canSend) || !onWall)
                    // These boards already show their own status, so the wall's
                    // message line would repeat it.
                    if !g.message.isEmpty && !g.over && !["heardle", "twentyq", "quiz", "pictionary", "pong", "snake", "tetris", "contexto", "sliding", "reveal", "reaction", "whistlebird"].contains(g.name) {
                        Text(g.message).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    if g.over { result(g) }
                    else {
                        if !wordless.contains(g.name) { wordHand(g) }
                        if g.voice == true { microphone }
                    }
                    if sending && !["whistlebird", "pong", "snake", "tetris"].contains(name) { HStack(spacing: 10) { ProgressView(); Text("Updating your wall…").font(.ui(13)).foregroundStyle(Ink.dim) }.accessibilityElement(children: .combine) }
                    if let text = problem ?? speech.problem { MessageProblem(text: text) }
                    if !g.over {
                        Button("Finish this game") { confirmEnd = true }.font(.ui(13)).foregroundStyle(Ink.dim).frame(minHeight: 44)
                            .disabled(!canSend)
                    }
                } else {
                    MessageNotice(title: "This game has ended", detail: "Choose another game from the library whenever you're ready.", symbol: "checkmark.circle", tint: accent)
                    Button("Back to games") { dismiss() }.font(.ui(16, .semibold)).frame(minHeight: 48)
                }
            }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 35)
        }.background(Ink.ground).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .navigationTitle(game?.title ?? "Game").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar).tint(accent)
            .confirmationDialog("Finish this game?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("Finish and return to the wall") { perform("end", [:], leaving: true) }
                Button("Keep playing", role: .cancel) {}
            } message: { Text("This round counts as played. The wall returns to what it was showing before.") }
            .task(id: "\(wall.host)|\(scenePhase)") {
                guard scenePhase == .active else { speech.stop(); return }
                let host = wall.host
                while !Task.isCancelled {
                    if !sending {
                        let stamp = version
                        let next = await GameLink.status(host: host)
                        guard !Task.isCancelled, host == wall.host else { return }
                        if version == stamp && !sending {
                            if let next { status = next; readFailed = false } else { readFailed = true }
                        }
                    }
                    try? await Task.sleep(for: .seconds(pollingInterval))
                }
            }
            .onAppear { chosenPlayer = wordleTurn ?? me; GameArcadeLifecycle.shared.cancel(host: wall.host, session: status?.session_id) }
            .onDisappear { pauseArcade(); pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil; speech.stop(); operation = UUID(); version += 1; sending = false }
            .onChange(of: chosenPlayer) { _, _ in pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil }
            .onChange(of: wordleTurn) { _, turn in if let turn { chosenPlayer = turn } }
            // A move that reached the wall just after the round ended comes back
            // as "that game is over". The results already say so.
            .onChange(of: game?.over) { _, over in if over == true { problem = nil } }
            .onChange(of: scenePhase) { _, next in if next == .active { GameArcadeLifecycle.shared.cancel(host: wall.host, session: status?.session_id) }; if next != .active { pauseArcade(); pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil } }
            .onChange(of: wall.host) { _, _ in pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil; speech.stop(); operation = UUID(); version += 1; sending = false; readFailed = true; typed = "" }
            .onChange(of: status?.session_id) { _, _ in
                pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil; speech.stop(); typed = ""
                // A rematch keeps the same players, so each phone keeps its own
                // side or seat. Only a player who is no longer in the game moves.
                if let g = game, !g.players.contains(chosenPlayer) {
                    chosenPlayer = g.players.first(where: { $0 == player }) ?? g.players.first ?? "You"
                }
            }
    }

    @ViewBuilder private func board(_ g: GameStatus.Game) -> some View {
        switch g.name {
        case "wordle": WordleBoard(game: g, accent: accent, send: post)
        case "sudoku": SudokuBoard(game: g, accent: accent, send: post)
        case "connections": ConnectionsBoard(game: g, accent: accent, send: post)
        case "spellingbee": SpellingBeeBoard(game: g, accent: accent, send: post)
        case "letterboxed": LetterBoxedBoard(game: g, accent: accent, send: post)
        case "strands": StrandsBoard(game: g, accent: accent, send: post)
        case "crossword": CrosswordBoard(game: g, accent: accent, send: post)
        case "contexto": ContextoBoard(game: g, accent: accent, send: post)
        case "heardle": HeardleBoard(game: g, accent: accent, playerName: me, send: post, playback: reportPlayback)
        case "reveal": RevealBoard(game: g, accent: accent, send: post)
        case "sliding": SlidingBoard(game: g, accent: accent, send: post)
        case "reaction": ReactionBoard(game: g, accent: accent, send: post)
        case "whistlebird": WhistleBirdBoard(game: g, accent: accent, send: post)
        case "twentyq": TwentyQBoard(game: g, accent: accent, send: post)
        case "quiz": QuizBoard(game: g, accent: accent, playerName: me, send: post)
        case "pictionary": PictionaryBoard(game: g, accent: accent, send: post)
        case "pong": PongBoard(game: g, accent: accent, player: me, send: post)
        case "snake": SnakeBoard(game: g, accent: accent, send: post)
        case "tetris": TetrisBoard(game: g, accent: accent, send: post)
        default: WallBoard()
        }
    }
    private func result(_ g: GameStatus.Game) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline(g)).font(.display(29)).foregroundStyle(Ink.ink)
            Text(g.message).font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if let scores = status?.scores {
                ForEach(g.players, id: \.self) { person in
                    if let score = scores[person] {
                        VStack(alignment: .leading, spacing: 10) {
                            if g.players.count > 1 { Text(person).font(.ui(14, .semibold)).foregroundStyle(Ink.ink) }
                            HStack(spacing: 0) {
                                stat("PLAYED", score.played); stat("WON", score.won); stat("STREAK", score.streak)
                            }
                        }
                    }
                }
            }
            // The wall restarts with this round's options and players, so a
            // Sudoku rematch keeps its difficulty.
            Button { perform("move", ["player": me, "move": ["again": true]]) } label: {
                HStack { Text("Play another round").font(.ui(16, .semibold)); Spacer(); Image(systemName: "arrow.right") }
                    .padding(18).foregroundStyle(Ink.ground).background(accent, in: RoundedRectangle(cornerRadius: 17))
            }.buttonStyle(PressStyle()).disabled(!canSend)
            Button("Return to the wall") { perform("end", [:], leaving: true) }.font(.ui(14, .semibold)).frame(minHeight: 44).disabled(!canSend)
        }.padding(20).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
    }
    private func headline(_ g: GameStatus.Game) -> String {
        if g.players.count > 1 { return g.winner.map { "\($0) won" } ?? "Round over" }
        if ["pong", "snake", "tetris", "whistlebird", "reaction", "quiz"].contains(g.name) { return "Game over" }
        return g.won ? "Solved" : "Not solved"
    }
    /// Wall errors arrive as short lowercase phrases, such as "not in the
    /// list". Show them as sentences.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return text }
        var result = first.uppercased() + trimmed.dropFirst()
        if let last = result.last, !".!?".contains(last) { result += "." }
        return result
    }
    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.formatted()).font(.display(28)).foregroundStyle(accent)
            Text(title).font(.machine(9)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func wordHand(_ g: GameStatus.Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder(g), text: $typed, axis: .vertical).font(.ui(17)).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($typing).lineLimit(1...3).padding(16).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
                .onSubmit(send).accessibilityLabel("Your move")
            Button("Send move", systemImage: "arrow.up") { send() }.font(.ui(15, .semibold)).frame(minHeight: 48)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend || !onWall)
        }
    }
    private var microphone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if speech.listening { speech.stop() }
                else {
                    speech.start(words: status?.voice_words ?? []) { text in perform("hear", ["text": text, "player": me]) }
                }
            } label: {
                Label(speech.listening ? "Stop listening" : "Speak your move", systemImage: speech.listening ? "stop.circle" : "mic")
                    .font(.ui(14, .semibold)).frame(minHeight: 48)
            }.disabled(!canSend || !onWall).accessibilityHint("Uses this phone's microphone")
            if speech.listening { Text(speech.heard.isEmpty ? "Listening…" : speech.heard).font(.ui(14)).foregroundStyle(Ink.dim) }
        }
    }
    private func placeholder(_ g: GameStatus.Game) -> String {
        switch g.name {
        case "contexto": "A word, any word"
        case "heardle": "The song, or skip"
        case "reveal": "The album or artist"
        case "quiz": "Your answer"
        case "connections": "Four words, separated by commas"
        case "crossword": "Clue and answer, like 1A lamp"
        default: "Your move"
        }
    }
    private var steeringKey: String { name == "pong" ? "paddle" : "y" }

    private func reportPlayback(_ origin: GameClipOrigin, _ playing: Bool, _ position: Double) {
        let move: [String: Any] = ["played": playing, "position": position, "step": origin.step]
        clipTransport.send(host: origin.host, session: origin.session, player: origin.player, move: move) { detail in
            if wall.host == origin.host && status?.session_id == origin.session && game?.over == false && game?.state["step"].int == origin.step { problem = detail }
        }
    }

    private func post(_ move: [String: Any]) {
        var move = move
        // Phone-only: marks where a drag or slider ended. The wall never sees it.
        let final = move.removeValue(forKey: GameSteeringBuffer.finalKey) as? Bool == true
        if ["snake", "tetris"].contains(name), sending {
            guard canSteer, onWall, game?.over == false else { return }
            if !pendingCommands.offer(move, session: status?.session_id) { problem = "Let the wall catch up, then try again." }
            return
        }
        if name == "pong", move["paddle"] == nil, sending {
            guard canSteer, onWall, game?.over == false else { return }
            pendingCourtCommand = move; pendingCourtSession = status?.session_id
            pendingSteer.clear()
            return
        }
        if ["whistlebird", "pong"].contains(name), let y = move[steeringKey] as? Double {
            guard canSteer, onWall, game?.over == false, y.isFinite else { return }
            if sending {
                // Keep only the newest finger position; never replay a drag backlog.
                pendingSteer.offer(y, session: status?.session_id, final: final)
                return
            }
        }
        if ["snake", "tetris"].contains(name) { GameArcadeLifecycle.shared.cancel(host: wall.host, session: status?.session_id) }
        perform("move", ["player": me, "move": move])
    }
    private func send() {
        let word = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return }
        var move: [String: Any] = ["guess": word]
        switch game?.name {
        case "connections":
            let words = word.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            move = words.count == 4 ? ["words": words] : ["pick": word]
        case "crossword":
            let parts = word.split(separator: " ", maxSplits: 1).map(String.init)
            move = parts.count == 2 ? ["slot": parts[0].uppercased(), "word": parts[1]] : ["word": word]
        case "quiz": move = ["answer": word]
        case "heardle": move = word == "skip" ? ["skip": true] : ["guess": word]
        default: break
        }
        perform("move", ["player": me, "move": move], clearDraft: true)
    }
    private func pauseArcade() {
        guard ["snake", "tetris"].contains(name), game?.over == false, let session = status?.session_id else { return }
        GameArcadeLifecycle.shared.pause(host: wall.host, session: session, player: me, after: activeRequest)
    }
    private func perform(_ action: String, _ body: [String: Any], clearDraft: Bool = false, leaving: Bool = false) {
        guard canSend else { return }
        let host = wall.host, token = UUID(), draft = typed
        let steering = action == "move" && ["whistlebird", "pong"].contains(name) && (body["move"] as? [String: Any])?[steeringKey] != nil
        var body = body
        if let session = status?.session_id { body["session_id"] = session }
        operation = token; version += 1; sending = true; problem = nil; speech.stop()
        let request = Task { try await GameLink.perform(host: host, action, body, timeout: steering || ["snake", "tetris"].contains(name) ? 2 : 30) }
        activeRequest = request
        Task {
            do {
                let next = try await request.value
                guard operation == token, host == wall.host else { return }
                status = next; readFailed = false
                if clearDraft && typed == draft { typed = "" }
                if !steering { Taps.commit() }
                if leaving { dismiss() }
            } catch {
                guard operation == token, host == wall.host else { return }
                problem = Self.sentence(error.localizedDescription)
                pendingCommands.clear(); pendingSteer.clear(); pendingCourtCommand = nil; pendingCourtSession = nil
            }
            version += 1; sending = false; activeRequest = nil
            while let command = pendingCommands.take(session: status?.session_id) {
                guard canSteer, onWall, game?.over == false else { pendingCommands.clear(); break }
                let phase = game?.state["phase"].string ?? ""
                let valid = command["start"] as? Bool == true ? phase == "ready"
                    : command["resume"] as? Bool == true ? phase == "paused"
                    : phase == "playing"
                if valid { post(command); return }
            }
            if let command = pendingCourtCommand, pendingCourtSession == status?.session_id {
                pendingCourtCommand = nil; pendingCourtSession = nil
                let phase = game?.state["phase"].string ?? ""
                let valid = (command["serve"] as? Bool == true && phase == "ready")
                    || (command["resume"] as? Bool == true && phase == "paused")
                    || (command["pause"] as? Bool == true && ["serve", "rally", "point"].contains(phase))
                if valid && canSteer && onWall && game?.over == false { post(command); return }
            }
            if let y = pendingSteer.take(session: status?.session_id) { post([steeringKey: y]) }
        }
    }
}
