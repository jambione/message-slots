import Foundation

/// Every tunable number in the game. Nothing about balance is hard-coded in the
/// engine: reel weights, bonus rates, pity thresholds and scoring constants all
/// live here, loadable from JSON so themes, difficulty tiers and post-launch
/// tuning never require a code change (ARCHITECTURE.md §1.3).
public struct EconomyConfig: Codable, Hashable, Sendable {

    // MARK: Table shape

    public var reelCount: Int
    public var triesPerTurn: Int
    public var traySize: Int

    // MARK: Reels

    /// Share of each rarity tier in the draw.
    public var tierShares: [Rarity: Double]

    /// Per-reel part-of-speech weighting. Reels are not identical: the machine
    /// is shaped so a full spin usually offers a subject and a verb
    /// (GAME_DESIGN.md §2.4).
    public var reelRoles: [[PartOfSpeech: Double]]

    // MARK: Bonuses

    /// Probability that a given reel face shows a bonus instead of a word.
    public var bonusRate: Double
    /// Extra multiplier on the bonus rate for the last reel (the "bonus reel").
    public var lastReelBonusMultiplier: Double
    /// Hard cap on bonus faces per spin — bonus-flood turns feel unearned.
    public var maxBonusFacesPerSpin: Int
    public var bonusWeights: [BonusSlot: Double]
    /// Free re-spins granted by Free Spin Frenzy. The UI runs this as a ~15s
    /// window; the engine bounds it by count so a turn can always end.
    public var maxFrenzySpins: Int

    // MARK: Pity

    /// When the tray has no verb and tries remaining drops to this or below,
    /// verbs get boosted. Invisible to the player; feels like luck.
    public var pityVerbTriesThreshold: Int
    public var pityVerbWeightMultiplier: Double
    /// Guarantee that every spin offers at least one noun-capable and one
    /// verb-capable face across the reels that actually spun.
    public var guaranteeSentenceCapableSpin: Bool

    // MARK: Scoring (GAME_DESIGN.md §4.1)

    public var lengthBonusStep: Double        // per word beyond the floor
    public var lengthBonusFloor: Int          // words before length pays
    public var lengthMultiplierCap: Double
    public var grammarValidMultiplier: Double
    public var grammarSaladMultiplier: Double
    public var sentenceStarStep: Double
    public var pointsPerUnusedTry: Int
    public var streakStep: Double
    public var streakMultiplierCap: Double

    public var alliterationBonus: Int
    public var rhymeBonus: Int
    public var allReelsBonus: Int
    public var themeWordBonus: Int
    /// Awarded when the subject and verb are both tagged and compatible
    /// (Language/SemanticCoherence.swift). Additive, like the style bonuses —
    /// never a gate. A grammatical-but-nonsense sentence still scores fully
    /// via grammarValidMultiplier; this only rewards the ones that also make
    /// sense, on top of that.
    public var senseBonus: Int

    // MARK: Story mode (GAME_DESIGN.md §5.1)

    public var callbackBonus: Int
    public var maxCallbacksPerTurn: Int
    public var threadBonus: Int
    public var connectorOpenBonus: Int
    public var chapterCloseBonus: Int
    public var chainStep: Double
    public var chainMultiplierCap: Double
    /// Words already in the story reappear at this weight multiplier, so
    /// callbacks are actually reachable.
    public var storyNounBias: Double
    public var storyConnectorBias: Double

    // MARK: Bonus slots

    public enum BonusSlot: String, Codable, Hashable, Sendable, CaseIterable {
        case wordGem2, wordGem3, sentenceStar, extraTry, frenzy, wildCard, swap, gift, rust
    }

    // MARK: Default table

