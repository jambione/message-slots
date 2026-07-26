import XCTest
@testable import GameCore

/// Coverage for `WordEntry.weight` — authored draw frequency.
///
/// This exists because the bug it guards against was invisible: every
/// determiner was `common`, so nothing in the content or the tests looked
/// wrong, and yet "the" reached the reels on roughly 6% of spins. Trays read
/// "Friend ate" instead of "The friend ate" and it took playing the game to
/// notice. These tests pin the mechanism so a future content pass can't
/// quietly undo it.
final class WordFrequencyTests: XCTestCase {

    // MARK: Model

    func testWeightDefaultsToNeutral() {
        XCTAssertEqual(Fixture.dog.weight, 1.0)
    }

    /// Old compiled pools have no `weight` key at all and must keep working.
    func testMissingWeightDecodesToNeutral() throws {
        let json = """
        {"text":"dog","pos":["NOUN"],"tier":"common","points":1,"tags":[]}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WordEntry.self, from: json)
        XCTAssertEqual(entry.weight, 1.0)
    }

    func testWeightSurvivesARoundTrip() throws {
        let original = Fixture.word("the", .article, weight: 9)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WordEntry.self, from: data)
        XCTAssertEqual(decoded.weight, 9)
    }

    /// Weight is about how often you see a word, tier is about what it's worth.
    /// Conflating them is the mistake this field exists to prevent.
    func testWeightDoesNotAffectScoringValue() {
        let common = Fixture.word("the", .article, points: 1, weight: 9)
        let rare = Fixture.word("the", .article, points: 1, weight: 0.1)
        XCTAssertEqual(common.effectivePoints, rare.effectivePoints)
    }

    // MARK: Draw behaviour

    /// Over many draws from a weighted set, the ordering
    /// of frequencies matches the ordering of weights.
    func testDrawFrequencyTracksAuthoredWeight() {
        let words = [
            Fixture.word("the", .article, weight: 9),
            Fixture.word("a", .article, weight: 6),
            Fixture.word("every", .article, weight: 0.6)
        ]
        var rng = SeededRNG(seed: 99)
        var counts: [String: Int] = [:]
        for _ in 0..<6_000 {
            if let pick = rng.pick(words, weights: words.map(\.weight)) {
                counts[pick.text, default: 0] += 1
            }
        }

        let the = counts["the"] ?? 0
        let a = counts["a"] ?? 0
        let every = counts["every"] ?? 0

        XCTAssertGreaterThan(the, a, "'the' is weighted 9 vs 6 and should lead")
        XCTAssertGreaterThan(a, every, "'a' is weighted 6 vs 0.6")
        XCTAssertGreaterThan(every, 0, "a low weight must still be reachable, never zero")

        // 9 : 6 : 0.6 out of 15.6 → roughly 58% / 38% / 4%.
        let total = Double(the + a + every)
        XCTAssertEqual(Double(the) / total, 9.0 / 15.6, accuracy: 0.05)
        XCTAssertEqual(Double(every) / total, 0.6 / 15.6, accuracy: 0.03)
    }

    /// The shipping pool must actually carry the fix.
    func testShippedPoolWeightsTheAndAAboveOtherDeterminers() throws {
        let pool = try WordPool.bundled()
        let determiners = pool.words.filter { $0.can(be: .article) }
        guard let the = determiners.first(where: { $0.text == "the" }),
              let a = determiners.first(where: { $0.text == "a" }) else {
            return XCTFail("starter pool should contain 'the' and 'a'")
        }
        let others = determiners.filter { $0.text != "the" && $0.text != "a" && $0.text != "an" }
        for other in others {
            XCTAssertGreaterThan(the.weight, other.weight, "'the' should outrank '\(other.text)'")
            XCTAssertGreaterThan(a.weight, other.weight, "'a' should outrank '\(other.text)'")
        }
    }
}
