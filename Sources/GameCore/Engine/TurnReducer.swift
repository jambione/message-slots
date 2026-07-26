import Foundation

/// Everything outside the turn that the reducer needs in order to spin fairly
/// and score correctly.
public struct TurnContext: Sendable {
    public var mode: GameMode
    public var story: Story?
    public var teamStreak: Int
    public var themeTag: String?
    public var isFinalTurnOfChapter: Bool

    public init(
        mode: GameMode = .passAndPlay,
        story: Story? = nil,
        teamStreak: Int = 0,
        themeTag: String? = nil,
        isFinalTurnOfChapter: Bool = false
    ) {
        self.mode = mode
        self.story = story
        self.teamStreak = teamStreak
        self.themeTag = themeTag
        self.isFinalTurnOfChapter = isFinalTurnOfChapter
    }
}

/// The pure heart of the game.
///
/// `reduce` is the only way turn state changes: same state plus same action
/// always yields the same next state and the same effects. Score animations,
/// teammate-turn replay, remote-play verification and bug repro all ride on that
/// one property (ARCHITECTURE.md §4).
public struct TurnReducer: Sendable {
    public let config: EconomyConfig
    public let pool: WordPool
    public let resolver: SpinResolver
    public let validator: SentenceValidator
    public let scorer: ScoreCalculator
    public let combos: ComboDetector

    public init(config: EconomyConfig = .default, pool: WordPool, validator: SentenceValidator = SentenceValidator()) {
        self.config = config
        self.pool = pool
        self.resolver = SpinResolver(config: config, pool: pool)
        self.validator = validator
        self.scorer = ScoreCalculator(config: config)
        self.combos = ComboDetector(config: config)
    }

    // MARK: Turn lifecycle

    /// Fresh turn, with any gifts from a teammate already applied — generosity
    /// should be the first thing you see.
    public func startTurn(
        playerID: String,
        seed: UInt64,
        gifts: [BonusKind] = []
    ) -> TurnState {
        var state = TurnState(playerID: playerID, reelCount: config.reelCount, tries: config.triesPerTurn, seed: seed)
        state.receivedGifts = gifts
        var ignored: [Effect] = []
        for gift in gifts { apply(bonus: gift, to: &state, effects: &ignored) }
        return state
    }

    // MARK: Reduce

    public func reduce(_ state: TurnState, _ action: TurnAction, context: TurnContext = TurnContext()) -> (TurnState, [Effect]) {
        var state = state
        var effects: [Effect] = []

        guard state.phase != .locked else {
            return (state, [.rejected(.turnAlreadyLocked)])
        }
        state.actionLog.append(action)

        switch action {
        case .spin:
            performSpin(&state, context: context, effects: &effects)

        case .bank(let reel):
            bank(reel: reel, &state, effects: &effects)

        case .reorder(let from, let to):
            guard state.tray.indices.contains(from), to >= 0, to <= state.tray.count else {
                return reject(.invalidIndex, &state, effects)
            }
            let word = state.tray.remove(at: from)
            state.tray.insert(word, at: min(to, state.tray.count))
            effects.append(.trayChanged)

        case .removeFromTray(let index):
            removeFromTray(index: index, &state, effects: &effects)

        case .useSwap(let trayIndex):
            useSwap(trayIndex: trayIndex, &state, context: context, effects: &effects)

        case .playWildCard(let word):
            playWildCard(word, &state, effects: &effects)

        case .startFrenzy(let reel):
            guard let heldIndex = state.heldBonuses.firstIndex(of: .frenzy) else {
                return reject(.reelNotReady, &state, effects)
            }
            guard state.reels.indices.contains(reel), state.reels[reel].isSpinnable else {
                return reject(.reelNotReady, &state, effects)
            }
            state.heldBonuses.remove(at: heldIndex)
            state.frenzyReel = reel
            state.frenzySpinsUsed = 0
            effects.append(.frenzyStarted(reel: reel))

        case .endFrenzy:
            state.frenzyReel = nil
            state.frenzySpinsUsed = 0
            effects.append(.frenzyEnded)

        case .lockIn:
            return lockIn(state, context: context, extraEffects: effects)
        }

        if state.phase != .locked {
            effects.append(.validityChanged(validator.validate(state.tray)))
        }
        return (state, effects)
    }

    // MARK: Spin

