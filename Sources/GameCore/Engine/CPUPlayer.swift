import Foundation

/// A CPU teammate.
///
/// Plays by exactly the same rules as a person: it emits `TurnAction`s into the
/// same reducer, so its turn is recorded, replayable and verifiable like any
/// other. It never sees the RNG, never re-rolls, and never scores by a
/// different formula. That matters for trust as much as for architecture — the
/// moment a player suspects their teammate isn't playing fair, the cooperative
/// framing collapses.
///
/// Skill is expressed as *patience and ambition*, never privilege.
public struct CPUPlayer: Sendable {
    public let skill: CPUSkill
    public let config: EconomyConfig

    public init(skill: CPUSkill, config: EconomyConfig = .default) {
        self.skill = skill
        self.config = config
    }

    /// Chooses the next action, or nil when it wants to stop.
    public func nextAction(for state: TurnState, context: TurnContext) -> TurnAction? {
        guard state.phase != .locked else { return nil }

        // Opening move.
        if state.phase == .ready { return .spin }

        let scorer = ScoreCalculator(config: config)
        let banked = state.tray.map(\.tile.letter)

        // Grab any bonus sitting on a reel — free value, no downside.
        if let bonusReel = state.reels.indices.first(where: { state.reels[$0].isBonus }) {
            return .bank(reel: bonusReel)
        }

        // What's the best word reachable from everything visible right now?
        let visible = state.availableLetters
        let blanks = state.heldBonuses.filter { $0 == .blank }.count
        let candidates = context.category.words(spellableFrom: visible, blanks: blanks)

        guard !candidates.isEmpty else {
            // Nothing reachable. Spin if we can, otherwise submit whatever we
            // have and take the consolation.
            return state.canSpin ? .spin : (state.tray.isEmpty ? nil : .lockIn)
        }

        let target = bestWord(candidates, visible: visible, scorer: scorer, state: state, context: context)

        // Already spelling it? Lock in — but only if we're content with it.
        if state.word == target {
            let score = projectedScore(for: state, scorer: scorer, context: context)
            let wantsMore = state.canSpin
                && state.tray.count < skill.targetLength
                && score < skill.greedThreshold
            return wantsMore ? .spin : .lockIn
        }

        // Drop letters that aren't in the target word, cheapest first.
        if let stray = strayTrayIndex(target: target, tray: state.tray) {
            return .removeFromTray(index: stray)
        }

        // Bank the next letter the target needs.
        if let reel = reelSupplying(nextLetterOf: target, state: state) {
            return .bank(reel: reel)
        }

        // The target needs a letter we can't see. Spin for it, or settle.
        if state.canSpin { return .spin }
        return state.word.count >= config.minimumWordLength && context.category.accepts(state.word)
            ? .lockIn
            : (state.tray.isEmpty ? nil : .lockIn)
    }

    // MARK: Choosing a word

    /// Picks the highest-scoring reachable word the skill level will commit to.
    ///
    /// Rookie takes the first thing that works — fast, chaotic, fun to watch.
    /// Sharp holds out for length and heavy letters.
    private func bestWord(
        _ candidates: [String],
        visible: [Character],
        scorer: ScoreCalculator,
        state: TurnState,
        context: TurnContext
    ) -> String {
        // Sorted for determinism: a replayed CPU turn must choose identically.
        let ordered = candidates.sorted()

        switch skill {
        case .rookie:
            return ordered.min { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
            } ?? ordered[0]

        case .steady, .sharp:
            return ordered.max { lhs, rhs in
                let l = wordValue(lhs), r = wordValue(rhs)
                return l == r ? lhs > rhs : l < r
            } ?? ordered[0]
        }
    }

    /// Rough value of a word, used only for the bot's own comparisons.
    private func wordValue(_ word: String) -> Int {
        let letters = word.reduce(0) { $0 + LetterTile.value(of: $1) }
        let over = max(0, word.count - config.lengthBonusFloor)
        return letters + over * over * config.lengthBonusStep
    }

    private func projectedScore(
        for state: TurnState,
        scorer: ScoreCalculator,
        context: TurnContext
    ) -> Int {
        scorer.score(
            tray: state.tray,
            context: .init(
                triesRemaining: state.triesRemaining,
                teamStreak: context.teamStreak,
                wordMultiplier: state.wordMultiplier,
                openingLetters: Array(state.openingLetters),
                reelCount: config.reelCount
            )
        ).total
    }

    // MARK: Tray management

    /// A banked letter the target word doesn't need, if any.
    private func strayTrayIndex(target: String, tray: [PlacedLetter]) -> Int? {
        var need: [Character: Int] = [:]
        for character in target { need[character, default: 0] += 1 }

        for (index, placed) in tray.enumerated() {
            let letter = placed.tile.letter
            if let count = need[letter], count > 0 {
                need[letter] = count - 1
            } else {
                return index
            }
        }
        return nil
    }

    /// The reel holding the next letter the target word still needs.
    private func reelSupplying(nextLetterOf target: String, state: TurnState) -> Int? {
        var need: [Character: Int] = [:]
        for character in target { need[character, default: 0] += 1 }
        for placed in state.tray {
            if let count = need[placed.tile.letter], count > 0 {
                need[placed.tile.letter] = count - 1
            }
        }
        let wanted = need.filter { $0.value > 0 }.keys
        guard !wanted.isEmpty else { return nil }

        // Deterministic: lowest reel index wins.
        return state.reels.indices.first { index in
            guard let tile = state.reels[index].tile else { return false }
            return wanted.contains(tile.letter)
        }
    }
}

// MARK: - Playing a whole CPU turn

public extension MatchEngine {
    /// Runs a CPU turn to completion, returning the final state and every
    /// effect it produced so the UI can play the turn back at human pace.
    func playCPUTurn(
        _ match: inout MatchState,
        skill: CPUSkill,
        maxActions: Int = 60
    ) -> (TurnState, [Effect], ScoreBreakdown?) {
        var state = beginTurn(&match)
        let turnContext = context(for: match)
        let bot = CPUPlayer(skill: skill, config: reducer.config)

        var effects: [Effect] = []
        var breakdown: ScoreBreakdown?

        for _ in 0..<maxActions {
            guard let action = bot.nextAction(for: state, context: turnContext) else { break }
            let (next, produced) = reducer.reduce(state, action, context: turnContext)
            state = next
            effects.append(contentsOf: produced)
            for effect in produced {
                if case .wordLocked(let result) = effect { breakdown = result }
            }
            if state.phase == .locked { break }
        }

        return (state, effects, breakdown)
    }
}
