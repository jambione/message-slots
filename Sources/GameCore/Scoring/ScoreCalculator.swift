import Foundation

/// Every line the score-reveal animation shows, in the order it reveals them.
/// Keeping the breakdown as data (rather than a single Int) is what lets the UI
/// animate an honest, auditable tally instead of a made-up one.
public struct ScoreBreakdown: Codable, Hashable, Sendable {
    public var words: [WordScore] = []
    public var rawWordPoints = 0

    public var wordCount = 0
    public var lengthMultiplier = 1.0

    public var isValidSentence = false
    public var grammarMultiplier = 1.0

    public var sentenceStars = 0
    public var starMultiplier = 1.0

    public var styleBonuses: [StyleBonus] = []
    public var styleBonusPoints = 0

    public var triesRemaining = 0
    public var tryBonusPoints = 0

    public var teamStreak = 0
    public var streakMultiplier = 1.0

    public var combo = ComboResult()

    public var total = 0

    public struct WordScore: Codable, Hashable, Sendable {
        public let text: String
        public let base: Int
        public let gemMultiplier: Int
        public var value: Int { base * gemMultiplier }
    }

    public struct StyleBonus: Codable, Hashable, Sendable {
        public let name: String
        public let points: Int
        public let detail: String?
    }
}

public struct ScoreCalculator: Sendable {
    public let config: EconomyConfig
    private let coherence = CoherenceEvaluator()

    public init(config: EconomyConfig) { self.config = config }

    /// Context the scorer needs beyond the tray itself.
    public struct Context: Sendable {
        public var validation: ValidationResult
        public var triesRemaining: Int
        public var sentenceStars: Int
        public var teamStreak: Int
        public var themeTag: String?
        /// Words that were on the very first spin of the turn, for the
        /// "banked all five original reels" bonus.
        public var openingReelWords: Set<String>
        public var reelCount: Int
        public var combo: ComboResult

        public init(
            validation: ValidationResult,
            triesRemaining: Int,
            sentenceStars: Int = 0,
            teamStreak: Int = 0,
            themeTag: String? = nil,
            openingReelWords: Set<String> = [],
            reelCount: Int = 5,
            combo: ComboResult = ComboResult()
        ) {
            self.validation = validation
            self.triesRemaining = triesRemaining
            self.sentenceStars = sentenceStars
            self.teamStreak = teamStreak
            self.themeTag = themeTag
            self.openingReelWords = openingReelWords
            self.reelCount = reelCount
            self.combo = combo
        }
    }

    /// The formula from GAME_DESIGN.md §4.1:
    ///
    ///   turn = (raw × lengthM × grammarM × starM + styleB + tryB) × streakM
    ///   story: turn = (turn + comboB) × chainM
    public func score(tray: [PlacedWord], context: Context) -> ScoreBreakdown {
        var b = ScoreBreakdown()
        guard !tray.isEmpty else { return b }

        // Raw word points. A repeated word only pays once, so nobody farms
        // "banana banana banana".
        var counted = Set<String>()
        for placed in tray {
            let isDuplicate = !counted.insert(placed.entry.text).inserted
            let base = isDuplicate ? 0 : placed.entry.effectivePoints
            b.words.append(.init(text: placed.entry.text, base: base, gemMultiplier: placed.gemMultiplier))
        }
        b.rawWordPoints = b.words.reduce(0) { $0 + $1.value }

        // Length.
        b.wordCount = tray.count
        let over = max(0, tray.count - config.lengthBonusFloor)
        b.lengthMultiplier = min(1.0 + config.lengthBonusStep * Double(over), config.lengthMultiplierCap)

        // Grammar. Word salad still pays — no turn is ever worth nothing.
        b.isValidSentence = context.validation.isValid
        b.grammarMultiplier = b.isValidSentence ? config.grammarValidMultiplier : config.grammarSaladMultiplier

        // Sentence stars.
        b.sentenceStars = context.sentenceStars
        b.starMultiplier = 1.0 + config.sentenceStarStep * Double(context.sentenceStars)

        // Style bonuses.
        b.styleBonuses = styleBonuses(tray: tray, context: context)
        b.styleBonusPoints = b.styleBonuses.reduce(0) { $0 + $1.points }

        // Unused tries. Deliberately modest against the value of one more good
        // word, so "should I stop?" stays a real question.
        b.triesRemaining = context.triesRemaining
        b.tryBonusPoints = context.triesRemaining * config.pointsPerUnusedTry

        // Streak, shared across the team.
        b.teamStreak = context.teamStreak
        b.streakMultiplier = min(1.0 + config.streakStep * Double(context.teamStreak), config.streakMultiplierCap)

        let core = Double(b.rawWordPoints) * b.lengthMultiplier * b.grammarMultiplier * b.starMultiplier
        var subtotal = (core + Double(b.styleBonusPoints) + Double(b.tryBonusPoints)) * b.streakMultiplier

        // Story combos ride on top.
        b.combo = context.combo
        if !context.combo.isEmpty {
            subtotal = (subtotal + Double(context.combo.totalBonus)) * context.combo.chainMultiplier
        }

        b.total = Int(subtotal.rounded())
        return b
    }

