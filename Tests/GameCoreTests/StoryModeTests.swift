import XCTest
@testable import GameCore

final class StoryModeTests: XCTestCase {
    private let config = EconomyConfig.default
    private var detector: ComboDetector { ComboDetector(config: config) }

    private func story(with sentences: [[WordEntry]], endingWord: String = "finally") -> Story {
        var story = Story(endingWord: endingWord)
        for (i, entries) in sentences.enumerated() {
            let sentence = StorySentence(
                id: i,
                text: Sentence.text(from: Fixture.tray(entries)),
                words: entries.map(\.text),
                authorID: "p\(i % 2)",
                authorName: "Player \(i % 2)",
                score: 100
            )
            story.append(sentence, entries: entries, carriedContinuity: false)
        }
        return story
    }

    // MARK: Combos

    func testThreadRewardsReusingANounFromTheLastSentence() {
        let s = story(with: [[Fixture.the, Fixture.octopus, Fixture.danced]])
        let result = detector.detect(
            tray: Fixture.tray([Fixture.the, Fixture.octopus, Fixture.tangoed]),
            story: s,
            isFinalTurnOfChapter: false
        )
        XCTAssertEqual(result.threadWords, ["octopus"])
        XCTAssertEqual(result.threadPoints, config.threadBonus)
        XCTAssertTrue(result.callbackWords.isEmpty, "a thread must not also pay as a callback")
    }

    func testCallbackRewardsReusingAnOlderNoun() {
        let s = story(with: [
            [Fixture.the, Fixture.octopus, Fixture.danced],
            [Fixture.the, Fixture.dog, Fixture.sang]
        ])
        let result = detector.detect(
            tray: Fixture.tray([Fixture.the, Fixture.octopus, Fixture.tangoed]),
            story: s,
            isFinalTurnOfChapter: false
        )
        XCTAssertEqual(result.callbackWords, ["octopus"])
        XCTAssertEqual(result.callbackPoints, config.callbackBonus)
    }

    func testPronounCountsAsACallback() {
        let s = story(with: [[Fixture.the, Fixture.octopus, Fixture.danced]])
        let result = detector.detect(
            tray: Fixture.tray([Fixture.it, Fixture.tangoed]),
            story: s,
            isFinalTurnOfChapter: false
        )
        XCTAssertEqual(result.callbackWords, ["it"])
    }

    func testCallbacksAreCapped() {
        let s = story(with: [
            [Fixture.octopus, Fixture.danced],
            [Fixture.dog, Fixture.sang],
            [Fixture.cat, Fixture.sang],
            [Fixture.banana, Fixture.sang],
            [Fixture.moonFixture, Fixture.sang]
        ])
        let result = detector.detect(
            tray: Fixture.tray([Fixture.octopus, Fixture.dog, Fixture.cat, Fixture.banana, Fixture.danced]),
            story: s,
            isFinalTurnOfChapter: false
        )
        XCTAssertLessThanOrEqual(result.callbackWords.count, config.maxCallbacksPerTurn)
    }

    func testConjunctionOpeningPays() {
        let s = story(with: [[Fixture.the, Fixture.dog, Fixture.danced]])
        let result = detector.detect(
            tray: Fixture.tray([Fixture.meanwhile, Fixture.the, Fixture.cat, Fixture.sang]),
            story: s,
            isFinalTurnOfChapter: false
        )
        XCTAssertTrue(result.openedWithConnector)
        XCTAssertEqual(result.connectorPoints, config.connectorOpenBonus)
    }

    func testChapterCloseOnlyOnTheFinalTurn() {
        let s = story(with: [[Fixture.the, Fixture.dog, Fixture.danced]], endingWord: "finally")
        let tray = Fixture.tray([Fixture.the, Fixture.dog, Fixture.danced, Fixture.finally])

        let early = detector.detect(tray: tray, story: s, isFinalTurnOfChapter: false)
        XCTAssertFalse(early.closedChapter)

        let final = detector.detect(tray: tray, story: s, isFinalTurnOfChapter: true)
        XCTAssertTrue(final.closedChapter)
        XCTAssertEqual(final.chapterPoints, config.chapterCloseBonus)
    }

    // MARK: Chain

