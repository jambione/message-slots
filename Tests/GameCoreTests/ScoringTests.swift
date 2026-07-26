import XCTest
@testable import GameCore

final class ScoringTests: XCTestCase {
    private let config = EconomyConfig.default
    private var scorer: ScoreCalculator { ScoreCalculator(config: config) }
    private let validator = SentenceValidator()

    private func context(
        valid: Bool,
        tries: Int = 0,
        stars: Int = 0,
        streak: Int = 0,
        theme: String? = nil,
        opening: Set<String> = [],
        combo: ComboResult = ComboResult()
    ) -> ScoreCalculator.Context {
        ScoreCalculator.Context(
            validation: ValidationResult(
                isValid: valid, confidence: valid ? .green : .red,
                matchedTemplate: valid ? "test" : nil,
                opensWithConnector: false, clauseCount: valid ? 1 : 0
            ),
            triesRemaining: tries,
            sentenceStars: stars,
            teamStreak: streak,
            themeTag: theme,
            openingReelWords: opening,
            reelCount: 5,
            combo: combo
        )
    }

    /// The worked example in docs/GAME_DESIGN.md §4.2 must produce exactly 126.
    /// If this test fails, either the code or the design doc is lying.
    func testWorkedExampleFromDesignDoc() {
        let the = Fixture.word("the", .article, points: 1)
        let grumpy = Fixture.word("grumpy", .adjective, tier: .uncommon, points: 4)
        let octopus = Fixture.word("octopus", .noun, tier: .rare, points: 6)
        let tangoed = Fixture.word("tangoed", .verb, tier: .uncommon, points: 5)
        let magnificently = Fixture.word("magnificently", .adverb, tier: .rare, points: 7)

        let tray = Fixture.tray([the, grumpy, octopus, tangoed, magnificently], gems: [2: 2])
        let breakdown = scorer.score(tray: tray, context: context(valid: true, tries: 1, streak: 3))

        XCTAssertEqual(breakdown.rawWordPoints, 29)
        XCTAssertEqual(breakdown.lengthMultiplier, 1.5)
        XCTAssertEqual(breakdown.grammarMultiplier, 2.0)
        XCTAssertEqual(breakdown.tryBonusPoints, 10)
        XCTAssertEqual(breakdown.streakMultiplier, 1.3, accuracy: 0.0001)
        XCTAssertEqual(breakdown.total, 126)
    }

    func testWordSaladStillScoresSomething() {
        let tray = Fixture.tray([Fixture.dog, Fixture.cat, Fixture.octopus])
        let breakdown = scorer.score(tray: tray, context: context(valid: false))
        XCTAssertEqual(breakdown.grammarMultiplier, 0.25)
        XCTAssertGreaterThan(breakdown.total, 0, "no turn should ever be worth zero")
    }

    func testValidSentenceBeatsSaladOfTheSameWords() {
        let words = [Fixture.the, Fixture.grumpy, Fixture.octopus, Fixture.tangoed]
        let good = scorer.score(tray: Fixture.tray(words), context: context(valid: true))
        let bad = scorer.score(tray: Fixture.tray(words), context: context(valid: false))
        XCTAssertGreaterThan(good.total, bad.total * 4)
    }

    func testLengthMultiplierIsCapped() {
        let many = Array(repeating: Fixture.dog, count: 12)
        let breakdown = scorer.score(tray: Fixture.tray(many), context: context(valid: true))
        XCTAssertEqual(breakdown.lengthMultiplier, config.lengthMultiplierCap)
    }

    func testRepeatedWordOnlyPaysOnce() {
        let tray = Fixture.tray([Fixture.banana, Fixture.banana, Fixture.banana])
        let breakdown = scorer.score(tray: tray, context: context(valid: false))
        XCTAssertEqual(breakdown.rawWordPoints, Fixture.banana.effectivePoints)
    }

    func testMultiCategoryWordEarnsPremium() {
        let run = Fixture.word("run", .noun, .verb, points: 2)
        XCTAssertEqual(run.effectivePoints, 3)
    }

    func testGemMultipliesOnlyItsWord() {
        let plain = scorer.score(tray: Fixture.tray([Fixture.octopus, Fixture.danced]), context: context(valid: true))
        let gemmed = scorer.score(tray: Fixture.tray([Fixture.octopus, Fixture.danced], gems: [0: 3]), context: context(valid: true))
        XCTAssertEqual(gemmed.rawWordPoints, plain.rawWordPoints + Fixture.octopus.effectivePoints * 2)
    }

    func testStreakMultiplierIsCapped() {
        let breakdown = scorer.score(tray: Fixture.tray([Fixture.dog, Fixture.danced]), context: context(valid: true, streak: 50))
        XCTAssertEqual(breakdown.streakMultiplier, config.streakMultiplierCap)
    }

    // MARK: Style bonuses

    func testAlliterationNeedsThreeContentWords() {
        let two = Fixture.tray([Fixture.dog, Fixture.danced])
        XCTAssertFalse(scorer.score(tray: two, context: context(valid: true)).styleBonuses.contains { $0.name == "Alliteration" })

        let three = Fixture.tray([
            Fixture.dog, Fixture.danced, Fixture.word("dizzily", .adverb, points: 2)
        ])
        XCTAssertTrue(scorer.score(tray: three, context: context(valid: true)).styleBonuses.contains { $0.name == "Alliteration" })
    }

    func testFullHouseRequiresEveryOpeningReelWord() {
        let opening: Set<String> = ["the", "grumpy", "octopus", "tangoed", "magnificently"]
        let full = Fixture.tray([
            Fixture.the, Fixture.grumpy, Fixture.octopus, Fixture.tangoed, Fixture.magnificently
        ])
        XCTAssertTrue(scorer.score(tray: full, context: context(valid: true, opening: opening))
            .styleBonuses.contains { $0.name == "Full House" })

        let partial = Fixture.tray([Fixture.the, Fixture.octopus, Fixture.tangoed])
        XCTAssertFalse(scorer.score(tray: partial, context: context(valid: true, opening: opening))
            .styleBonuses.contains { $0.name == "Full House" })
    }

    func testThemeWordsPayPerWord() {
        let tray = Fixture.tray([Fixture.pirate, Fixture.danced])
        let breakdown = scorer.score(tray: tray, context: context(valid: true, theme: "pirate"))
        XCTAssertEqual(breakdown.styleBonuses.first { $0.name == "Theme" }?.points, config.themeWordBonus)
    }

    // MARK: Design intent

    /// The try bonus must stay small enough that banking one more good word is
    /// usually better than stopping early — that doubt is the slots DNA.
    func testBankingAnotherGoodWordBeatsSavingATry() {
        let base = Fixture.tray([Fixture.the, Fixture.grumpy, Fixture.octopus, Fixture.tangoed])
        let stopEarly = scorer.score(tray: base, context: context(valid: true, tries: 1))
        let spendIt = scorer.score(tray: base + [PlacedWord(id: 9, entry: Fixture.magnificently)],
                                   context: context(valid: true, tries: 0))
        XCTAssertGreaterThan(spendIt.total, stopEarly.total)
    }
}
