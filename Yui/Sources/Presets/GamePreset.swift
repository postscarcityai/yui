import SwiftUI
import YuiLines

/// `game KIND [title]` (YUI-59): a small game on the phone, one line.
/// `tictactoe` is turn-based against the agent: a tap is a move event, the
/// agent answers with a patch of its own cells (`~game o=1|7`). `snake` and
/// `memory` run on the phone and send one event when the game ends. Any other
/// kind says it is not in this version. Every event carries `kind`.
struct GamePreset: View {
    let c: YLComponent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    static let kinds: Set<String> = ["tictactoe", "snake", "memory"]

    var body: some View {
        let kind = (c.string("kind") ?? "").lowercased()
        PresetCard {
            if let title = c.string("title"), !title.isEmpty { PresetTitle(text: title) }
            switch kind {
            case "tictactoe": TicTacToeGame(c: c)
            case "snake": SnakeGame(c: c)
            case "memory": MemoryGame(c: c)
            default:
                Label(kind.isEmpty ? "No game named on this line." : "This game isn't in this version of Yui.",
                      systemImage: "gamecontroller")
                    .font(theme.font(theme.type.body, .semibold))
                    .foregroundStyle(theme.swatch(scheme).inkSoft)
                    .accessibilityIdentifier("game-unknown")
            }
        }
    }
}

/// A status line over a board: whose turn, the score, the result.
private struct GameStatus: View {
    let text: String
    var trailing: String? = nil
    var hot = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        HStack {
            Text(text).foregroundStyle(hot ? s.accent : s.ink)
                .accessibilityIdentifier("game-status")
            Spacer(minLength: 0)
            if let trailing { Text(trailing).foregroundStyle(s.inkSoft).accessibilityIdentifier("game-best") }
        }
        .font(theme.font(theme.type.body, .heavy))
        .contentTransition(.numericText())
    }
}

private extension YLComponent {
    func game(_ value: [String: YLValue], echo: String? = nil) -> YLEvent {
        var v = value
        v["kind"] = .string((string("kind") ?? "").lowercased())
        return event(v, echo: echo)
    }

    func clampedInt(_ key: String, _ range: ClosedRange<Int>, _ d: Int) -> Int {
        guard let n = number(key), n.isFinite else { return d }
        return min(range.upperBound, max(range.lowerBound, Int(n.rounded())))
    }
}

// MARK: - tic-tac-toe

/// The rules, shared by the view and the demo agent.
enum TicTacToe {
    static let lines = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [1, 4, 7], [2, 5, 8], [3, 6, 9], [1, 5, 9], [3, 5, 7]]

    /// Cells 1 to 9 from a prop: a list of numbers (the parser always makes one).
    static func cells(_ v: YLValue?) -> [Int] {
        var out: [Int] = []
        for n in v?.array?.compactMap(\.number) ?? [] where n.rounded() == n && (1...9).contains(Int(n)) && !out.contains(Int(n)) {
            out.append(Int(n))
        }
        return out
    }

    /// "x", "o" or "draw" with the winning line, or nil while the game is on.
    static func winner(x: [Int], o: [Int]) -> (mark: String, line: [Int])? {
        for l in lines {
            if l.allSatisfy(x.contains) { return ("x", l) }
            if l.allSatisfy(o.contains) { return ("o", l) }
        }
        return x.count + o.count >= 9 ? ("draw", []) : nil
    }

    /// A fair stand-in opponent for demos: win, block, the middle, a corner, an edge.
    static func reply(mine: [Int], theirs: [Int]) -> Int? {
        let free = (1...9).filter { !mine.contains($0) && !theirs.contains($0) }
        func completes(_ cells: [Int]) -> Int? {
            free.first { c in lines.contains { $0.contains(c) && $0.filter { $0 != c }.allSatisfy(cells.contains) } }
        }
        return completes(mine) ?? completes(theirs) ?? [5, 1, 3, 7, 9, 2, 4, 6, 8].first(where: free.contains)
    }
}

private struct TicTacToeGame: View {
    let c: YLComponent
    /// The person's cells this round, until the props carry them too.
    @State private var mine: [Int] = []
    /// The props when Play again was tapped: ignored until the next patch changes them.
    @State private var stale: [YLValue?]?
    @State private var tapped = 0
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var you: String { c.string("you") == "o" ? "o" : "x" }

