import Foundation

/// What the resolver needs to know about the turn in order to shape a fair spin.
public struct SpinContext: Sendable {
    public var trayEntries: [WordEntry]
    public var triesRemaining: Int
    public var story: Story?
    public var themeTag: String?
    /// Words visible on reels that are not spinning, so a spin never duplicates
    /// what is already on the table.
    public var excludedWords: Set<String>

    public init(
        trayEntries: [WordEntry] = [],
        triesRemaining: Int = 5,
        story: Story? = nil,
        themeTag: String? = nil,
        excludedWords: Set<String> = []
    ) {
        self.trayEntries = trayEntries
        self.triesRemaining = triesRemaining
        self.story = story
        self.themeTag = themeTag
        self.excludedWords = excludedWords
    }

    var trayHasVerb: Bool { trayEntries.contains(where: \.isVerbCapable) }
    var trayHasNoun: Bool { trayEntries.contains(where: \.isNounCapable) }
}

/// Diagnostics for telemetry and the balance simulator. Never shown to players —
/// pity should feel like luck (GAME_DESIGN.md §2.4).
public struct SpinDiagnostics: Codable, Hashable, Sendable {
    public var verbPityApplied = false
    public var guaranteeRepairApplied = false
    public var endingWordInjected = false
}

/// Turns randomness into reel faces. All rolls draw from the turn's `SeededRNG`
/// in a fixed order, so the same seed and actions always produce the same table.
public struct SpinResolver: Sendable {
    public let config: EconomyConfig
    public let pool: WordPool

    public init(config: EconomyConfig, pool: WordPool) {
        self.config = config
        self.pool = pool
    }

    /// Resolve faces for the given reel indices.
    public func spin(
        reels: [Int],
        context: SpinContext,
        rng: inout SeededRNG,
        forceEndingWord: Bool = false
    ) -> (faces: [Int: Token], diagnostics: SpinDiagnostics) {
        var diagnostics = SpinDiagnostics()
        var faces: [Int: Token] = [:]
        var used = context.excludedWords
        var bonusesPlaced = 0

        let pityActive = !context.trayHasVerb && context.triesRemaining <= config.pityVerbTriesThreshold
        diagnostics.verbPityApplied = pityActive

        for reel in reels.sorted() {
            var rate = config.bonusRate
            if reel == config.reelCount - 1 { rate *= config.lastReelBonusMultiplier }

            if bonusesPlaced < config.maxBonusFacesPerSpin, rng.chance(rate) {
                if let bonus = rollBonus(rng: &rng, used: &used) {
                    faces[reel] = .bonus(bonus)
                    bonusesPlaced += 1
                    continue
                }
            }

            if let entry = drawWord(reel: reel, context: context, pityActive: pityActive, used: used, rng: &rng) {
                used.insert(entry.text)
                faces[reel] = .word(entry)
            }
        }

        // Story Mode: the chapter's ending word must be reachable on the final turn.
        if forceEndingWord, let story = context.story,
           let ending = pool.entry(for: story.endingWord),
           !used.contains(ending.text),
           !context.trayEntries.contains(where: { $0.text == ending.text }) {
            let wordReels = faces.filter { !$0.value.isBonus }.keys.sorted()
            if let target = rng.pick(wordReels.isEmpty ? reels.sorted() : wordReels) {
                faces[target] = .word(ending)
                diagnostics.endingWordInjected = true
            }
        }

        // Guarantee: a spin should always offer a way forward. If the table (tray
        // plus this spin) still cannot make a sentence, repair one face.
        if config.guaranteeSentenceCapableSpin {
            let repaired = repairIfDeadEnd(faces: &faces, reels: reels, context: context, rng: &rng)
            diagnostics.guaranteeRepairApplied = repaired
        }

        return (faces, diagnostics)
    }

    // MARK: Word draw

    private func drawWord(
        reel: Int,
        context: SpinContext,
        pityActive: Bool,
        used: Set<String>,
        rng: inout SeededRNG
    ) -> WordEntry? {
        let tier = rollTier(rng: &rng)
        let pos = rollPOS(reel: reel, pityActive: pityActive, context: context, rng: &rng)

        // Preferred draw, then progressively looser fallbacks so a thin corner of
        // the pool can never produce an empty reel face.
        let attempts: [[WordEntry]] = [
            pool.candidates(tier: tier, pos: pos),
            Rarity.allCases.flatMap { pool.candidates(tier: $0, pos: pos) },
            pool.words
        ]

        for candidates in attempts {
            let available = candidates.filter { !used.contains($0.text) }
            guard !available.isEmpty else { continue }
            let weights = available.map { weight(for: $0, context: context) }
            if let pick = rng.pick(available, weights: weights) { return pick }
        }
        return nil
    }

