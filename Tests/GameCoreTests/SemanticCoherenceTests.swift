import XCTest
@testable import GameCore

/// Coverage for the "Makes Sense" coherence bonus (GAME_LOGIC.md §5.1).
///
/// The user's requirement was explicit: reward sentences that make sense,
/// but never punish ones that don't ("Funny and silly yes, invalid no").
/// These tests assert both halves of that contract — the bonus fires when
/// earned, and its absence never touches grammar validity or the base score.
final class SemanticCoherenceTests: XCTestCase {
    private let evaluator = CoherenceEvaluator()

    // MARK: CoherenceEvaluator

    func testCompatibleSubjectAndVerbAreCoherent() {
        let tray = Fixture.tray([Fixture.the, Fixture.parrot, Fixture.flew])
        let result = evaluator.evaluate(tray)
        XCTAssertTrue(result.isCoherent)
        XCTAssertEqual(result.subject, "parrot")
        XCTAssertEqual(result.verb, "flew")
    }

    func testIncompatibleTaggedPairIsNotCoherentButStillIdentified() {
        // "parrot" only claims animate; "overflowed" only claims place/object.
        // No shared category, so no bonus — but the evaluator still reports
        // what it found, since this is a scoring decision, not a rejection.
        let tray = Fixture.tray([Fixture.the, Fixture.parrot, Fixture.overflowed])
        let result = evaluator.evaluate(tray)
        XCTAssertFalse(result.isCoherent)
        XCTAssertEqual(result.subject, "parrot")
        XCTAssertEqual(result.verb, "overflowed")
    }

    func testUntaggedPairHasNoOpinionEitherWay() {
        // dog/danced carry no semantics in the fixtures — an untagged word
        // pool must never claim incoherence, only silence.
        let tray = Fixture.tray([Fixture.the, Fixture.dog, Fixture.danced])
        let result = evaluator.evaluate(tray)
        XCTAssertFalse(result.isCoherent)
    }

    func testCopulaVerbIsCompatibleWithAnyTaggedSubject() {
        // "is" is tagged with every semantic category, matching the design
        // intent that copulas ("is/are/was") never gate on subject kind.
        let tray = Fixture.tray([Fixture.parrot, Fixture.isVerb, Fixture.happy])
        let result = evaluator.evaluate(tray)
        XCTAssertTrue(result.isCoherent)
    }

    func testMultiCategoryVerbMatchesAnyOfItsTaggedCategories() {
        let sandwich = Fixture.word("sandwich", .noun, points: 2, semantics: [.food])
        let tray = Fixture.tray([Fixture.the, sandwich, Fixture.melted])
        let result = evaluator.evaluate(tray)
        XCTAssertTrue(result.isCoherent)
    }

    func testNoVerbInTrayYieldsNoResult() {
        let tray = Fixture.tray([Fixture.the, Fixture.parrot, Fixture.happy])
        let result = evaluator.evaluate(tray)
        XCTAssertFalse(result.isCoherent)
        XCTAssertNil(result.subject)
        XCTAssertNil(result.verb)
    }

    func testNoNounBeforeVerbYieldsNoResult() {
        let tray = Fixture.tray([Fixture.flew])
        let result = evaluator.evaluate(tray)
        XCTAssertFalse(result.isCoherent)
        XCTAssertNil(result.subject)
        XCTAssertNil(result.verb)
    }

    // MARK: ScoreCalculator integration

    private let config = EconomyConfig.default
    private var scorer: ScoreCalculator { ScoreCalculator(config: config) }

    private func context(valid: Bool) -> ScoreCalculator.Context {
        ScoreCalculator.Context(
            validation: ValidationResult(
                isValid: valid, confidence: valid ? .green : .red,
                matchedTemplate: valid ? "test" : nil,
                opensWithConnector: false, clauseCount: valid ? 1 : 0
            ),
            triesRemaining: 0
        )
    }

    func testCoherentSentenceEarnsTheMakesSenseBonus() {
        let tray = Fixture.tray([Fixture.the, Fixture.parrot, Fixture.flew])
        let breakdown = scorer.score(tray: tray, context: context(valid: true))
        let bonus = breakdown.styleBonuses.first { $0.name == "Makes Sense" }
        XCTAssertEqual(bonus?.points, config.senseBonus)
    }

    /// The core promise: an incoherent-but-grammatical sentence is still a
    /// fully valid, fully scored turn. It just doesn't get the extra line.
    func testIncoherentSentenceStaysFullyValidAndJustSkipsTheBonus() {
        let tray = Fixture.tray([Fixture.the, Fixture.parrot, Fixture.overflowed])
        let breakdown = scorer.score(tray: tray, context: context(valid: true))
        XCTAssertTrue(breakdown.isValidSentence)
        XCTAssertEqual(breakdown.grammarMultiplier, config.grammarValidMultiplier)
        XCTAssertFalse(breakdown.styleBonuses.contains { $0.name == "Makes Sense" })
        XCTAssertGreaterThan(breakdown.total, 0)
    }

    func testUntaggedSentenceNeitherEarnsNorLosesAnything() {
        // Same point values on both sides so the only possible score delta is
        // the bonus itself, not a difference in the words' raw worth.
        let taggedSubject = Fixture.word("parrot", .noun, points: 2, semantics: [.animate])
        let taggedVerb = Fixture.word("flew", .verb, points: 2, semantics: [.animate])
        let plainSubject = Fixture.word("gizmo", .noun, points: 2)
        let plainVerb = Fixture.word("wozzled", .verb, points: 2)

        let coherent = Fixture.tray([Fixture.the, taggedSubject, taggedVerb])
        let untagged = Fixture.tray([Fixture.the, plainSubject, plainVerb])
        let withSense = scorer.score(tray: coherent, context: context(valid: true))
        let withoutSignal = scorer.score(tray: untagged, context: context(valid: true))
        XCTAssertFalse(withoutSignal.styleBonuses.contains { $0.name == "Makes Sense" })
        // Same shape of sentence, same validity — the only score delta between
        // an untagged pool and a tagged-but-compatible one is the bonus itself.
        XCTAssertEqual(withSense.total - withoutSignal.total, config.senseBonus)
    }
}