    private var board: (x: [Int], o: [Int]) {
        let fresh = stale == nil || stale! != [c.props["x"], c.props["o"]]
        var x = fresh ? TicTacToe.cells(c.props["x"]) : []
        var o = fresh ? TicTacToe.cells(c.props["o"]) : []
        if you == "x" { x += mine.filter { !x.contains($0) } } else { o += mine.filter { !o.contains($0) } }
        o.removeAll(where: x.contains)
        return (x, o)
    }

    var body: some View {
        let s = theme.swatch(scheme)
        let (x, o) = board
        let my = you == "x" ? x : o
        let their = you == "x" ? o : x
        let win = TicTacToe.winner(x: x, o: o)
        let myTurn = win == nil && (c.string("first") == "agent" ? their.count > my.count : my.count == their.count)
        let status = if let w = win?.mark {
            w == "draw" ? "Draw." : w == you ? "You win!" : "The agent wins."
        } else {
            myTurn ? "Your turn" : "Their move…"
        }
        VStack(spacing: theme.spacing.m) {
            GameStatus(text: status, hot: win != nil)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(1...3, id: \.self) { col in
                            let cell = r * 3 + col
                            let mark = x.contains(cell) ? "x" : o.contains(cell) ? "o" : nil
                            cellView(cell, mark: mark, hot: win?.line.contains(cell) == true,
                                     enabled: myTurn && mark == nil && !c.locked, s)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            if win != nil {
                OptionPill(text: "Play again", fill: s.accent, ink: s.onAccent, grow: true) { again() }
                    .accessibilityIdentifier("game-again")
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .sensoryFeedback(trigger: win?.mark) { _, new in
            guard let new else { return nil }
            return new == you ? .success : new == "draw" ? .impact(weight: .medium) : .warning
        }
        .animation(reduceMotion ? nil : theme.spring, value: x + o)
        // A reopened thread: the board the last move sent.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard mine.isEmpty, stale == nil, let v, v["again"] == nil else { return }
            mine = TicTacToe.cells(v[you])
        }
    }

    private func cellView(_ cell: Int, mark: String?, hot: Bool, enabled: Bool, _ s: Swatch) -> some View {
        Button { tap(cell) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.card * 0.7)
                    .fill(hot ? s.accent.opacity(0.22) : s.background)
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.card * 0.7).stroke(s.outline, lineWidth: 1.5))
                if let mark {
                    Image(systemName: mark == "x" ? "xmark" : "circle")
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(mark == "x" ? s.accent : s.ink.opacity(0.75))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(mark.map { "Cell \(cell), \($0.uppercased())" } ?? "Cell \(cell), empty")
        .accessibilityIdentifier("game-cell-\(cell)")
    }

    private func tap(_ cell: Int) {
        let (x, o) = board
        guard !x.contains(cell), !o.contains(cell) else { return }
        mine.append(cell)
        tapped += 1
        let nx = you == "x" ? x + [cell] : x
        let no = you == "o" ? o + [cell] : o
        var v: [String: YLValue] = ["move": .number(Double(cell)), "x": .array(nx.map { .number(Double($0)) }),
                                    "o": .array(no.map { .number(Double($0)) })]
        var echo: String?
        if let w = TicTacToe.winner(x: nx, o: no) {
            v["winner"] = .string(w.mark)
            echo = w.mark == "draw" ? "Tic-tac-toe: a draw." : "Tic-tac-toe: I won!"
        }
        emit(c.game(v, echo: echo))
    }

    private func again() {
        stale = [c.props["x"], c.props["o"]]
        mine = []
        emit(c.game(["again": .bool(true)]))
    }
}

// MARK: - snake

private struct SnakeGame: View {
    let c: YLComponent
    private struct P: Hashable { var x: Int, y: Int }
    private enum Phase { case ready, play, over }
    @State private var snake: [P] = []
    @State private var dir = P(x: 1, y: 0)
    @State private var next = P(x: 1, y: 0)
    @State private var food = P(x: 0, y: 0)
    @State private var score = 0
    @State private var best = 0
    @State private var phase = Phase.ready
    @State private var ate = 0
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var size: Int { c.clampedInt("size", 10...20, 15) }
    private var tick: Duration { .milliseconds([220, 165, 125, 95, 70][c.clampedInt("speed", 1...5, 2) - 1]) }

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(spacing: theme.spacing.m) {
            GameStatus(text: "Score \(score)", trailing: best > 0 ? "Best \(best)" : nil)
            ZStack {
                Canvas { ctx, box in
                    let cell = box.width / CGFloat(size)
                    func rect(_ p: P, inset: CGFloat) -> CGRect {
                        CGRect(x: CGFloat(p.x) * cell, y: CGFloat(p.y) * cell, width: cell, height: cell).insetBy(dx: inset, dy: inset)
                    }
                    ctx.fill(Path(ellipseIn: rect(food, inset: cell * 0.14)), with: .color(s.mint))
                    for (i, p) in snake.enumerated() {
                        ctx.fill(Path(roundedRect: rect(p, inset: 1), cornerRadius: cell * 0.28),
                                 with: .color(i == 0 ? s.accent : s.accent.opacity(0.7)))
                    }
                }
                .background(s.background, in: .rect(cornerRadius: theme.radius.card * 0.7))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card * 0.7).stroke(s.outline, lineWidth: 1.5))
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 14).onEnded { g in
                    let dx = g.translation.width, dy = g.translation.height
                    steer(abs(dx) > abs(dy) ? P(x: dx > 0 ? 1 : -1, y: 0) : P(x: 0, y: dy > 0 ? 1 : -1))
                })
                .accessibilityElement()
                .accessibilityLabel("Snake board, score \(score)")
                .accessibilityIdentifier("snake-board")
                if phase != .play {
                    VStack(spacing: theme.spacing.m) {
                        if phase == .over {
                            Text("Game over · \(score)").font(theme.font(theme.type.title, .heavy)).foregroundStyle(s.ink)
                                .accessibilityIdentifier("snake-over")
                        }
                        OptionPill(text: phase == .over ? "Play again" : "Start", fill: s.accent, ink: s.onAccent) { start() }
                            .accessibilityIdentifier("snake-start")
                    }
                    .padding(theme.spacing.l)
                    .background(s.surface.opacity(0.92), in: .rect(cornerRadius: theme.radius.card))
                }
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            pad(s)
        }
        .onAppear { if snake.isEmpty { reset() }; best = max(best, Int(c.number("best") ?? 0)) }
        .task(id: phase == .play) {
            guard phase == .play else { return }
            while !Task.isCancelled, phase == .play {
                try? await Task.sleep(for: tick)
                if Task.isCancelled { break }
                step()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: ate)
        .sensoryFeedback(.warning, trigger: phase == .over)
    }

    private func pad(_ s: Swatch) -> some View {
        VStack(spacing: 6) {
            key("Up", "chevron.up", P(x: 0, y: -1), s)
            HStack(spacing: 6) {
                key("Left", "chevron.left", P(x: -1, y: 0), s)
                key("Down", "chevron.down", P(x: 0, y: 1), s)
                key("Right", "chevron.right", P(x: 1, y: 0), s)
            }
        }
    }

    private func key(_ label: String, _ sym: String, _ d: P, _ s: Swatch) -> some View {
            Button { steer(d) } label: {
                Image(systemName: sym).font(.system(size: 18, weight: .bold)).foregroundStyle(s.ink)
                    .frame(width: 60, height: 46)
                    .background(s.background, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(s.outline, lineWidth: 1.5))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityLabel(label)
            .accessibilityIdentifier("snake-\(label.lowercased())")
    }

    private func reset() {
        let m = size / 2
        snake = [P(x: m, y: m), P(x: m - 1, y: m), P(x: m - 2, y: m)]
        dir = P(x: 1, y: 0)
        next = dir
        food = P(x: min(size - 2, m + 4), y: m)
        score = 0
    }

    private func start() {
        reset()
        phase = .play
    }

    private func steer(_ d: P) {
        if phase == .ready { phase = .play }
        guard phase == .play else { return }
        next = d
    }

    private func step() {
        let d = next.x == -dir.x && next.y == -dir.y ? dir : next
        dir = d
        let head = P(x: snake[0].x + d.x, y: snake[0].y + d.y)
        let eats = head == food
        let body = eats ? snake : Array(snake.dropLast())
        if head.x < 0 || head.y < 0 || head.x >= size || head.y >= size || body.contains(head) {
            phase = .over
            best = max(best, score)
            emit(c.game(["over": .bool(true), "score": .number(Double(score))], echo: "Snake: \(score)"))
            return
        }
        snake = [head] + body
        if eats {
            score += 1
            ate += 1
            var free: [P] = []
            for y in 0..<size { for x in 0..<size where !snake.contains(P(x: x, y: y)) { free.append(P(x: x, y: y)) } }
            food = free.randomElement() ?? food
        }
    }
}

