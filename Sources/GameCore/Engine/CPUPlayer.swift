import Foundation

/// A CPU teammate.
///
/// Plays by exactly the same rules as a person: it emits `TurnAction`s into the
/// same reducer, so its turn is recorded, replayable and verifiable like any
/// other. Nothing is fabricated behind the scenes — the bot cannot see the RNG,
/// re-roll a spin, or score points a human could not have scored.
///
/// Used for: solo play, filling an empty seat, keeping a match alive when a
/// friend drops out mid-game, the tutorial's demo turn, and driving the headless
/// balance simulator.
public struct CPUPlayer: Sendable {
    public let skill: CPUSkill
    public let reducer: TurnReducer

    public init(skill: CPUSkill = .steady, reducer: TurnReducer) {
        self.skill = skill
        self.reducer = reducer
    }

    /// Safety valve: no bot turn may exceed this many actions.
    public static let maxActionsPerTurn = 60

    // MARK: Decision

    /// The single next action the bot wants to take, or nil when it is done.
    public func nextAction(for state: TurnState, context: TurnContext) -> TurnAction? {
        guard state.phase != .locked else { return nil }
        if state.phase == .ready { return .spin }

        // 1. Free value first: collect bonus tokens sitting on the reels.
        if let reel = bonusReelWorthTaking(state) { return .bank(reel: reel) }

        // 2. Fill the holes the sentence needs (a subject, then a verb).
        if let reel = reelSatisfyingMissingCategory(state) { return .bank(reel: reel) }

        // 3. Bank words that are good enough to spend a slot on.
        if let reel = reelWorthBanking(state) { return .bank(reel: reel) }

        // 4. Arrange the tray into its best order before judging it.
        if let move = improvingReorder(state) { return move }

        // 5. Spin again if that is still allowed and worthwhile.
        if shouldSpinAgain(state) { return .spin }

        // 6. Otherwise commit.
        return state.canLockIn ? .lockIn : (state.canSpin ? .spin : nil)
    }

    /// Plays a whole turn to completion, returning the final state and the score.
    public func playTurn(_ start: TurnState, context: TurnContext) -> (TurnState, ScoreBreakdown?) {
        var state = start
        var breakdown: ScoreBreakdown?

        for _ in 0..<CPUPlayer.maxActionsPerTurn {
            guard let action = nextAction(for: state, context: context) else { break }
            let (next, effects) = reducer.reduce(state, action, context: context)

            // A rejected action means the bot's model of the turn is stale;
            // stop rather than spin forever.
            if effects.contains(where: { if case .rejected = $0 { return true }; return false }),
               next.tray.count == state.tray.count, next.triesRemaining == state.triesRemaining {
                if state.canLockIn, breakdown == nil {
                    let (locked, lockEffects) = reducer.reduce(state, .lockIn, context: context)
                    state = locked
                    breakdown = lockEffects.compactMap { if case .sentenceLocked(let b) = $0 { return b }; return nil }.first
                }
                break
            }

            state = next
            if let found = effects.compactMap({ if case .sentenceLocked(let b) = $0 { return b }; return nil }).first {
                breakdown = found
                break
            }
        }
        return (state, breakdown)
    }

    // MARK: Heuristics

    private func bonusReelWorthTaking(_ state: TurnState) -> Int? {
        for (index, reel) in state.reels.enumerated() {
            guard case .bonus(let kind)? = reel.token else { continue }
            switch kind {
            case .rust(_, let remaining):
                // Take a rust word once it has decayed to roughly what a normal
                // word is worth, or immediately if there is room and it is rich.
                if remaining >= skill.greedThreshold + 2, state.tray.count < reducer.config.traySize { return index }
            case .wildCard, .swap, .gift, .frenzy:
                return index          // held bonuses cost nothing to collect
            case .wordGem, .sentenceStar, .extraTry:
                return index          // always worth taking
            }
        }
        return nil
    }

