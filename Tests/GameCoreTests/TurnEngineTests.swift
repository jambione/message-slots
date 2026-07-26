import XCTest
@testable import GameCore

final class TurnEngineTests: XCTestCase {

    // MARK: Category gating

    /// The rule the whole pivot rests on: under "Animals" you cannot submit a
    /// word that isn't an animal, however well spelled.
    func testWordOutsideTheCategoryCannotBeSubmitted() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.tray = Fixture.tray("PAN")

        let check = reducer.check(state, context: Fixture.context())
        XCTAssertFalse(check.isSubmittable)
        if case .notInCategory(let word, let category) = check.verdict {
            XCTAssertEqual(word, "PAN")
            XCTAssertEqual(category, "Animals")
        } else {
            XCTFail("expected notInCategory, got \(check.verdict)")
        }
    }

    func testWordInTheCategoryIsSubmittable() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.tray = Fixture.tray("CAT")
        XCTAssertTrue(reducer.check(state, context: Fixture.context()).isSubmittable)
    }

    func testLockInIsRefusedOutsideTheCategory() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.tray = Fixture.tray("PAN")

        let (next, effects) = reducer.reduce(state, .lockIn, context: Fixture.context())
        XCTAssertNotEqual(next.phase, .locked, "the turn must stay open")
        XCTAssertTrue(effects.contains { $0 == .rejected(.notInCategory) })
    }

    func testShortWordsAreRefusedWithTheirOwnReason() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.tray = Fixture.tray("OX")

        let (_, effects) = reducer.reduce(state, .lockIn, context: Fixture.context())
        XCTAssertTrue(effects.contains { $0 == .rejected(.wordTooShort) },
                      "too-short must be distinguishable from wrong-category")
    }

    // MARK: Tries

    func testTurnHasThreeTries() {
        XCTAssertEqual(EconomyConfig.default.triesPerTurn, 3)
        XCTAssertEqual(Fixture.turn().triesRemaining, 3)
    }

    func testSpinningConsumesATry() {
        let reducer = Fixture.reducer()
        let (next, _) = reducer.reduce(Fixture.turn(), .spin, context: Fixture.context())
        XCTAssertEqual(next.triesRemaining, 2)
    }

    func testSpinningWithNoTriesIsRejected() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.triesRemaining = 0

        let (_, effects) = reducer.reduce(state, .spin, context: Fixture.context())
        XCTAssertTrue(effects.contains { $0 == .rejected(.noTriesLeft) })
    }

    // MARK: Banking

    func testBankingMovesALetterAndEmptiesTheReel() {
        let reducer = Fixture.reducer()
        let state = Fixture.withReels(Fixture.turn(), "CATER")

        let (next, _) = reducer.reduce(state, .bank(reel: 0), context: Fixture.context())
        XCTAssertEqual(next.word, "C")
        XCTAssertTrue(next.reels[0].isEmpty, "the reel empties so it refills next spin")
        XCTAssertEqual(next.triesRemaining, 3, "banking is free")
    }

    /// Banking must not retire a reel, or a word could never outgrow the reel
    /// count. This was a real bug in the sentence engine.
    func testWordsCanGrowBeyondTheReelCount() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing

        for _ in 0..<6 {
            state = Fixture.withReels(state, "AAAAA")
            let (next, _) = reducer.reduce(state, .bank(reel: 0), context: Fixture.context())
            state = next
        }
        XCTAssertEqual(state.tray.count, 6, "six banks should yield six letters")
    }

    func testTrayCapacityIsEnforced() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.tray = Fixture.tray(String(repeating: "A", count: EconomyConfig.default.trayCapacity))
        state = Fixture.withReels(state, "BBBBB")

        let (_, effects) = reducer.reduce(state, .bank(reel: 0), context: Fixture.context())
        XCTAssertTrue(effects.contains { $0 == .rejected(.trayFull) })
    }

    // MARK: Remove and reorder

    func testRemovedLetterReturnsToAnUntouchedReel() {
        let reducer = Fixture.reducer()
        let state = Fixture.withReels(Fixture.turn(), "CATER")
        let (banked, _) = reducer.reduce(state, .bank(reel: 0), context: Fixture.context())
        let (removed, effects) = reducer.reduce(banked, .removeFromTray(index: 0), context: Fixture.context())

        XCTAssertTrue(removed.tray.isEmpty)
        XCTAssertEqual(removed.reels[0].tile?.letter, "C", "it goes back where it came from")
        XCTAssertTrue(effects.contains { $0 == .letterReturnedToReel(reel: 0, letter: "C") })
    }

    /// If the reel has moved on, the letter is gone — otherwise removal would
    /// be a free second look at a spin already paid for.
    func testRemovedLetterIsDiscardedIfItsReelMovedOn() {
        let reducer = Fixture.reducer()
        let state = Fixture.withReels(Fixture.turn(), "CATER")
        var (banked, _) = reducer.reduce(state, .bank(reel: 0), context: Fixture.context())
        banked.reels[0] = ReelFace(token: .letter(LetterTile("Z")))

        let (removed, effects) = reducer.reduce(banked, .removeFromTray(index: 0), context: Fixture.context())
        XCTAssertEqual(removed.reels[0].tile?.letter, "Z", "the new letter is not displaced")
        XCTAssertTrue(effects.contains { $0 == .letterDiscarded(letter: "C") })
    }

    func testReorderingIsFree() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.tray = Fixture.tray("ACT")

        let (next, _) = reducer.reduce(state, .reorder(from: 1, to: 0), context: Fixture.context())
        XCTAssertEqual(next.word, "CAT")
        XCTAssertEqual(next.triesRemaining, 3, "arranging never costs a try")
    }

    // MARK: Blanks

    func testBlankCanBePlayedAsAnyLetterAndScoresZero() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing
        state.heldBonuses = [.blank]
        state.tray = Fixture.tray("AT")

        let (next, effects) = reducer.reduce(state, .playBlank(letter: "C"), context: Fixture.context())
        XCTAssertEqual(next.word, "ATC")
        XCTAssertTrue(effects.contains { $0 == .blankPlayed(letter: "C") })
        XCTAssertEqual(next.tray.last?.tile.value, 0)
        XCTAssertTrue(next.heldBonuses.isEmpty, "the blank is consumed")
    }

    func testPlayingABlankWithoutHoldingOneIsRejected() {
        let reducer = Fixture.reducer()
        var state = Fixture.turn()
        state.phase = .playing

        let (_, effects) = reducer.reduce(state, .playBlank(letter: "C"), context: Fixture.context())
        XCTAssertTrue(effects.contains { $0 == .rejected(.noBlankHeld) })
    }

    // MARK: Determinism

    /// The property remote play depends on: same seed and actions, same result.
    func testTurnsReplayIdentically() {
        let reducer = Fixture.reducer()
        let actions: [TurnAction] = [.spin, .bank(reel: 0), .spin, .bank(reel: 1)]

        func run() -> TurnState {
            var state = Fixture.turn(seed: 4242)
            for action in actions {
                (state, _) = reducer.reduce(state, action, context: Fixture.context())
            }
            return state
        }

        XCTAssertEqual(run(), run())
    }

    func testDifferentSeedsDiverge() {
        let reducer = Fixture.reducer()
        func run(_ seed: UInt64) -> [Character] {
            var state = Fixture.turn(seed: seed)
            (state, _) = reducer.reduce(state, .spin, context: Fixture.context())
            return state.reels.compactMap { $0.tile?.letter }
        }
        XCTAssertNotEqual(run(1), run(999_999))
    }

    // MARK: Spin guarantees

    /// A rack with no vowel is unspellable no matter the category.
    func testEverySpinOffersAVowel() {
        let reducer = Fixture.reducer()
        let bag = LetterBag()
        for seed in UInt64(1)...60 {
            var state = Fixture.turn(seed: seed)
            (state, _) = reducer.reduce(state, .spin, context: Fixture.context())
            let letters = state.reels.compactMap { $0.tile?.letter }
            XCTAssertTrue(letters.contains(where: bag.isVowel), "seed \(seed): no vowel on the reels")
        }
    }

    /// The guarantee that makes the category gate survivable: whatever the
    /// letters, at least one word in the category must be reachable. Without
    /// this the game hands out dead turns constantly.
    func testEverySpinLeavesACategoryWordReachable() {
        let reducer = Fixture.reducer()
        for seed in UInt64(1)...60 {
            var state = Fixture.turn(seed: seed)
            (state, _) = reducer.reduce(state, .spin, context: Fixture.context())
            let letters = state.reels.compactMap { $0.tile?.letter }
            let reachable = Fixture.animals.words(spellableFrom: letters)
            XCTAssertFalse(reachable.isEmpty, "seed \(seed): dead rack \(String(letters))")
        }
    }
}
