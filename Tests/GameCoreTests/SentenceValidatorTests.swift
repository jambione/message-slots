import XCTest
@testable import GameCore

final class SentenceValidatorTests: XCTestCase {
    private let validator = SentenceValidator()

    private func validate(_ entries: [WordEntry]) -> ValidationResult {
        validator.validate(Fixture.tray(entries))
    }

    // MARK: Accepts

    func testSubjectVerb() {
        XCTAssertTrue(validate([Fixture.dog, Fixture.danced]).isValid)
    }

    func testArticleAdjectiveNounAdverbVerb() {
        // "The grumpy octopus tangoed magnificently."
        let r = validate([Fixture.the, Fixture.grumpy, Fixture.octopus, Fixture.tangoed, Fixture.magnificently])
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.confidence, .green)
    }

    func testSubjectVerbObject() {
        XCTAssertTrue(validate([Fixture.the, Fixture.dog, Fixture.danced, Fixture.a, Fixture.banana]).isValid)
    }

    func testPredicateAdjective() {
        XCTAssertTrue(validate([Fixture.the, Fixture.dog, Fixture.isVerb, Fixture.happy]).isValid)
    }

    func testPrepositionalPlace() {
        XCTAssertTrue(validate([Fixture.the, Fixture.cat, Fixture.danced, Fixture.under, Fixture.the, Fixture.table]).isValid)
    }

    func testPronounSubject() {
        XCTAssertTrue(validate([Fixture.it, Fixture.danced]).isValid)
    }

    func testConjunctionJoinsTwoClauses() {
        // "The dog danced and the cat sang."
        let sang = Fixture.word("sang", .verb, points: 2)
        XCTAssertTrue(validate([Fixture.the, Fixture.dog, Fixture.danced, Fixture.and, Fixture.the, Fixture.cat, sang]).isValid)
    }

    func testLeadingConjunctionIsAllowedAndFlagged() {
        // "Meanwhile the grumpy octopus tangoed."
        let r = validate([Fixture.meanwhile, Fixture.the, Fixture.grumpy, Fixture.octopus, Fixture.tangoed])
        XCTAssertTrue(r.isValid)
        XCTAssertTrue(r.opensWithConnector)
    }

    func testMultiCategoryWordResolvesByPosition() {
        // "run" as a verb: "they run" — and as a noun: "the run is happy".
        let run = Fixture.word("run", .noun, .verb, points: 2)
        XCTAssertTrue(validate([Fixture.they, run]).isValid)
        XCTAssertTrue(validate([Fixture.the, run, Fixture.isVerb, Fixture.happy]).isValid)
    }

    // MARK: Rejects

    func testEmptyAndSingleWordTraysAreNotSentences() {
        XCTAssertFalse(validate([]).isValid)
        XCTAssertFalse(validate([Fixture.dog]).isValid)
    }

    func testNounPileIsWordSalad() {
        XCTAssertFalse(validate([Fixture.dog, Fixture.cat, Fixture.octopus]).isValid)
    }

    func testVerbWithNoSubjectIsInvalid() {
        XCTAssertFalse(validate([Fixture.danced, Fixture.quickly]).isValid)
    }

    func testDanglingArticleIsInvalid() {
        XCTAssertFalse(validate([Fixture.the, Fixture.dog, Fixture.danced, Fixture.the]).isValid)
    }

    func testTrailingConjunctionIsInvalid() {
        XCTAssertFalse(validate([Fixture.dog, Fixture.danced, Fixture.and]).isValid)
    }

    // MARK: Advisory layer

    func testAdvisoryCanOnlyDowngradeToYellowNeverReject() {
        struct Disagreeing: AdvisoryTagger {
            func agrees(with sentence: String) -> Bool { false }
        }
        let strict = SentenceValidator(advisory: Disagreeing())
        let r = strict.validate(Fixture.tray([Fixture.dog, Fixture.danced]))
        XCTAssertTrue(r.isValid, "advisory must never reject a template match")
        XCTAssertEqual(r.confidence, .yellow)
    }

    // MARK: Corpus health

    /// The design targets ≥95% acceptance of sentences players would consider
    /// valid, and rejection of obvious salad.
    func testCorpusAcceptanceRates() {
        let valid: [[WordEntry]] = [
            [Fixture.dog, Fixture.danced],
            [Fixture.the, Fixture.dog, Fixture.danced],
            [Fixture.the, Fixture.grumpy, Fixture.dog, Fixture.danced],
            [Fixture.the, Fixture.dog, Fixture.quickly, Fixture.danced],
            [Fixture.the, Fixture.dog, Fixture.danced, Fixture.quickly],
            [Fixture.it, Fixture.isVerb, Fixture.happy],
            [Fixture.the, Fixture.cat, Fixture.danced, Fixture.under, Fixture.the, Fixture.table],
            [Fixture.the, Fixture.octopus, Fixture.tangoed, Fixture.a, Fixture.banana],
            [Fixture.meanwhile, Fixture.the, Fixture.cat, Fixture.sangFixture],
            [Fixture.they, Fixture.danced, Fixture.magnificently]
        ]
        let salad: [[WordEntry]] = [
            [Fixture.dog, Fixture.cat],
            [Fixture.the, Fixture.the],
            [Fixture.grumpy, Fixture.quickly],
            [Fixture.danced, Fixture.tangoed],
            [Fixture.under, Fixture.the, Fixture.table]
        ]

        let accepted = valid.filter { validate($0).isValid }.count
        let wronglyAccepted = salad.filter { validate($0).isValid }.count

        XCTAssertGreaterThanOrEqual(Double(accepted) / Double(valid.count), 0.95, "grammar is too strict — players will feel cheated")
        XCTAssertEqual(wronglyAccepted, 0, "obvious word salad should not pass as a sentence")
    }
}

private extension Fixture {
    static let sangFixture = Fixture.word("sang", .verb, points: 2)
}