    /// Every unbanked reel showing a word, as (reel index, word).
    private func availableWords(_ state: TurnState) -> [(reel: Int, word: WordEntry)] {
        state.reels.indices.compactMap { index in
            let reel = state.reels[index]
            guard let word = reel.token?.word else { return nil }
            return (index, word)
        }
    }

    /// The bot's first duty is a legal sentence: a subject, then an action.
    private func reelSatisfyingMissingCategory(_ state: TurnState) -> Int? {
        guard state.tray.count < reducer.config.traySize else { return nil }
        for needed in state.missingCategories {
            let matches = availableWords(state).filter { candidate in
                needed == .noun ? candidate.word.isNounCapable : candidate.word.can(be: needed)
            }
            // Take the most valuable option for the role.
            if let best = matches.max(by: { $0.word.effectivePoints < $1.word.effectivePoints }) {
                return best.reel
            }
        }
        return nil
    }

    private func reelWorthBanking(_ state: TurnState) -> Int? {
        guard state.tray.count < min(skill.targetLength, reducer.config.traySize) else { return nil }

        let trayIsValid = reducer.validator.validate(state.tray).isValid
        // Only extend once the sentence already works; otherwise the bot risks
        // filling the tray with adjectives and no verb.
        guard trayIsValid || state.tray.count < 2 else { return nil }

        // Late in the turn the bot lowers its standards — the same nerve a human loses.
        let threshold = state.triesRemaining <= 1 ? 1 : skill.greedThreshold
        let worthy = availableWords(state).filter { $0.word.effectivePoints >= threshold }
        guard let best = worthy.max(by: { $0.word.effectivePoints < $1.word.effectivePoints }) else { return nil }

        // Adding a word must not break a sentence that already works — but the
        // bot, like a person, may slot it anywhere in the tray rather than only
        // on the end. It banks now and tidies the order on the next step.
        if trayIsValid, !anyInsertionKeepsSentenceValid(tray: state.tray, adding: best.word) {
            return nil
        }
        return best.reel
    }

    private func anyInsertionKeepsSentenceValid(tray: [PlacedWord], adding word: WordEntry) -> Bool {
        let candidate = PlacedWord(id: -1, entry: word)
        for position in 0...tray.count {
            var probe = tray
            probe.insert(candidate, at: position)
            if reducer.validator.validate(probe).isValid { return true }
        }
        return false
    }

    /// One-swap improvement search: if moving a word makes an invalid tray valid,
    /// do it. Humans do this by dragging; the bot does it by looking.
    private func improvingReorder(_ state: TurnState) -> TurnAction? {
        guard state.tray.count >= 2, !reducer.validator.validate(state.tray).isValid else { return nil }
        for from in state.tray.indices {
            for to in state.tray.indices where to != from {
                var probe = state.tray
                let word = probe.remove(at: from)
                probe.insert(word, at: to)
                if reducer.validator.validate(probe).isValid {
                    return .reorder(from: from, to: to)
                }
            }
        }
        return nil
    }

    private func shouldSpinAgain(_ state: TurnState) -> Bool {
        guard state.canSpin, state.triesRemaining > 0 else { return false }
        // Always spin while the sentence is not yet legal.
        if !reducer.validator.validate(state.tray).isValid { return true }
        // Otherwise keep going only while short of the target length.
        return state.tray.count < skill.targetLength
    }
}

// MARK: - Match integration

public extension MatchEngine {
    /// Runs the current player's whole turn on the CPU and folds it into the match.
    /// Returns nil when the current player is human.
    @discardableResult
    func playCPUTurn(_ match: inout MatchState) -> CompletedTurn? {
        guard case .cpu(let skill) = match.currentPlayer.kind else { return nil }
        let bot = CPUPlayer(skill: skill, reducer: reducer)
        let turnContext = self.context(for: match)
        let start = beginTurn(&match)
        let (finished, breakdown) = bot.playTurn(start, context: turnContext)
        guard let breakdown else { return nil }
        return completeTurn(&match, state: finished, breakdown: breakdown)
    }
}