    func testChainGrowsWithContinuityAndResetsWithout() {
        var s = story(with: [[Fixture.the, Fixture.octopus, Fixture.danced]])

        let continued = detector.detect(
            tray: Fixture.tray([Fixture.the, Fixture.octopus, Fixture.tangoed]),
            story: s, isFinalTurnOfChapter: false
        )
        XCTAssertTrue(continued.carriedContinuity)
        XCTAssertEqual(continued.resultingChainLevel, 1)
        XCTAssertEqual(continued.chainMultiplier, 1.1, accuracy: 0.0001)

        // Bank the continuation, then write something unrelated.
        s.append(
            StorySentence(id: 1, text: "x", words: ["octopus"], authorID: "p1", authorName: "P", score: 1),
            entries: [Fixture.octopus], carriedContinuity: true
        )
        let broken = detector.detect(
            tray: Fixture.tray([Fixture.a, Fixture.banana, Fixture.danced]),
            story: s, isFinalTurnOfChapter: false
        )
        XCTAssertFalse(broken.carriedContinuity)
        XCTAssertEqual(broken.resultingChainLevel, 0)
        XCTAssertEqual(broken.chainMultiplier, 1.0)
    }

    func testChainMultiplierIsCapped() {
        var s = story(with: [[Fixture.octopus, Fixture.danced]])
        for i in 0..<20 {
            s.append(
                StorySentence(id: i + 1, text: "x", words: ["octopus"], authorID: "p", authorName: "P", score: 1),
                entries: [Fixture.octopus], carriedContinuity: true
            )
        }
        let result = detector.detect(
            tray: Fixture.tray([Fixture.octopus, Fixture.tangoed]),
            story: s, isFinalTurnOfChapter: false
        )
        XCTAssertEqual(result.chainMultiplier, config.chainMultiplierCap)
    }

    func testCombosDoNotApplyOutsideStoryMode() {
        let result = detector.detect(
            tray: Fixture.tray([Fixture.octopus, Fixture.danced]),
            story: nil, isFinalTurnOfChapter: true
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Scoring integration

    func testComboBonusAndChainApplyOnTopOfTheTurnScore() {
        let scorer = ScoreCalculator(config: config)
        let tray = Fixture.tray([Fixture.the, Fixture.octopus, Fixture.tangoed])
        let validation = ValidationResult(isValid: true, confidence: .green, matchedTemplate: "t", opensWithConnector: false, clauseCount: 1)

        let plain = scorer.score(tray: tray, context: .init(validation: validation, triesRemaining: 0))
        var combo = ComboResult()
        combo.threadWords = ["octopus"]
        combo.threadPoints = config.threadBonus
        combo.chainMultiplier = 1.2
        combo.resultingChainLevel = 2
        let withCombo = scorer.score(tray: tray, context: .init(validation: validation, triesRemaining: 0, combo: combo))

        XCTAssertEqual(withCombo.total, Int(((Double(plain.total) + Double(config.threadBonus)) * 1.2).rounded()))
    }

    // MARK: Reel bias

    /// Callbacks are only fun if they are reachable, so nouns already in the
    /// story must resurface noticeably more often than fresh ones.
    func testStoryNounsResurfaceMoreOften() {
        let resolver = SpinResolver(config: config, pool: Fixture.pool)
        var storyState = Story(endingWord: "finally")
        storyState.append(
            StorySentence(id: 0, text: "x", words: ["octopus"], authorID: "p", authorName: "P", score: 1),
            entries: [Fixture.octopus], carriedContinuity: false
        )

        func octopusAppearances(story: Story?) -> Int {
            var count = 0
            for seed in UInt64(0)..<400 {
                var rng = SeededRNG(seed: seed)
                let context = SpinContext(trayEntries: [], triesRemaining: 5, story: story)
                let (faces, _) = resolver.spin(reels: [0, 1, 2, 3, 4], context: context, rng: &rng)
                if faces.values.contains(where: { $0.word?.text == "octopus" }) { count += 1 }
            }
            return count
        }

        let withStory = octopusAppearances(story: storyState)
        let without = octopusAppearances(story: nil)
        XCTAssertGreaterThan(withStory, without, "story nouns should be biased upward")
    }
}

private extension Fixture {
    static let sang = Fixture.word("sang", .verb, points: 2)
    static let moonFixture = Fixture.word("moon", .noun, points: 2)
}