    private func performSpin(_ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        let inFrenzy = state.frenzyReel != nil
        guard state.triesRemaining > 0 || inFrenzy else {
            effects.append(.rejected(.noTriesLeft))
            return
        }

        // A frenzy spins only its own reel, and costs nothing.
        let spinning: [Int]
        if let frenzyReel = state.frenzyReel {
            // Frenzy is free but finite — otherwise a turn need never end.
            guard state.frenzySpinsUsed < config.maxFrenzySpins else {
                state.frenzyReel = nil
                state.frenzySpinsUsed = 0
                effects.append(.frenzyEnded)
                return
            }
            spinning = state.reels[frenzyReel].isSpinnable ? [frenzyReel] : []
            state.frenzySpinsUsed += 1
        } else {
            // Every reel churns except rust, which holds its face — that is the
            // whole tension: it sits there tempting you while its value bleeds.
            spinning = state.reels.indices.filter { state.reels[$0].isSpinnable }
            state.triesRemaining -= 1
        }

        guard !spinning.isEmpty else {
            effects.append(.rejected(.reelNotReady))
            return
        }

        // Rust decays for every spin the player waits.
        decayRust(&state, effects: &effects)

        let held = Set(state.reels.indices
            .filter { !spinning.contains($0) }
            .compactMap { state.reels[$0].token?.word?.text })

        let spinContext = SpinContext(
            trayEntries: state.trayEntries,
            triesRemaining: state.triesRemaining,
            story: context.mode.usesStory ? context.story : nil,
            themeTag: context.themeTag,
            excludedWords: held.union(Set(state.trayEntries.map(\.text)))
        )

        let forceEnding = context.isFinalTurnOfChapter && state.triesRemaining <= 1
        let (faces, diagnostics) = resolver.spin(
            reels: spinning,
            context: spinContext,
            rng: &state.rng,
            forceEndingWord: forceEnding
        )

        for (reel, token) in faces {
            state.reels[reel] = ReelFace(token: token)
        }
        state.diagnostics.append(diagnostics)
        state.phase = .playing

        if state.openingReelWords.isEmpty {
            state.openingReelWords = Set(state.reels.compactMap(\.token?.word?.text))
        }

        effects.append(.reelsSpun(spinning.sorted()))
    }

    private func decayRust(_ state: inout TurnState, effects: inout [Effect]) {
        for index in state.reels.indices {
            guard case .bonus(.rust(let entry, let remaining)) = state.reels[index].token else { continue }
            let next = max(1, remaining - 2)
            state.reels[index].token = .bonus(.rust(entry: entry, remainingValue: next))
            state.reels[index].rustDecayApplied += 1
            effects.append(.rustDecayed(word: entry.text, remaining: next))
        }
    }

    // MARK: Banking

    private func bank(reel: Int, _ state: inout TurnState, effects: inout [Effect]) {
        guard state.reels.indices.contains(reel) else {
            effects.append(.rejected(.invalidIndex)); return
        }
        guard let token = state.reels[reel].token else {
            effects.append(.rejected(.reelNotReady)); return
        }

        switch token {
        case .word(let entry):
            guard state.tray.count < config.traySize else {
                effects.append(.rejected(.trayFull)); return
            }
            place(entry, from: reel, &state, effects: &effects)
            // The word is safe in the tray; the face empties and will refill on
            // the next spin.
            state.reels[reel] = ReelFace()

        case .bonus(.rust(let entry, let remaining)):
            guard state.tray.count < config.traySize else {
                effects.append(.rejected(.trayFull)); return
            }
            // Rust banks as a word at its decayed value.
            let decayed = WordEntry(text: entry.text, pos: entry.pos, tier: entry.tier, points: remaining, tags: entry.tags)
            place(decayed, from: reel, &state, effects: &effects)
            state.reels[reel] = ReelFace()

        case .bonus(let kind):
            apply(bonus: kind, to: &state, effects: &effects)
            // Collected bonuses free the reel to spin again.
            state.reels[reel] = ReelFace()
            effects.append(.bonusCollected(kind))
        }
    }

    /// Pulls a word back out of the tray. Arranging your sentence is always
    /// free — the bet in this game is the *spin* (new words cost a try), never
    /// where you put a word you already have. So the word returns to its
    /// origin reel whenever that's still possible: nothing has replaced it,
    /// and it wasn't conjured by a Wild Card. No resource is ever refunded —
    /// a gem or Wild Card spent to place it is still spent. If the reel has
    /// moved on since (the player already spun), the word is simply gone;
    /// that's the one case where removal has a real cost, exactly because it
    /// would otherwise buy a free re-look at an already-passed spin.
    private func removeFromTray(index: Int, _ state: inout TurnState, effects: inout [Effect]) {
        guard state.tray.indices.contains(index) else {
            effects.append(.rejected(.invalidIndex)); return
        }
        let removed = state.tray.remove(at: index)

        if !removed.isWild, let reel = removed.sourceReel,
           state.reels.indices.contains(reel), state.reels[reel].isEmpty {
            state.reels[reel] = ReelFace(token: .word(removed.entry))
            effects.append(.wordReturnedToReel(reel: reel, word: removed.entry.text))
        } else {
            effects.append(.wordDiscarded(word: removed.entry.text))
        }
        effects.append(.trayChanged)
    }

