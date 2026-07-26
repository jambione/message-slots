import XCTest
@testable import GameCore

final class ScoringTests: XCTestCase {
    private let config = EconomyConfig.default
    private var scorer: ScoreCalculator { ScoreCalculator(config: config) }

    private func context(tries: Int = 0, streak: Int = 0, wordMultiplier: Int = 1,
                         opening: [Character] = []) -> ScoreCalculator.Context {
        .init(triesRemaining: tries, teamStreak: streak,
              wordMultiplier: wordMultiplier, openingLetters: opening)
    }

    // MARK: Scrabble values

    /// The whole appeal of Scrabble scoring is that a player can predict it.
    /// If these drift, the game silently stops being checkable by hand.
    func testLetterValuesMatchScrabble() {
        XCTAssertEqual(LetterTile.value(of: "A"), 1)
        XCTAssertEqual(LetterTile.value(of: "D"), 2)
        XCTAssertEqual(LetterTile.value(of: "B"), 3)
        XCTAssertEqual(LetterTile.value(of: "F"), 4)
        XCTAssertEqual(LetterTile.value(of: "K"), 5)
        XCTAssertEqual(LetterTile.value(of: "J"), 8)
        XCTAssertEqual(LetterTile.value(of: "Q"), 10)
        XCTAssertEqual(LetterTile.value(of: "Z"), 10)
    }

    func testBlankScoresZeroButStillSpells() {
        let blank = LetterTile("Q", isBlank: true)
        XCTAssertEqual(blank.value, 0, "a blank is worth nothing, exactly as in Scrabble")
        XCTAssertEqual(blank.letter, "Q", "but it still spells the letter it was played as")
    }

    func testLetterValuesAreCaseInsensitive() {
        XCTAssertEqual(LetterTile("q").value, 10)
        XCTAssertEqual(LetterTile("q").letter, "Q")
    }

    // MARK: Worked example

    /// CAT = 3 + 1 + 1 = 5 letter points, length 3 (no bonus at the floor),
    /// no tries left, no streak. A player can check this on their fingers.
    func testWorkedExample() {
        let breakdown = scorer.score(tray: Fixture.tray("CAT"), context: context())
        XCTAssertEqual(breakdown.word, "CAT")
        XCTAssertEqual(breakdown.letterPoints, 5)
        XCTAssertEqual(breakdown.lengthBonus, 0)
        XCTAssertEqual(breakdown.total, 5)
    }

    func testLetterGemMultipliesOnlyItsLetter() {
        let plain = scorer.score(tray: Fixture.tray("CAT"), context: context())
        let gemmed = scorer.score(tray: Fixture.tray("CAT", multipliers: [0: 3]), context: context())
        // C is worth 3; tripling it adds 6.
        XCTAssertEqual(gemmed.letterPoints, plain.letterPoints + 6)
    }

    func testWordMultiplierAppliesToEveryLetter() {
        let plain = scorer.score(tray: Fixture.tray("CAT"), context: context())
        let doubled = scorer.score(tray: Fixture.tray("CAT"), context: context(wordMultiplier: 2))
        XCTAssertEqual(doubled.total, plain.total * 2)
    }

    // MARK: Length

    /// Length must escalate, not creep. Going from 4 to 6 letters should be
    /// worth more than two average tiles, or the safe short word always wins
    /// and the turn has no arc.
    func testLengthBonusEscalates() {
        let four = scorer.score(tray: Fixture.tray("BEAR"), context: context()).lengthBonus
        let six = scorer.score(tray: Fixture.tray("BADGER"), context: context()).lengthBonus
        XCTAssertGreaterThan(six, four * 2, "length should escalate, not scale linearly")
    }

    func testShortWordsGetNoLengthBonus() {
        XCTAssertEqual(scorer.score(tray: Fixture.tray("CAT"), context: context()).lengthBonus, 0)
    }

    // MARK: Style bonuses

    func testHeavyLetterBonusFiresForHighValueTiles() {
        let breakdown = scorer.score(tray: Fixture.tray("ZAP"), context: context())
        XCTAssertTrue(breakdown.styleBonuses.contains { $0.name == "Heavy Letter" })
    }

    func testBlanksDoNotCountAsHeavyLetters() {
        // A blank played as Z spells Z but is worth nothing, so it must not
        // claim the bonus for a letter the player never actually landed.
        let breakdown = scorer.score(tray: Fixture.tray("ZAP", blanks: [0]), context: context())
        XCTAssertFalse(breakdown.styleBonuses.contains { $0.name == "Heavy Letter" })
    }

    func testAllRealTilesBonusRequiresNoBlanks() {
        let clean = scorer.score(tray: Fixture.tray("BADGER"), context: context())
        let withBlank = scorer.score(tray: Fixture.tray("BADGER", blanks: [2]), context: context())
        XCTAssertTrue(clean.styleBonuses.contains { $0.name == "All Real Tiles" })
        XCTAssertFalse(withBlank.styleBonuses.contains { $0.name == "All Real Tiles" })
    }

    func testFullRackBonusNeedsEveryOpeningLetterUsed() {
        let opening: [Character] = ["B", "E", "A", "R", "S"]
        let partial = scorer.score(tray: Fixture.tray("BEAR"), context: context(opening: opening))
        XCTAssertFalse(partial.styleBonuses.contains { $0.name == "Full Rack" })

        let full = scorer.score(tray: Fixture.tray("BEARS"), context: context(opening: opening))
        XCTAssertTrue(full.styleBonuses.contains { $0.name == "Full Rack" })
    }

    // MARK: Multipliers and streak

    func testStreakMultiplierIsCapped() {
        let breakdown = scorer.score(tray: Fixture.tray("CAT"), context: context(streak: 99))
        XCTAssertEqual(breakdown.streakMultiplier, config.streakMultiplierCap)
    }

    func testUnusedTriesPayOut() {
        let spent = scorer.score(tray: Fixture.tray("CAT"), context: context(tries: 0))
        let saved = scorer.score(tray: Fixture.tray("CAT"), context: context(tries: 2))
        XCTAssertEqual(saved.total - spent.total, 2 * config.pointsPerUnusedTry)
    }

    /// With only three tries, banking a better letter should still usually beat
    /// hoarding a spin — that doubt is the slots DNA.
    func testLongerWordBeatsSavingATry() {
        let short = scorer.score(tray: Fixture.tray("BEAR"), context: context(tries: 1))
        let long = scorer.score(tray: Fixture.tray("BADGER"), context: context(tries: 0))
        XCTAssertGreaterThan(long.total, short.total)
    }

    func testEmptyTrayScoresNothing() {
        XCTAssertEqual(scorer.score(tray: [], context: context()).total, 0)
    }
}