    /// Shipping defaults, matching the numbers written in GAME_DESIGN.md.
    /// Kept in code (not only JSON) so tests and the simulator have a source of
    /// truth that cannot drift silently.
    public static let `default` = EconomyConfig(
        reelCount: 5,
        triesPerTurn: 5,
        traySize: 10,
        tierShares: [.common: 0.55, .uncommon: 0.30, .rare: 0.12, .legendary: 0.03],
        reelRoles: [
            // Reel 1 — determiners and subjects
            [.article: 4.0, .pronoun: 2.5, .adjective: 1.5, .noun: 2.0, .verb: 0.5, .adverb: 0.4, .conjunction: 0.6, .preposition: 0.5],
            // Reel 2 — description
            [.adjective: 4.0, .noun: 2.0, .adverb: 1.5, .article: 1.0, .verb: 1.0, .pronoun: 0.6, .conjunction: 0.4, .preposition: 0.5],
            // Reel 3 — subjects and objects
            [.noun: 5.0, .adjective: 1.2, .pronoun: 1.0, .verb: 1.2, .article: 0.8, .adverb: 0.5, .conjunction: 0.3, .preposition: 0.5],
            // Reel 4 — action
            [.verb: 5.0, .adverb: 1.6, .noun: 1.2, .adjective: 0.8, .preposition: 0.8, .article: 0.5, .pronoun: 0.4, .conjunction: 0.3],
            // Reel 5 — glue, twists and bonuses
            [.conjunction: 2.6, .preposition: 2.0, .adverb: 1.8, .noun: 1.6, .verb: 1.6, .adjective: 1.4, .article: 1.2, .pronoun: 1.0]
        ],
        bonusRate: 0.08,
        lastReelBonusMultiplier: 2.0,
        maxBonusFacesPerSpin: 2,
        maxFrenzySpins: 12,
        bonusWeights: [
            .wordGem2: 3.0,
            .wordGem3: 1.2,
            .sentenceStar: 1.8,
            .extraTry: 2.2,
            .frenzy: 0.8,
            .wildCard: 1.6,
            .swap: 1.4,
            .gift: 1.6,
            .rust: 1.0
        ],
        pityVerbTriesThreshold: 2,
        pityVerbWeightMultiplier: 3.0,
        guaranteeSentenceCapableSpin: true,
        lengthBonusStep: 0.25,
        lengthBonusFloor: 3,
        lengthMultiplierCap: 3.0,
        grammarValidMultiplier: 2.0,
        grammarSaladMultiplier: 0.25,
        sentenceStarStep: 0.5,
        pointsPerUnusedTry: 10,
        streakStep: 0.1,
        streakMultiplierCap: 2.0,
        alliterationBonus: 15,
        rhymeBonus: 15,
        allReelsBonus: 25,
        themeWordBonus: 10,
        senseBonus: 30,
        callbackBonus: 20,
        maxCallbacksPerTurn: 2,
        threadBonus: 40,
        connectorOpenBonus: 15,
        chapterCloseBonus: 100,
        chainStep: 0.1,
        chainMultiplierCap: 1.5,
        storyNounBias: 3.0,
        storyConnectorBias: 2.0
    )

    /// Difficulty variants. Only the knobs change — never the rules.
    public static var easy: EconomyConfig {
        var c = EconomyConfig.default
        c.triesPerTurn = 6
        c.bonusRate = 0.11
        c.pityVerbTriesThreshold = 3
        return c
    }

    public static var hard: EconomyConfig {
        var c = EconomyConfig.default
        c.triesPerTurn = 4
        c.bonusRate = 0.06
        c.pityVerbTriesThreshold = 1
        return c
    }

    // MARK: Codable with non-string-keyed dictionaries

    private enum CodingKeys: String, CodingKey {
        case reelCount, triesPerTurn, traySize, tierShares, reelRoles
        case bonusRate, lastReelBonusMultiplier, maxBonusFacesPerSpin, bonusWeights, maxFrenzySpins
        case pityVerbTriesThreshold, pityVerbWeightMultiplier, guaranteeSentenceCapableSpin
        case lengthBonusStep, lengthBonusFloor, lengthMultiplierCap
        case grammarValidMultiplier, grammarSaladMultiplier, sentenceStarStep
        case pointsPerUnusedTry, streakStep, streakMultiplierCap
        case alliterationBonus, rhymeBonus, allReelsBonus, themeWordBonus, senseBonus
        case callbackBonus, maxCallbacksPerTurn, threadBonus, connectorOpenBonus
        case chapterCloseBonus, chainStep, chainMultiplierCap
        case storyNounBias, storyConnectorBias
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = EconomyConfig.default