    private func place(_ entry: WordEntry, from reel: Int?, _ state: inout TurnState, effects: inout [Effect]) {
        let gem = state.pendingGem ?? 1
        let placed = PlacedWord(
            id: state.takeWordID(),
            entry: entry,
            gemMultiplier: gem,
            isWild: reel == nil,
            sourceReel: reel
        )
        state.tray.append(placed)
        if gem > 1 {
            effects.append(.gemAttached(multiplier: gem, word: entry.text))
            state.pendingGem = nil
        }
        effects.append(.wordBanked(trayIndex: state.tray.count - 1, fromReel: reel ?? -1))
    }

    /// Applies a bonus's immediate consequence.
    private func apply(bonus: BonusKind, to state: inout TurnState, effects: inout [Effect]) {
        switch bonus {
        case .wordGem(let multiplier):
            // Gems stack multiplicatively if two are collected before banking.
            state.pendingGem = (state.pendingGem ?? 1) * multiplier
        case .sentenceStar:
            state.sentenceStars += 1
        case .extraTry:
            state.triesRemaining += 1
            effects.append(.tryGranted(remaining: state.triesRemaining))
        case .frenzy, .wildCard, .swap, .gift:
            state.heldBonuses.append(bonus)
        case .rust:
            break  // handled at bank time
        }
    }

    // MARK: Held bonuses

    private func useSwap(trayIndex: Int, _ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        guard let heldIndex = state.heldBonuses.firstIndex(of: .swap) else {
            effects.append(.rejected(.noSwapHeld)); return
        }
        guard state.tray.indices.contains(trayIndex) else {
            effects.append(.rejected(.invalidIndex)); return
        }
        let removed = state.tray.remove(at: trayIndex)
        state.heldBonuses.remove(at: heldIndex)

        // Free re-spin of the reel the word came from.
        if let reel = removed.sourceReel, state.reels.indices.contains(reel) {
            state.reels[reel] = ReelFace()
            let spinContext = SpinContext(
                trayEntries: state.trayEntries,
                triesRemaining: state.triesRemaining,
                story: context.mode.usesStory ? context.story : nil,
                themeTag: context.themeTag,
                // Explicitly exclude the word just handed back: swapping a word
                // only to be shown the same word again is infuriating.
                excludedWords: state.wordsOnTable
                    .union(state.trayEntries.map(\.text))
                    .union([removed.entry.text])
            )
            let (faces, diagnostics) = resolver.spin(reels: [reel], context: spinContext, rng: &state.rng)
            if let token = faces[reel] { state.reels[reel] = ReelFace(token: token) }
            state.diagnostics.append(diagnostics)
            effects.append(.reelsSpun([reel]))
        }
        effects.append(.trayChanged)
    }

    private func playWildCard(_ word: String, _ state: inout TurnState, effects: inout [Effect]) {
        guard let heldIndex = state.heldBonuses.firstIndex(of: .wildCard) else {
            effects.append(.rejected(.noWildCardHeld)); return
        }
        guard state.tray.count < config.traySize else {
            effects.append(.rejected(.trayFull)); return
        }
        // A wild must still be a real word from the loaded pool, so the sentence
        // grammar has categories to work with and the content stays family safe.
        guard let entry = pool.entry(for: word.lowercased()) else {
            effects.append(.rejected(.notAWord)); return
        }
        state.heldBonuses.remove(at: heldIndex)
        let wild = WordEntry(text: entry.text, pos: entry.pos, tier: entry.tier, points: 3, tags: entry.tags)
        place(wild, from: nil, &state, effects: &effects)
    }

    // MARK: Lock in

    private func lockIn(_ state: TurnState, context: TurnContext, extraEffects: [Effect]) -> (TurnState, [Effect]) {
        var state = state
        var effects = extraEffects

        guard state.tray.count >= 2 else {
            effects.append(.rejected(.needTwoWords))
            return (state, effects)
        }

        let validation = validator.validate(state.tray)
        let combo = context.mode.usesStory
            ? combos.detect(tray: state.tray, story: context.story, isFinalTurnOfChapter: context.isFinalTurnOfChapter)
            : ComboResult()

        let breakdown = scorer.score(
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

        state.phase = .locked
        effects.append(.sentenceLocked(breakdown))
        return (state, effects)
    }

    private func reject(_ reason: Effect.Rejection, _ state: inout TurnState, _ effects: [Effect]) -> (TurnState, [Effect]) {
        (state, effects + [.rejected(reason)])
    }

    // MARK: Replay

    /// Re-runs a recorded turn. Used for the teammate-turn replay in remote play
    /// and for verifying an incoming turn's score without trusting the sender.
    public func replay(seed: UInt64, playerID: String, actions: [TurnAction], gifts: [BonusKind] = [], context: TurnContext = TurnContext()) -> (TurnState, [[Effect]]) {
        var state = startTurn(playerID: playerID, seed: seed, gifts: gifts)
        var frames: [[Effect]] = []
        for action in actions {
            let (next, effects) = reduce(state, action, context: context)
            state = next
            frames.append(effects)
        }
        return (state, frames)
    }
}
