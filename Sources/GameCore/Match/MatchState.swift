import Foundation

/// A finished turn, in the form that makes remote play work: the seed and the
/// action list are enough for any device to reconstruct the turn exactly — for
/// verification, and for the "watch what your teammate did" replay.
public struct CompletedTurn: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let playerID: String
    public let playerName: String
    public let seed: UInt64
    public let actions: [TurnAction]
    public let giftsReceived: [BonusKind]
    public let sentence: String
    public let words: [String]
    public let breakdown: ScoreBreakdown
    /// Optional language-model flavour award, computed once on the author's
    /// device and carried along (never recomputed — see SentenceJudge).
    public var verdict: JudgeVerdict?

    public var score: Int { breakdown.total + (verdict?.awardPoints ?? 0) }

    public init(
        id: Int, playerID: String, playerName: String, seed: UInt64,
        actions: [TurnAction], giftsReceived: [BonusKind] = [],
        sentence: String, words: [String], breakdown: ScoreBreakdown,
        verdict: JudgeVerdict? = nil
    ) {
        self.id = id
        self.playerID = playerID
        self.playerName = playerName
        self.seed = seed
        self.actions = actions
        self.giftsReceived = giftsReceived
        self.sentence = sentence
        self.words = words
        self.breakdown = breakdown
        self.verdict = verdict
    }
}

/// Everything a match needs to survive a device change, an app relaunch, or a
/// week between turns.
public struct MatchState: Codable, Hashable, Sendable {
    public var mode: GameMode
    public var connectivity: Connectivity
    public var players: [Player]
    public var currentPlayerIndex: Int
    public var teamBank: Int
    public var teamStreak: Int
    public var roundIndex: Int
    public var turnsPerRound: Int
    public var turnsTakenThisRound: Int
    public var targetScore: Int?
    public var themeTag: String?
    public var story: Story?
    public var history: [CompletedTurn]
    /// Gifts waiting for each player, keyed by player id.
    public var pendingGifts: [String: [BonusKind]]
    /// Seed source for future turns, so the whole match is reproducible.
    public var matchRNG: SeededRNG

    public var currentPlayer: Player { players[currentPlayerIndex] }
    public var isComplete: Bool {
        if let target = targetScore { return teamBank >= target || roundIndex > 3 }
        return roundIndex > 3
    }

    public init(
        mode: GameMode,
        connectivity: Connectivity = .localDevice,
        players: [Player],
        targetScore: Int? = nil,
        themeTag: String? = nil,
        story: Story? = nil,
        seed: UInt64
    ) {
        self.mode = mode
        self.connectivity = connectivity
        self.players = players
        self.currentPlayerIndex = 0
        self.teamBank = 0
        self.teamStreak = 0
        self.roundIndex = 1
        self.turnsPerRound = max(2, players.count * 2)
        self.turnsTakenThisRound = 0
        self.targetScore = targetScore
        self.themeTag = themeTag
        self.story = story
        self.history = []
        self.pendingGifts = [:]
        self.matchRNG = SeededRNG(seed: seed)
    }
}

/// Drives a match across turns: hands out seeds, applies results to the shared
/// bank, moves gifts between players, and advances the story.
///
/// Deliberately transport-agnostic. Pass-and-play, remote async and same-room
/// live all call exactly these methods; only the delivery of `CompletedTurn`
/// differs (ARCHITECTURE.md §9).
public struct MatchEngine: Sendable {
    public let reducer: TurnReducer

    public init(reducer: TurnReducer) { self.reducer = reducer }

    public var config: EconomyConfig { reducer.config }

    /// Context for the player whose turn it is.
    public func context(for match: MatchState) -> TurnContext {
        TurnContext(
            mode: match.mode,
            story: match.story,
            teamStreak: match.teamStreak,
            themeTag: match.themeTag,
            isFinalTurnOfChapter: match.turnsTakenThisRound == match.turnsPerRound - 1
        )
    }

    /// Begin the current player's turn, consuming a match-level seed so the
    /// sequence of turns is itself reproducible.
    public func beginTurn(_ match: inout MatchState) -> TurnState {
        let player = match.currentPlayer
        let seed = match.matchRNG.next()
        let gifts = match.pendingGifts[player.id] ?? []
        match.pendingGifts[player.id] = []
        return reducer.startTurn(playerID: player.id, seed: seed, gifts: gifts)
    }