// MARK: - memory

private struct MemoryGame: View {
    let c: YLComponent
    private struct Card: Identifiable { let id: Int; let face: String }
    @State private var deck: [Card] = []
    @State private var up: [Int] = []
    @State private var got: Set<Int> = []
    @State private var moves = 0
    @State private var started: Date?
    @State private var seconds: Int?
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let faces = ["🍎", "🍋", "🍇", "🍓", "🍒", "🥝", "🍑", "🍍", "🥥", "🍉", "🫐", "🍌"]

    var body: some View {
        let s = theme.swatch(scheme)
        let done = !deck.isEmpty && got.count == deck.count
        let cols = deck.count <= 12 ? 4 : deck.count <= 20 ? 5 : 6
        VStack(spacing: theme.spacing.m) {
            GameStatus(text: done ? "All \(deck.count / 2) pairs in \(moves) moves, \(seconds ?? 0)s." : "Moves \(moves)", hot: done)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                ForEach(Array(deck.enumerated()), id: \.element.id) { i, card in
                    cardView(i, card, shown: up.contains(i) || got.contains(i), matched: got.contains(i), s)
                }
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            if done {
                OptionPill(text: "Play again", fill: s.accent, ink: s.onAccent, grow: true) { deal() }
                    .accessibilityIdentifier("game-again")
            }
        }
        .onAppear { if deck.isEmpty { deal() } }
        .sensoryFeedback(.selection, trigger: up)
        .sensoryFeedback(.success, trigger: got.count)
    }