        reelCount = try c.decodeIfPresent(Int.self, forKey: .reelCount) ?? base.reelCount
        triesPerTurn = try c.decodeIfPresent(Int.self, forKey: .triesPerTurn) ?? base.triesPerTurn
        traySize = try c.decodeIfPresent(Int.self, forKey: .traySize) ?? base.traySize

        if let raw = try c.decodeIfPresent([String: Double].self, forKey: .tierShares) {
            tierShares = raw.reduce(into: [:]) { acc, kv in
                if let tier = Rarity(rawValue: kv.key) { acc[tier] = kv.value }
            }
        } else {
            tierShares = base.tierShares
        }

        if let raw = try c.decodeIfPresent([[String: Double]].self, forKey: .reelRoles) {
            reelRoles = raw.map { row in
                row.reduce(into: [PartOfSpeech: Double]()) { acc, kv in
                    if let pos = PartOfSpeech(rawValue: kv.key) { acc[pos] = kv.value }
                }
            }
        } else {
            reelRoles = base.reelRoles
        }

        bonusRate = try c.decodeIfPresent(Double.self, forKey: .bonusRate) ?? base.bonusRate
        lastReelBonusMultiplier = try c.decodeIfPresent(Double.self, forKey: .lastReelBonusMultiplier) ?? base.lastReelBonusMultiplier
        maxBonusFacesPerSpin = try c.decodeIfPresent(Int.self, forKey: .maxBonusFacesPerSpin) ?? base.maxBonusFacesPerSpin
        maxFrenzySpins = try c.decodeIfPresent(Int.self, forKey: .maxFrenzySpins) ?? base.maxFrenzySpins

        if let raw = try c.decodeIfPresent([String: Double].self, forKey: .bonusWeights) {
            bonusWeights = raw.reduce(into: [:]) { acc, kv in
                if let slot = BonusSlot(rawValue: kv.key) { acc[slot] = kv.value }
            }
        } else {
            bonusWeights = base.bonusWeights
        }

        pityVerbTriesThreshold = try c.decodeIfPresent(Int.self, forKey: .pityVerbTriesThreshold) ?? base.pityVerbTriesThreshold
        pityVerbWeightMultiplier = try c.decodeIfPresent(Double.self, forKey: .pityVerbWeightMultiplier) ?? base.pityVerbWeightMultiplier
        guaranteeSentenceCapableSpin = try c.decodeIfPresent(Bool.self, forKey: .guaranteeSentenceCapableSpin) ?? base.guaranteeSentenceCapableSpin

        lengthBonusStep = try c.decodeIfPresent(Double.self, forKey: .lengthBonusStep) ?? base.lengthBonusStep
        lengthBonusFloor = try c.decodeIfPresent(Int.self, forKey: .lengthBonusFloor) ?? base.lengthBonusFloor
        lengthMultiplierCap = try c.decodeIfPresent(Double.self, forKey: .lengthMultiplierCap) ?? base.lengthMultiplierCap
        grammarValidMultiplier = try c.decodeIfPresent(Double.self, forKey: .grammarValidMultiplier) ?? base.grammarValidMultiplier
        grammarSaladMultiplier = try c.decodeIfPresent(Double.self, forKey: .grammarSaladMultiplier) ?? base.grammarSaladMultiplier
        sentenceStarStep = try c.decodeIfPresent(Double.self, forKey: .sentenceStarStep) ?? base.sentenceStarStep
        pointsPerUnusedTry = try c.decodeIfPresent(Int.self, forKey: .pointsPerUnusedTry) ?? base.pointsPerUnusedTry
        streakStep = try c.decodeIfPresent(Double.self, forKey: .streakStep) ?? base.streakStep
        streakMultiplierCap = try c.decodeIfPresent(Double.self, forKey: .streakMultiplierCap) ?? base.streakMultiplierCap