    /// Fold a locked turn into the match: bank the score, roll the streak,
    /// extend the story, pass gifts, and advance to the next player.
    @discardableResult
    public func completeTurn(
        _ match: inout MatchState,
        state: TurnState,
        breakdown: ScoreBreakdown,
        verdict: JudgeVerdict? = nil
    ) -> CompletedTurn {
        let player = match.currentPlayer
        let sentence = Sentence.text(from: state.tray)

        let completed = CompletedTurn(
            id: match.history.count,
            playerID: player.id,
            playerName: player.name,
            seed: state.rng.seed,
            actions: state.actionLog,
            giftsReceived: state.receivedGifts,
            sentence: sentence,
            words: state.tray.map(\.entry.text),
            breakdown: breakdown,
            verdict: verdict
        )

        match.history.append(completed)
        match.teamBank += completed.score

        // The streak is shared: a teammate's rough turn is everyone's problem,
        // which is precisely what makes people coach each other.
        match.teamStreak = breakdown.isValidSentence ? match.teamStreak + 1 : 0

        // Gifts land on the *next* player, at boosted potency.
        let giftCount = state.heldBonuses.filter { $0 == .gift }.count
        if giftCount > 0 {
            let recipient = match.players[(match.currentPlayerIndex + 1) % match.players.count]
            var giftRNG = match.matchRNG
            for _ in 0..<giftCount {
                match.pendingGifts[recipient.id, default: []].append(MatchEngine.boostedGift(rng: &giftRNG))
            }
            match.matchRNG = giftRNG
        }

        // Story Mode: append the sentence and roll continuity forward.
        if match.mode.usesStory, var story = match.story {
            let entry = StorySentence(
                id: story.sentences.count,
                text: sentence,
                words: completed.words,
                authorID: player.id,
                authorName: player.name,
                score: completed.score
            )
            story.append(entry, entries: state.trayEntries, carriedContinuity: breakdown.combo.carriedContinuity)
            match.story = story
        }

        advance(&match)
        return completed
    }

    private func advance(_ match: inout MatchState) {
        match.turnsTakenThisRound += 1
        match.currentPlayerIndex = (match.currentPlayerIndex + 1) % match.players.count

        guard match.turnsTakenThisRound >= match.turnsPerRound else { return }
        match.turnsTakenThisRound = 0
        match.roundIndex += 1

        if match.mode.usesStory, var story = match.story {
            var rng = match.matchRNG
            let next = MatchEngine.drawEndingWord(pool: reducer.pool, rng: &rng) ?? story.endingWord
            match.matchRNG = rng
            story.closeChapter(nextEndingWord: next)
            match.story = story
        }
    }

    /// Gifting is intentionally the mathematically-correct warm fuzzy: what you
    /// pass along arrives stronger than if you had kept it.
    static func boostedGift(rng: inout SeededRNG) -> BonusKind {
        let options: [BonusKind] = [.wordGem(multiplier: 3), .sentenceStar, .extraTry, .extraTry]
        return rng.pick(options) ?? .extraTry
    }

    public static func drawEndingWord(pool: WordPool, rng: inout SeededRNG) -> String? {
        let candidates = pool.words(tagged: "ending")
        return rng.pick(candidates.isEmpty ? pool.words.filter(\.isNounCapable) : candidates)?.text
    }

    // MARK: Remote play

    /// Re-runs an incoming turn from `(seed, actions)` and reports whether the
    /// score matches what the sender claimed. No server needed: every device is
    /// its own referee (ARCHITECTURE.md §9.1).
    public func verify(_ turn: CompletedTurn, context: TurnContext) -> Bool {
        let (state, _) = reducer.replay(
            seed: turn.seed,
            playerID: turn.playerID,
            actions: turn.actions,
            gifts: turn.giftsReceived,
            context: context
        )
        guard state.phase == .locked else { return false }
        let validation = reducer.validator.validate(state.tray)
        let combo = context.mode.usesStory
            ? reducer.combos.detect(tray: state.tray, story: context.story, isFinalTurnOfChapter: context.isFinalTurnOfChapter)
            : ComboResult()
        let recomputed = reducer.scorer.score(
            tray: state.tray,
            context: ScoreCalculator.Context(
                validation: validation,
                triesRemaining: state.triesRemaining,
                sentenceStars: state.sentenceStars,
                teamStreak: context.teamStreak,
                themeTag: context.themeTag,
                openingReelWords: state.openingReelWords,
                reelCount: config.reelCount,
                combo: combo
            )
        )
        return recomputed.total == turn.breakdown.total
    }
}

// MARK: - Transport

/// What arrives from another device.
public enum MatchUpdate: Sendable {
    case turnReceived(MatchState, CompletedTurn)
    case stateSynced(MatchState)
    case reaction(playerID: String, emoji: String)
    case peerJoined(Player)
    case peerLeft(Player)
}

/// How turns move between phones. `GameCore` never knows which one is in use, so
/// a match can start as pass-and-play and finish as remote async without the
/// rules changing (GAME_DESIGN.md §5.2).
public protocol MatchTransport: Sendable {
    func send(state: MatchState, turn: CompletedTurn) async throws
    func send(reaction: String, from playerID: String) async throws
    var incoming: AsyncStream<MatchUpdate> { get }
}

/// Everyone on one phone. No delivery required.
public struct LocalTransport: MatchTransport {
    public init() {}
    public func send(state: MatchState, turn: CompletedTurn) async throws {}
    public func send(reaction: String, from playerID: String) async throws {}
    public var incoming: AsyncStream<MatchUpdate> { AsyncStream { $0.finish() } }
}
