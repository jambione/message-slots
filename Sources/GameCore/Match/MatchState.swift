import Foundation

/// A finished turn, in the form that makes remote play work: the seed and the
/// action list are enough for any device to reconstruct the turn exactly — for
/// verification, and for the "watch what your teammate did" replay.
public struct CompletedTurn: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var playerID: String
    public var playerName: String
    public var categoryID: String
    public var categoryName: String
    public var word: String
    public var breakdown: ScoreBreakdown
    public var seed: UInt64
    public var actions: [TurnAction]

    public init(
        id: UUID = UUID(),
        playerID: String,
        playerName: String,
        categoryID: String,
        categoryName: String,
        word: String,
        breakdown: ScoreBreakdown,
        seed: UInt64,
        actions: [TurnAction]
    ) {
        self.id = id
        self.playerID = playerID
        self.playerName = playerName
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.word = word
        self.breakdown = breakdown
        self.seed = seed
        self.actions = actions
    }

    public var score: Int { breakdown.total }
}

/// Everything shared across a match.
public struct MatchState: Codable, Hashable, Sendable {
    public var mode: GameMode
    public var connectivity: Connectivity
    public var players: [Player]
    public var currentPlayerIndex: Int

    /// Every player's score pools here. There is no individual leaderboard in
    /// co-op modes — a weak turn by your friend is your problem too, which is
    /// the whole social loop.
    public var teamBank: Int
    public var targetScore: Int
    /// Shared across the team, broken by any turn that fails to submit a word.
    public var teamStreak: Int
    public var roundIndex: Int

    /// The category for the turn in progress.
    public var currentCategoryID: String
    /// Recently used categories, so a match doesn't repeat itself immediately.
    public var recentCategoryIDs: [String]

    public var turnHistory: [CompletedTurn]
    /// Bonuses queued for the next player by a Gift token.
    public var pendingGifts: [String: [BonusKind]]

    public var seed: UInt64

    public init(
        mode: GameMode = .passAndPlay,
        connectivity: Connectivity = .localDevice,
        players: [Player],
        targetScore: Int = 400,
        seed: UInt64
    ) {
        self.mode = mode
        self.connectivity = connectivity
        self.players = players
        self.currentPlayerIndex = 0
        self.teamBank = 0
        self.targetScore = targetScore
        self.teamStreak = 0
        self.roundIndex = 0
        self.currentCategoryID = ""
        self.recentCategoryIDs = []
        self.turnHistory = []
        self.pendingGifts = [:]
        self.seed = seed
    }

    public var currentPlayer: Player { players[currentPlayerIndex % players.count] }
    public var isComplete: Bool { teamBank >= targetScore }
}

// MARK: - Engine

/// Drives the turn lifecycle: choosing a category, beginning a turn, banking
/// the score, passing the phone.
public struct MatchEngine: Sendable {
    public let reducer: TurnReducer
    public let pack: CategoryPack

    public init(reducer: TurnReducer, pack: CategoryPack) {
        self.reducer = reducer
        self.pack = pack
    }

    /// Category for the turn about to start, drawn deterministically so a
    /// replayed match picks the same one.
    public func drawCategory(_ match: inout MatchState) -> WordCategory {
        var rng = SeededRNG(seed: match.seed &+ UInt64(match.turnHistory.count) &* 0x9E37_79B9)
        let recent = Set(match.recentCategoryIDs.suffix(3))
        let category = pack.draw(using: &rng, excluding: recent)
            ?? pack.categories.first!
        match.currentCategoryID = category.id
        match.recentCategoryIDs.append(category.id)
        return category
    }

    public func category(for match: MatchState) -> WordCategory {
        pack.category(id: match.currentCategoryID) ?? pack.categories.first!
    }

    public func context(for match: MatchState) -> TurnContext {
        TurnContext(mode: match.mode, teamStreak: match.teamStreak, category: category(for: match))
    }

