import Foundation

/// Every line the score-reveal animation shows, in the order it reveals them.
///
/// Keeping the breakdown as data rather than a single Int is what lets the UI
/// animate an honest, auditable tally instead of a made-up one. With Scrabble
/// values the player can now check the arithmetic themselves, so the sheet has
/// to be exactly right — there is no hiding behind opaque word values any more.
public struct ScoreBreakdown: Codable, Hashable, Sendable {
    public var word = ""
    public var letters: [LetterScore] = []
    public var letterPoints = 0

    public var length = 0
    public var lengthBonus = 0

    public var wordMultiplier = 1

    public var styleBonuses: [StyleBonus] = []
    public var styleBonusPoints = 0

    public var triesRemaining = 0
    public var tryBonusPoints = 0

    public var teamStreak = 0
    public var streakMultiplier = 1.0

    public var total = 0

    public struct LetterScore: Codable, Hashable, Sendable {
        public let letter: String
        public let base: Int
        public let multiplier: Int
        public var value: Int { base * multiplier }
    }

    public struct StyleBonus: Codable, Hashable, Sendable {
        public let name: String
        public let points: Int
        public let detail: String?
    }
}

public struct ScoreCalculator: Sendable {
    public let config: EconomyConfig

    public init(config: EconomyConfig) { self.config = config }

    /// Context the scorer needs beyond the tray itself.
    public struct Context: Sendable {
        public var triesRemaining: Int
        public var teamStreak: Int
        public var wordMultiplier: Int
        /// Letters shown on the opening spin, for the "used the whole rack" bonus.
        public var openingLetters: [Character]
        public var reelCount: Int

        public init(
            triesRemaining: Int,
            teamStreak: Int = 0,
            wordMultiplier: Int = 1,
            openingLetters: [Character] = [],
            reelCount: Int = 5
        ) {
            self.triesRemaining = triesRemaining
            self.teamStreak = teamStreak
            self.wordMultiplier = wordMultiplier
            self.openingLetters = openingLetters
            self.reelCount = reelCount
        }
    }

    /// The formula:
    ///
    ///     turn = (letterPoints × wordM + lengthBonus + styleB + tryB) × streakM
    ///
    /// Letter points come straight from the Scrabble table, so a player who
    /// knows the game can predict a score before submitting. That predictability
    /// is a real part of the appeal and worth protecting in any future tuning —
    /// it's the thing the old opaque per-word point values never had.
    public func score(tray: [PlacedLetter], context: Context) -> ScoreBreakdown {
        var b = ScoreBreakdown()
        guard !tray.isEmpty else { return b }

        b.word = String(tray.map(\.tile.letter))

        for placed in tray {
            b.letters.append(.init(
                letter: String(placed.tile.letter),
                base: placed.tile.value,
                multiplier: placed.multiplier
            ))
        }
        b.letterPoints = b.letters.reduce(0) { $0 + $1.value }

        // Length, escalating rather than linear: stretching from four letters
        // to six should be worth more than two average tiles, or the safe short
        // word is almost always correct and the turn loses its arc.
        b.length = tray.count
        let over = max(0, tray.count - config.lengthBonusFloor)
        b.lengthBonus = over * over * config.lengthBonusStep

        b.wordMultiplier = context.wordMultiplier

        b.styleBonuses = styleBonuses(tray: tray, context: context)
        b.styleBonusPoints = b.styleBonuses.reduce(0) { $0 + $1.points }

        // Unused tries. Deliberately modest against one more good letter so
        // "should I stop?" stays a real question — and with only three tries,
        // each is worth proportionally more than it was with five.
        b.triesRemaining = context.triesRemaining
        b.tryBonusPoints = context.triesRemaining * config.pointsPerUnusedTry

        b.teamStreak = context.teamStreak
        b.streakMultiplier = min(
            1.0 + config.streakStep * Double(context.teamStreak),
            config.streakMultiplierCap
        )

        let core = Double(b.letterPoints * b.wordMultiplier)
            + Double(b.lengthBonus)
            + Double(b.styleBonusPoints)
            + Double(b.tryBonusPoints)

        b.total = Int((core * b.streakMultiplier).rounded())
        return b
    }

    // MARK: Style bonuses

    private func styleBonuses(tray: [PlacedLetter], context: Context) -> [ScoreBreakdown.StyleBonus] {
        var bonuses: [ScoreBreakdown.StyleBonus] = []

        // Used every letter from the opening spin.
        if !context.openingLetters.isEmpty, context.openingLetters.count >= context.reelCount {
            var remaining: [Character: Int] = [:]
            for letter in context.openingLetters { remaining[letter, default: 0] += 1 }
            for placed in tray {
                if let count = remaining[placed.tile.letter], count > 0 {
                    remaining[placed.tile.letter] = count - 1
                }
            }
            if remaining.values.allSatisfy({ $0 == 0 }) {
                bonuses.append(.init(
                    name: "Full Rack",
                    points: config.fullRackBonus,
                    detail: "used all \(context.reelCount) opening letters"
                ))
            }
        }

        // A long word with no blanks. Blanks score zero, so building length out
        // of real tiles is a harder feat and worth marking separately.
        if tray.count >= config.pureWordFloor, tray.allSatisfy({ !$0.isBlank }) {
            bonuses.append(.init(name: "All Real Tiles", points: config.pureWordBonus, detail: "no blanks"))
        }

        // The four 8–10 pointers already pay through the Scrabble table, but
        // landing one is a moment and deserves a line of its own.
        let heavy = tray.filter { !$0.isBlank && $0.tile.value >= 8 }
        if !heavy.isEmpty {
            bonuses.append(.init(
                name: "Heavy Letter",
                points: config.heavyLetterBonus * heavy.count,
                detail: heavy.map { String($0.tile.letter) }.joined(separator: ", ")
            ))
        }

        return bonuses
    }
}