    private func cardView(_ i: Int, _ card: Card, shown: Bool, matched: Bool, _ s: Swatch) -> some View {
        let word = card.face.count > 2
        return Button { flip(i) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(s.accent)
                    .opacity(shown ? 0 : 1)
                RoundedRectangle(cornerRadius: 12).fill(matched ? s.mint.opacity(0.55) : s.background)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(s.outline, lineWidth: 1.5))
                    .overlay(
                        Text(card.face)
                            .font(word ? theme.font(theme.type.caption, .heavy) : .system(size: 28))
                            .foregroundStyle(s.ink)
                            .minimumScaleFactor(0.6).lineLimit(2).multilineTextAlignment(.center).padding(4)
                    )
                    .opacity(shown ? 1 : 0)
            }
            .aspectRatio(0.78, contentMode: .fit)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8), value: shown)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shown ? card.face : "Hidden card")
        .accessibilityIdentifier("memory-card-\(i)")
    }

    private func deal() {
        let n = c.clampedInt("pairs", 2...12, 6)
        let items = c.strings("items") ?? []
        let faces = Array((items.isEmpty ? Self.faces : items).prefix(n))
        deck = (faces + faces).enumerated().map { Card(id: $0.offset, face: $0.element) }.shuffled()
        #if DEBUG
        // UI tests: -yuiGameSeed keeps the deal in line order so the pairs are known.
        if UserDefaults.standard.bool(forKey: "yuiGameSeed") { deck.sort { $0.id < $1.id } }
        #endif
        up = []; got = []; moves = 0; started = nil; seconds = nil
    }

    private func flip(_ i: Int) {
        guard up.count < 2, !up.contains(i), !got.contains(i), got.count < deck.count else { return }
        if started == nil { started = .now }
        up.append(i)
        guard up.count == 2 else { return }
        moves += 1
        let pair = up
        let match = deck[pair[0]].face == deck[pair[1]].face
        Task {
            try? await Task.sleep(for: .milliseconds(match ? 250 : 800))
            if match { got.formUnion(pair) }
            up = []
            if match, got.count == deck.count {
                let s = Int(Date.now.timeIntervalSince(started ?? .now).rounded())
                seconds = s
                emit(c.game(["over": .bool(true), "moves": .number(Double(moves)), "seconds": .number(Double(s))],
                            echo: "Memory: \(deck.count / 2) pairs in \(moves) moves"))
            }
        }
    }
}
