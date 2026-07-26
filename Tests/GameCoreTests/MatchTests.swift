import XCTest
@testable import GameCore

final class MatchTests: XCTestCase {

    private func engine() -> MatchEngine {
        MatchEngine(reducer: Fixture.reducer(), pack: Fixture.pack)
    }

    private func match() -> MatchState {
        MatchState(
            players: [Player(id: "a", name: "Ann"), Player(id: "b", name: "Ben")],
            targetScore: 200,
            seed: 777
        )
    }

    func testBeginningATurnAssignsACategoryUpFront() {
        let engine = engine()
        var match = match()
        let state = engine.beginTurn(&match)

        XCTAssertFalse(state.categoryID.isEmpty, "the player must know the category before spinning")
        XCTAssertFalse(state.categoryName.isEmpty)
        XCTAssertEqual(state.triesRemaining, 3)
    }

    func testScoresPoolIntoTheSharedBank() {
        let engine = engine()
        var match = match()
        let state = engine.beginTurn(&match)

        var breakdown = ScoreBreakdown()
        breakdown.word = "CAT"
        breakdown.total = 40
        engine.completeTurn(&match, state: state, breakdown: breakdown)

        XCTAssertEqual(match.teamBank, 40)
        XCTAssertEqual(match.currentPlayer.id, "b", "the turn passes on")
    }

    func testStreakBreaksOnAScorelessTurn() {
        let engine = engine()
        var match = match()

        for total in [30, 30, 0] {
            let state = engine.beginTurn(&match)
            var breakdown = ScoreBreakdown()
            breakdown.total = total
            engine.completeTurn(&match, state: state, breakdown: breakdown)
        }
        XCTAssertEqual(match.teamStreak, 0)
    }

    func testMatchCompletesWhenTargetIsReached() {
        let engine = engine()
        var match = match()
        let state = engine.beginTurn(&match)

        var breakdown = ScoreBreakdown()
        breakdown.total = 250
        engine.completeTurn(&match, state: state, breakdown: breakdown)
        XCTAssertTrue(match.isComplete)
    }

    /// Cheat resistance without a server: the receiving device recomputes the
    /// score from `(seed, actions)` rather than trusting the number it was sent.
    func testATurnCanBeVerifiedByReplay() {
        let engine = engine()
        var match = match()
        var state = engine.beginTurn(&match)
        let context = engine.context(for: match)

        var claimed: ScoreBreakdown?
        for action in [TurnAction.spin, .bank(reel: 0), .bank(reel: 1), .lockIn] {
            let (next, effects) = engine.reducer.reduce(state, action, context: context)
            state = next
            for effect in effects {
                if case .wordLocked(let result) = effect { claimed = result }
            }
        }

        let turn = CompletedTurn(
            playerID: state.playerID,
            playerName: "Ann",
            categoryID: state.categoryID,
            categoryName: state.categoryName,
            word: claimed?.word ?? "",
            breakdown: claimed ?? ScoreBreakdown(),
            seed: state.rng.seed,
            actions: state.actionLog
        )

        let recomputed = engine.verify(turn, category: engine.category(for: match), teamStreak: 0)
        XCTAssertEqual(recomputed, turn.breakdown.total,
                       "a replayed turn must reproduce the same score exactly")
    }

    func testTransportCanChangeMidMatchWithoutAlteringRules() {
        var match = match()
        match.connectivity = .remoteAsync
        XCTAssertEqual(match.connectivity, .remoteAsync)
        XCTAssertEqual(match.players.count, 2, "changing transport changes nothing about play")
    }

    // MARK: Categories

    func testCategoryDrawIsDeterministic() {
        let engine = engine()
        var first = match()
        var second = match()
        XCTAssertEqual(engine.drawCategory(&first).id, engine.drawCategory(&second).id)
    }

    func testCategoryPackAcceptsOnlyItsOwnWords() {
        XCTAssertTrue(Fixture.animals.accepts("cat"), "matching is case-insensitive")
        XCTAssertFalse(Fixture.animals.accepts("PAN"))
    }

    /// Found on the first live run: TIES was refused under Clothing because the
    /// list had TIE. Refusing an obviously correct word reads as a broken game,
    /// not an incomplete word list.
    func testRegularPluralsOfListedWordsAreAccepted() {
        XCTAssertTrue(Fixture.animals.accepts("CATS"), "CAT is listed")
        XCTAssertTrue(Fixture.animals.accepts("BEARS"))

        let category = WordCategory(id: "t", name: "T", words: ["BOX", "PUPPY", "TIE"])
        XCTAssertTrue(category.accepts("BOXES"))
        XCTAssertTrue(category.accepts("PUPPIES"))
        XCTAssertTrue(category.accepts("TIES"))
    }

    /// The plural rule may only widen acceptance from a word already listed —
    /// it must never let in something unrelated to the category.
    func testPluralRuleCannotAdmitUnrelatedWords() {
        XCTAssertFalse(Fixture.animals.accepts("PANS"), "PAN isn't an animal")
        XCTAssertFalse(Fixture.animals.accepts("GLASSES"))
        XCTAssertFalse(Fixture.animals.accepts("S"))
    }

    func testSpellableFromRespectsLetterCounts() {
        // One E cannot spell a word needing two.
        let category = WordCategory(id: "t", name: "T", words: ["BEE", "BE"])
        XCTAssertEqual(category.words(spellableFrom: ["B", "E"]).sorted(), ["BE"])
        XCTAssertEqual(category.words(spellableFrom: ["B", "E", "E"]).sorted(), ["BE", "BEE"])
    }

    func testBlanksExtendWhatIsSpellable() {
        let category = WordCategory(id: "t", name: "T", words: ["BEE"])
        XCTAssertTrue(category.words(spellableFrom: ["B", "E"]).isEmpty)
        XCTAssertEqual(category.words(spellableFrom: ["B", "E"], blanks: 1), ["BEE"])
    }
}