    /// Starts the next player's turn.
    public func beginTurn(_ match: inout MatchState) -> TurnState {
        let category = drawCategory(&match)
        let player = match.currentPlayer

        var state = TurnState(
            playerID: player.id,
            categoryID: category.id,
            categoryName: category.name,
            config: reducer.config,
            rng: SeededRNG(seed: match.seed &+ UInt64(match.turnHistory.count &+ 1) &* 0x2545_F491)
        )

        // Gifts a teammate sent arrive before the first spin.
        if let gifts = match.pendingGifts[player.id], !gifts.isEmpty {
            state.receivedGifts = gifts
            for gift in gifts {
                switch gift {
                case .extraTry: state.triesRemaining += 1
                case .letterGem(let m): state.pendingLetterGem = max(state.pendingLetterGem ?? 1, m)
                case .wordGem(let m): state.wordMultiplier *= m
                default: state.heldBonuses.append(gift)
                }
            }
            match.pendingGifts[player.id] = []
        }

        return state
    }

    /// Banks a finished turn and advances to the next player.
    @discardableResult
    public func completeTurn(
        _ match: inout MatchState,
        state: TurnState,
        breakdown: ScoreBreakdown
    ) -> CompletedTurn {
        let player = match.currentPlayer

        let turn = CompletedTurn(
            playerID: player.id,
            playerName: player.name,
            categoryID: state.categoryID,
            categoryName: state.categoryName,
            word: breakdown.word,
            breakdown: breakdown,
            seed: state.rng.seed,
            actions: state.actionLog
        )

        match.teamBank += breakdown.total
        match.teamStreak = breakdown.total > 0 ? match.teamStreak + 1 : 0
        match.turnHistory.append(turn)

        // Gift tokens still held at lock-in pass to the next player, boosted.
        let nextIndex = (match.currentPlayerIndex + 1) % match.players.count
        let nextPlayer = match.players[nextIndex]
        let giftCount = state.heldBonuses.filter { $0 == .gift }.count
        if giftCount > 0 {
            var queue = match.pendingGifts[nextPlayer.id] ?? []
            for _ in 0..<giftCount { queue.append(.letterGem(multiplier: 3)) }
            match.pendingGifts[nextPlayer.id] = queue
        }

        match.currentPlayerIndex = nextIndex
        if nextIndex == 0 { match.roundIndex += 1 }
        return turn
    }

    /// Re-runs a turn from `(seed, actions)` and returns the score it produces.
    ///
    /// This is what makes remote play cheat-resistant without a server: the
    /// receiving device recomputes rather than trusting the number it was sent.
    public func verify(_ turn: CompletedTurn, category: WordCategory, teamStreak: Int) -> Int? {
        var state = TurnState(
            playerID: turn.playerID,
            categoryID: turn.categoryID,
            categoryName: turn.categoryName,
            config: reducer.config,
            rng: SeededRNG(seed: turn.seed)
        )
        let context = TurnContext(teamStreak: teamStreak, category: category)

        var breakdown: ScoreBreakdown?
        for action in turn.actions {
            let (next, effects) = reducer.reduce(state, action, context: context)
            state = next
            for effect in effects {
                if case .wordLocked(let result) = effect { breakdown = result }
            }
        }
        return breakdown?.total
    }
}

// MARK: - Transport

/// `GameCore` never knows how bytes move. Multiplayer implements this one
/// protocol three ways (local, Game Center async, same-room multipeer).
public protocol MatchTransport: Sendable {
    func send(_ state: MatchState, turn: CompletedTurn) async throws
    var incoming: AsyncStream<MatchUpdate> { get }
}

public struct MatchUpdate: Sendable {
    public let state: MatchState
    public let turn: CompletedTurn?

    public init(state: MatchState, turn: CompletedTurn?) {
        self.state = state
        self.turn = turn
    }
}

/// Pass-and-play on a single device.
public final class LocalTransport: MatchTransport, @unchecked Sendable {
    private var continuation: AsyncStream<MatchUpdate>.Continuation?
    public let incoming: AsyncStream<MatchUpdate>

    public init() {
        var captured: AsyncStream<MatchUpdate>.Continuation?
        incoming = AsyncStream { captured = $0 }
        continuation = captured
    }

    public func send(_ state: MatchState, turn: CompletedTurn) async throws {
        continuation?.yield(MatchUpdate(state: state, turn: turn))
    }
}