    // MARK: Style bonuses

    private func styleBonuses(tray: [PlacedWord], context: Context) -> [ScoreBreakdown.StyleBonus] {
        var bonuses: [ScoreBreakdown.StyleBonus] = []
        let entries = tray.map(\.entry)

        // Alliteration: three or more content words sharing an initial letter.
        let contentWords = entries.filter { !$0.pos.allSatisfy(\.isGlue) }
        var initials: [Character: [String]] = [:]
        for word in contentWords {
            guard let first = word.text.first else { continue }
            initials[first, default: []].append(word.text)
        }
        // Sorted so the reported detail is stable across runs and devices —
        // it rides in the turn payload that remote clients replay.
        if let (letter, words) = initials.sorted(by: { $0.key < $1.key }).first(where: { $0.value.count >= 3 }) {
            bonuses.append(.init(
                name: "Alliteration",
                points: config.alliterationBonus,
                detail: "\(words.count) words starting with '\(letter)'"
            ))
        }

        // Rhyme: two or more words sharing their last three letters.
        var endings: [String: [String]] = [:]
        for word in entries where word.text.count >= 4 {
            let key = String(word.text.suffix(3))
            endings[key, default: []].append(word.text)
        }
        if let (_, words) = endings.sorted(by: { $0.key < $1.key }).first(where: { Set($0.value).count >= 2 }) {
            bonuses.append(.init(
                name: "Rhyme",
                points: config.rhymeBonus,
                detail: words.joined(separator: " / ")
            ))
        }

        // Banked every word from the opening spin.
        if !context.openingReelWords.isEmpty,
           context.openingReelWords.count >= context.reelCount,
           context.openingReelWords.isSubset(of: Set(entries.map(\.text))) {
            bonuses.append(.init(name: "Full House", points: config.allReelsBonus, detail: "all \(context.reelCount) opening reels banked"))
        }

        // Theme words, when a themed round is running.
        if let theme = context.themeTag {
            let themed = entries.filter { $0.tags.contains(theme) }
            if !themed.isEmpty {
                bonuses.append(.init(
                    name: "Theme",
                    points: config.themeWordBonus * themed.count,
                    detail: themed.map(\.text).joined(separator: ", ")
                ))
            }
        }

        // Makes Sense: the subject and verb are both tagged and plausibly go
        // together (Language/SemanticCoherence.swift). This never subtracts —
        // an untagged pool or a merely grammatical-but-random pairing simply
        // doesn't earn the line, it isn't marked wrong. Grammar validity
        // above already decided whether the turn counts at all; this only
        // rewards the sentences that also make sense on top of that.
        let sense = coherence.evaluate(tray)
        if sense.isCoherent, let subject = sense.subject, let verb = sense.verb {
            bonuses.append(.init(
                name: "Makes Sense",
                points: config.senseBonus,
                detail: "\(subject) \(verb)"
            ))
        }

        return bonuses
    }
}
