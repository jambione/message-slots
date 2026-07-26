import Foundation

/// Every tunable number in the game. Nothing about balance is hard-coded in the
/// engine: draw weights, bonus rates and scoring constants all live here,
/// loadable from JSON so difficulty tiers and post-launch tuning never require
/// a code change (ARCHITECTURE.md §1.3).
///
/// Far smaller than its sentence-era predecessor: the reel-role matrix, tier
/// shares and pity thresholds are all gone, replaced by the Scrabble letter
/// distribution and a single category-bias knob.
public struct EconomyConfig: Codable, Hashable, Sendable {

    // MARK: Structure

    public var reelCount: Int
    /// Spins per turn. Three, not five — a shorter turn keeps the arc tight and
    /// makes each spin a real decision rather than one of a comfortable five.
    public var triesPerTurn: Int
    /// Hard cap on banked letters.
    public var trayCapacity: Int
    /// Shortest submittable word.
    public var minimumWordLength: Int

    // MARK: Letter draw

    /// How strongly reels favour letters that complete a word in the active
    /// category.
    ///
    /// This is the single most important number in the game. Because the
    /// category gates submission, drawing uniformly from the Scrabble bag
    /// produces dead turns constantly — measured at only 13% of random racks
    /// being able to spell *any* musical instrument. A weight of 1.0 is pure
    /// Scrabble randomness; higher values quietly tilt the machine toward
    /// letters the player can actually use.
    ///
    /// The player should never perceive this as help. They should just feel
    /// lucky — the same principle the old design's verb pity system worked on,
    /// except here it is the primary mechanism rather than a safety net.
    public var categoryBias: Double
    /// Guarantee at least one vowel across the reels on every spin. A rack with
    /// no vowel is unspellable regardless of category.
    public var guaranteeVowel: Bool
    /// Guarantee the letters on offer can complete at least one category word.
    public var guaranteeSolvableSpin: Bool

    // MARK: Bonuses

    /// Probability that a reel face shows a bonus instead of a letter.
    public var bonusRate: Double
    /// Extra multiplier on the bonus rate for the last reel.
    public var lastReelBonusMultiplier: Double
    /// Hard cap on bonus faces per spin — bonus-flood turns feel unearned.
    public var maxBonusFacesPerSpin: Int
    /// Keyed by `BonusSlot.rawValue` so the JSON stays readable.
    public var bonusWeights: [String: Double]
    /// Free re-spins granted by Frenzy, bounded so a turn can always end.
    public var maxFrenzySpins: Int

    // MARK: Scoring

    /// Word length beyond which the length bonus starts accruing.
    public var lengthBonusFloor: Int
    /// Multiplied by the *square* of letters over the floor, so long words
    /// escalate rather than creep.
    public var lengthBonusStep: Int
    public var pointsPerUnusedTry: Int
    public var streakStep: Double
    public var streakMultiplierCap: Double

    public var fullRackBonus: Int
    public var pureWordBonus: Int
    /// Minimum length for the no-blanks bonus to count.
    public var pureWordFloor: Int
    public var heavyLetterBonus: Int

    // MARK: Presets

    public static let `default` = EconomyConfig(
        reelCount: 5,
        triesPerTurn: 3,
        trayCapacity: 10,
        minimumWordLength: 3,
        categoryBias: 3.5,
        guaranteeVowel: true,
        guaranteeSolvableSpin: true,
        bonusRate: 0.09,
        lastReelBonusMultiplier: 2.0,
        maxBonusFacesPerSpin: 2,
        bonusWeights: [
            BonusSlot.letterGem2.rawValue: 3.0,
            BonusSlot.letterGem3.rawValue: 1.2,
            BonusSlot.wordGem2.rawValue:   1.6,
            BonusSlot.extraTry.rawValue:   2.2,
            BonusSlot.frenzy.rawValue:     0.8,
            BonusSlot.blank.rawValue:      1.8,
            BonusSlot.swap.rawValue:       1.4,
            BonusSlot.gift.rawValue:       1.6
        ],
        maxFrenzySpins: 12,
        lengthBonusFloor: 3,
        lengthBonusStep: 4,
        pointsPerUnusedTry: 8,
        streakStep: 0.1,
        streakMultiplierCap: 2.0,
        fullRackBonus: 25,
        pureWordBonus: 12,
        pureWordFloor: 5,
        heavyLetterBonus: 10
    )

    /// Gentler: an extra try and a heavier thumb on the scale.
    public static var easy: EconomyConfig {
        var config = EconomyConfig.default
        config.triesPerTurn = 4
        config.categoryBias = 5.0
        config.bonusRate = 0.12
        return config
    }

    /// Closer to honest Scrabble randomness.
    public static var hard: EconomyConfig {
        var config = EconomyConfig.default
        config.triesPerTurn = 2
        config.categoryBias = 1.8
        config.bonusRate = 0.07
        config.guaranteeSolvableSpin = false
        return config
    }

    public func weight(for slot: BonusSlot) -> Double {
        bonusWeights[slot.rawValue] ?? 0
    }
}