        alliterationBonus = try c.decodeIfPresent(Int.self, forKey: .alliterationBonus) ?? base.alliterationBonus
        rhymeBonus = try c.decodeIfPresent(Int.self, forKey: .rhymeBonus) ?? base.rhymeBonus
        allReelsBonus = try c.decodeIfPresent(Int.self, forKey: .allReelsBonus) ?? base.allReelsBonus
        themeWordBonus = try c.decodeIfPresent(Int.self, forKey: .themeWordBonus) ?? base.themeWordBonus
        senseBonus = try c.decodeIfPresent(Int.self, forKey: .senseBonus) ?? base.senseBonus

        callbackBonus = try c.decodeIfPresent(Int.self, forKey: .callbackBonus) ?? base.callbackBonus
        maxCallbacksPerTurn = try c.decodeIfPresent(Int.self, forKey: .maxCallbacksPerTurn) ?? base.maxCallbacksPerTurn
        threadBonus = try c.decodeIfPresent(Int.self, forKey: .threadBonus) ?? base.threadBonus
        connectorOpenBonus = try c.decodeIfPresent(Int.self, forKey: .connectorOpenBonus) ?? base.connectorOpenBonus
        chapterCloseBonus = try c.decodeIfPresent(Int.self, forKey: .chapterCloseBonus) ?? base.chapterCloseBonus
        chainStep = try c.decodeIfPresent(Double.self, forKey: .chainStep) ?? base.chainStep
        chainMultiplierCap = try c.decodeIfPresent(Double.self, forKey: .chainMultiplierCap) ?? base.chainMultiplierCap
        storyNounBias = try c.decodeIfPresent(Double.self, forKey: .storyNounBias) ?? base.storyNounBias
        storyConnectorBias = try c.decodeIfPresent(Double.self, forKey: .storyConnectorBias) ?? base.storyConnectorBias
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reelCount, forKey: .reelCount)
        try c.encode(triesPerTurn, forKey: .triesPerTurn)
        try c.encode(traySize, forKey: .traySize)
        try c.encode(Dictionary(uniqueKeysWithValues: tierShares.map { ($0.key.rawValue, $0.value) }), forKey: .tierShares)
        try c.encode(reelRoles.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }, forKey: .reelRoles)
        try c.encode(bonusRate, forKey: .bonusRate)
        try c.encode(lastReelBonusMultiplier, forKey: .lastReelBonusMultiplier)
        try c.encode(maxBonusFacesPerSpin, forKey: .maxBonusFacesPerSpin)
        try c.encode(maxFrenzySpins, forKey: .maxFrenzySpins)
        try c.encode(Dictionary(uniqueKeysWithValues: bonusWeights.map { ($0.key.rawValue, $0.value) }), forKey: .bonusWeights)
        try c.encode(pityVerbTriesThreshold, forKey: .pityVerbTriesThreshold)
        try c.encode(pityVerbWeightMultiplier, forKey: .pityVerbWeightMultiplier)
        try c.encode(guaranteeSentenceCapableSpin, forKey: .guaranteeSentenceCapableSpin)
        try c.encode(lengthBonusStep, forKey: .lengthBonusStep)
        try c.encode(lengthBonusFloor, forKey: .lengthBonusFloor)
        try c.encode(lengthMultiplierCap, forKey: .lengthMultiplierCap)
        try c.encode(grammarValidMultiplier, forKey: .grammarValidMultiplier)
        try c.encode(grammarSaladMultiplier, forKey: .grammarSaladMultiplier)
        try c.encode(sentenceStarStep, forKey: .sentenceStarStep)
        try c.encode(pointsPerUnusedTry, forKey: .pointsPerUnusedTry)
        try c.encode(streakStep, forKey: .streakStep)
        try c.encode(streakMultiplierCap, forKey: .streakMultiplierCap)
        try c.encode(alliterationBonus, forKey: .alliterationBonus)
        try c.encode(rhymeBonus, forKey: .rhymeBonus)
        try c.encode(allReelsBonus, forKey: .allReelsBonus)
        try c.encode(themeWordBonus, forKey: .themeWordBonus)
        try c.encode(senseBonus, forKey: .senseBonus)
        try c.encode(callbackBonus, forKey: .callbackBonus)
        try c.encode(maxCallbacksPerTurn, forKey: .maxCallbacksPerTurn)
        try c.encode(threadBonus, forKey: .threadBonus)
        try c.encode(connectorOpenBonus, forKey: .connectorOpenBonus)
        try c.encode(chapterCloseBonus, forKey: .chapterCloseBonus)
        try c.encode(chainStep, forKey: .chainStep)
        try c.encode(chainMultiplierCap, forKey: .chainMultiplierCap)
        try c.encode(storyNounBias, forKey: .storyNounBias)
        try c.encode(storyConnectorBias, forKey: .storyConnectorBias)
    }

    public init(
        reelCount: Int, triesPerTurn: Int, traySize: Int,
        tierShares: [Rarity: Double], reelRoles: [[PartOfSpeech: Double]],
        bonusRate: Double, lastReelBonusMultiplier: Double, maxBonusFacesPerSpin: Int,
        maxFrenzySpins: Int, bonusWeights: [BonusSlot: Double],
        pityVerbTriesThreshold: Int, pityVerbWeightMultiplier: Double, guaranteeSentenceCapableSpin: Bool,
        lengthBonusStep: Double, lengthBonusFloor: Int, lengthMultiplierCap: Double,
        grammarValidMultiplier: Double, grammarSaladMultiplier: Double, sentenceStarStep: Double,
        pointsPerUnusedTry: Int, streakStep: Double, streakMultiplierCap: Double,
        alliterationBonus: Int, rhymeBonus: Int, allReelsBonus: Int, themeWordBonus: Int, senseBonus: Int,
        callbackBonus: Int, maxCallbacksPerTurn: Int, threadBonus: Int, connectorOpenBonus: Int,
        chapterCloseBonus: Int, chainStep: Double, chainMultiplierCap: Double,
        storyNounBias: Double, storyConnectorBias: Double
    ) {
        self.reelCount = reelCount
        self.triesPerTurn = triesPerTurn
        self.traySize = traySize
        self.tierShares = tierShares
        self.reelRoles = reelRoles
        self.bonusRate = bonusRate
        self.lastReelBonusMultiplier = lastReelBonusMultiplier
        self.maxBonusFacesPerSpin = maxBonusFacesPerSpin
        self.maxFrenzySpins = maxFrenzySpins
        self.bonusWeights = bonusWeights
        self.pityVerbTriesThreshold = pityVerbTriesThreshold
        self.pityVerbWeightMultiplier = pityVerbWeightMultiplier
        self.guaranteeSentenceCapableSpin = guaranteeSentenceCapableSpin
        self.lengthBonusStep = lengthBonusStep
        self.lengthBonusFloor = lengthBonusFloor
        self.lengthMultiplierCap = lengthMultiplierCap
        self.grammarValidMultiplier = grammarValidMultiplier
        self.grammarSaladMultiplier = grammarSaladMultiplier
        self.sentenceStarStep = sentenceStarStep
        self.pointsPerUnusedTry = pointsPerUnusedTry
        self.streakStep = streakStep
        self.streakMultiplierCap = streakMultiplierCap
        self.alliterationBonus = alliterationBonus
        self.rhymeBonus = rhymeBonus
        self.allReelsBonus = allReelsBonus
        self.themeWordBonus = themeWordBonus
        self.senseBonus = senseBonus
        self.callbackBonus = callbackBonus
        self.maxCallbacksPerTurn = maxCallbacksPerTurn
        self.threadBonus = threadBonus
        self.connectorOpenBonus = connectorOpenBonus
        self.chapterCloseBonus = chapterCloseBonus
        self.chainStep = chainStep
        self.chainMultiplierCap = chainMultiplierCap
        self.storyNounBias = storyNounBias
        self.storyConnectorBias = storyConnectorBias
    }
}