    private func rollTier(rng: inout SeededRNG) -> Rarity {
        let tiers = Rarity.allCases
        let weights = tiers.map { config.tierShares[$0] ?? 0 }
        return rng.pick(tiers, weights: weights) ?? .common
    }

    private func rollPOS(
        reel: Int,
        pityActive: Bool,
        context: SpinContext,
        rng: inout SeededRNG
    ) -> PartOfSpeech {
        let roleIndex = min(reel, config.reelRoles.count - 1)
        let role = config.reelRoles[max(0, roleIndex)]
        var parts: [PartOfSpeech] = []
        var weights: [Double] = []

        for pos in PartOfSpeech.allCases {
            var w = role[pos] ?? 0
            guard w > 0 else { continue }
            if pityActive && pos == .verb { w *= config.pityVerbWeightMultiplier }
            // Story Mode leans the machine toward callbacks and connectives.
            if context.story != nil {
                if pos == .conjunction { w *= config.storyConnectorBias }
            }
            parts.append(pos)
            weights.append(w)
        }
        return rng.pick(parts, weights: weights) ?? .noun
    }

    /// Per-word weighting on top of the part-of-speech roll.
    private func weight(for entry: WordEntry, context: SpinContext) -> Double {
        // Authored frequency. Rarity sets a word's value; this sets how often it
        // turns up, which for function words is a completely separate question —
        // "the" and "a" are worth almost nothing and needed constantly.
        var w = entry.weight
        if let story = context.story, entry.isNounCapable, story.knownNouns.contains(entry.text) {
            // Nouns already in the story resurface more often so callbacks are
            // actually landable rather than a lottery.
            w *= config.storyNounBias
        }
        if let theme = context.themeTag, entry.tags.contains(theme) {
            w *= 2.0
        }
        return w
    }

    // MARK: Bonus draw

    private func rollBonus(rng: inout SeededRNG, used: inout Set<String>) -> BonusKind? {
        let slots = Array(config.bonusWeights.keys).sorted { $0.rawValue < $1.rawValue }
        let weights = slots.map { config.bonusWeights[$0] ?? 0 }
        guard let slot = rng.pick(slots, weights: weights) else { return nil }

        switch slot {
        case .wordGem2: return .wordGem(multiplier: 2)
        case .wordGem3: return .wordGem(multiplier: 3)
        case .sentenceStar: return .sentenceStar
        case .extraTry: return .extraTry
        case .frenzy: return .frenzy
        case .wildCard: return .wildCard
        case .swap: return .swap
        case .gift: return .gift
        case .rust:
            let juicy = pool.words.filter { ($0.tier == .rare || $0.tier == .legendary) && !used.contains($0.text) }
            guard let entry = rng.pick(juicy) else { return .wordGem(multiplier: 2) }
            used.insert(entry.text)
            return .rust(entry: entry, remainingValue: entry.effectivePoints)
        }
    }

    // MARK: Dead-end repair

    /// Ensures the player can always reach a subject and a verb. Considers what
    /// is already banked — a tray with a verb does not need another one.
    private func repairIfDeadEnd(
        faces: inout [Int: Token],
        reels: [Int],
        context: SpinContext,
        rng: inout SeededRNG
    ) -> Bool {
        var repaired = false
        // Reels already used to fix one role must not be sacrificed to fix the
        // other — otherwise the noun repair overwrites the verb we just placed.
        var protectedReels = Set<Int>()

        func satisfy(_ needed: PartOfSpeech, alreadyInTray: Bool) {
            // Recomputed each call: a repair for one role may have supplied the other.
            let spunWords = faces.values.compactMap(\.word)
            let present = spunWords.contains { $0.can(be: needed) }
                || (needed == .noun && spunWords.contains(where: \.isNounCapable))
            guard !alreadyInTray, !present else { return }

            // Overwrite the least useful face: an empty one first, then a plain
            // word reel. Never destroy a bonus the player is about to enjoy.
            let available = reels.filter { !protectedReels.contains($0) }
            let empties = available.filter { faces[$0] == nil }
            let plainWords = available.filter { faces[$0]?.isBonus == false }
            guard let reel = empties.last ?? plainWords.last ?? available.last else { return }

            let used = Set(faces.values.compactMap(\.word?.text))
            let options = Rarity.allCases
                .flatMap { pool.candidates(tier: $0, pos: needed) }
                .filter { !used.contains($0.text) && !context.excludedWords.contains($0.text) }
            guard let replacement = rng.pick(options) else { return }
            faces[reel] = .word(replacement)
            protectedReels.insert(reel)
            repaired = true
        }

        satisfy(.verb, alreadyInTray: context.trayHasVerb)
        satisfy(.noun, alreadyInTray: context.trayHasNoun)
        return repaired
    }
}
