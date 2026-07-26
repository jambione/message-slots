import XCTest
@testable import GameCore

final class TurnEngineTests: XCTestCase {
    private let reducer = Fixture.reducer()

    private func startedTurn(seed: UInt64 = 42) -> TurnState {
        var state = reducer.startTurn(playerID: "p1", seed: seed)
        (state, _) = reducer.reduce(state, .spin)
        return state
    }

    // MARK: Determinism — the property everything else depends on

    func testSameSeedAndActionsProduceIdenticalTurns() {
        let actions: [TurnAction] = [.spin, .bank(reel: 0), .spin, .bank(reel: 1), .spin, .lockIn]
        let (a, effectsA) = reducer.replay(seed: 12_345, playerID: "p1", actions: actions)
        let (b, effectsB) = reducer.replay(seed: 12_345, playerID: "p1", actions: actions)

        XCTAssertEqual(a, b, "identical seed and actions must produce identical state")
        XCTAssertEqual(effectsA, effectsB, "effects must replay identically for turn playback")
    }

    func testDifferentSeedsProduceDifferentTables() {
        let (a, _) = reducer.replay(seed: 1, playerID: "p1", actions: [.spin])
        let (b, _) = reducer.replay(seed: 2, playerID: "p1", actions: [.spin])
        XCTAssertNotEqual(a.reels, b.reels)
    }

    func testTurnStateSurvivesRoundTripEncoding() throws {
        let state = startedTurn()
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(TurnState.self, from: data)
        XCTAssertEqual(state, restored, "match state must survive being sent to another phone")
    }

    // MARK: Spinning and tries

    func testFirstSpinFillsEveryReel() {
        let state = startedTurn()
        XCTAssertEqual(state.reels.compactMap(\.token).count, EconomyConfig.default.reelCount)
        XCTAssertEqual(state.triesRemaining, EconomyConfig.default.triesPerTurn - 1)
    }

    func testBankingIsFreeButSpinningCostsATry() {
        var state = startedTurn()
        let triesAfterSpin = state.triesRemaining
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        XCTAssertEqual(state.triesRemaining, triesAfterSpin, "banking must never cost a try")

        (state, _) = reducer.reduce(state, .spin)
        XCTAssertEqual(state.triesRemaining, triesAfterSpin - 1)
    }

    /// Banking is permanent for the *word*, not the reel: the face empties and
    /// refills next spin. This is what lets a sentence grow past five words.
    func testBankedWordStaysAndItsReelRefills() {
        var state = startedTurn()
        let banked = Fixture.octopus
        state.reels[0] = ReelFace(token: .word(banked))

        (state, _) = reducer.reduce(state, .bank(reel: 0))
        XCTAssertTrue(state.reels[0].isEmpty)
        XCTAssertEqual(state.tray.first?.entry.text, banked.text)

        (state, _) = reducer.reduce(state, .spin)
        XCTAssertFalse(state.reels[0].isEmpty, "the reel should refill after banking")
        XCTAssertEqual(state.tray.first?.entry.text, banked.text, "the banked word stays put")
        XCTAssertNotEqual(state.reels[0].token?.word?.text, banked.text, "a banked word cannot reappear")
    }

    func testSentencesCanGrowBeyondTheReelCount() {
        var state = reducer.startTurn(playerID: "p1", seed: 31)
        for _ in 0..<EconomyConfig.default.triesPerTurn {
            (state, _) = reducer.reduce(state, .spin)
            for reel in state.reels.indices where state.reels[reel].token?.word != nil {
                (state, _) = reducer.reduce(state, .bank(reel: reel))
            }
        }
        XCTAssertGreaterThan(state.tray.count, EconomyConfig.default.reelCount,
                             "banking across several spins must be able to exceed five words")
    }

    func testSpinningWithNoTriesIsRejected() {
        var state = reducer.startTurn(playerID: "p1", seed: 7)
        for _ in 0..<EconomyConfig.default.triesPerTurn {
            (state, _) = reducer.reduce(state, .spin)
        }
        let (after, effects) = reducer.reduce(state, .spin)
        XCTAssertEqual(after.triesRemaining, 0)
        XCTAssertTrue(effects.contains(.rejected(.noTriesLeft)))
    }

    func testLockedTurnRejectsFurtherActions() {
        var state = startedTurn()
        // Bank two *word* faces specifically: a bonus face attaches to the turn
        // instead of filling the tray, and lock-in needs two words. Hard-coding
        // reels 0 and 1 made this depend on where the seed happened to put a bonus.
        let wordReels = state.reels.indices.filter { state.reels[$0].token?.word != nil }
        for reel in wordReels.prefix(2) {
            (state, _) = reducer.reduce(state, .bank(reel: reel))
        }
        XCTAssertEqual(state.tray.count, 2, "precondition: two words banked")

        (state, _) = reducer.reduce(state, .lockIn)
        XCTAssertEqual(state.phase, .locked, "precondition: the turn actually locked")

        let (_, effects) = reducer.reduce(state, .spin)
        XCTAssertEqual(effects, [.rejected(.turnAlreadyLocked)])
    }

    func testTrayCannotExceedItsLimit() {
        var config = EconomyConfig.default
        config.traySize = 2
        let small = Fixture.reducer(config: config)
        var state = small.startTurn(playerID: "p1", seed: 3)
        (state, _) = small.reduce(state, .spin)

        var rejected = false
        for reel in state.reels.indices {
            let (next, effects) = small.reduce(state, .bank(reel: reel))
            state = next
            if effects.contains(.rejected(.trayFull)) { rejected = true }
        }
        XCTAssertLessThanOrEqual(state.tray.count, 2)
        XCTAssertTrue(rejected)
    }

    // MARK: The dead-turn guard

    /// Property test: across many seeds, a player must always be able to reach a
    /// subject and a verb. A spin that offers neither is a dead turn, and dead
    /// turns are the fastest way to kill a party game.
    func testEverySpinOffersASubjectAndAVerb() {
        for seed in UInt64(0)..<300 {
            let (state, _) = reducer.replay(seed: seed, playerID: "p1", actions: [.spin])
            let words = state.reels.compactMap(\.token?.word)
            XCTAssertTrue(words.contains(where: \.isNounCapable), "seed \(seed): no noun-capable face")
            XCTAssertTrue(words.contains(where: \.isVerbCapable), "seed \(seed): no verb-capable face")
        }
    }

    /// Regression: seed 112 lands a verb and no noun, so the noun repair has to
    /// overwrite *something* — and it used to choose the lone verb, because only
    /// reels the repair had written itself were protected. The spin came back
    /// with no way to build a sentence at all.
    func testNounRepairPreservesANaturallyLandedVerb() {
        let (state, _) = reducer.replay(seed: 112, playerID: "p1", actions: [.spin])
        let words = state.reels.compactMap(\.token?.word)
        XCTAssertTrue(words.contains(where: \.isVerbCapable), "the lone verb was sacrificed to supply a noun")
        XCTAssertTrue(words.contains(where: \.isNounCapable))
    }

    /// The guarantee has to hold for the pool players actually spin. The fixture
    /// pool is small enough to hide this — the same defect showed on ~1% of
    /// opening spins against the shipped pool and on 2% of fixture seeds.
    func testShippedPoolAlwaysOffersASubjectAndAVerb() throws {
        let shipped = TurnReducer(config: .default, pool: try WordPool.bundled(), validator: Fixture.validator)
        for seed in UInt64(0)..<2000 {
            let (state, _) = shipped.replay(seed: seed, playerID: "p1", actions: [.spin])
            let words = state.reels.compactMap(\.token?.word)
            XCTAssertTrue(words.contains(where: \.isNounCapable), "seed \(seed): no noun-capable face")
            XCTAssertTrue(words.contains(where: \.isVerbCapable), "seed \(seed): no verb-capable face")
        }
    }

    func testVerbPityEngagesWhenTriesRunLowWithoutAVerb() {
        let config = EconomyConfig.default
        let resolver = SpinResolver(config: config, pool: Fixture.pool)
        var rng = SeededRNG(seed: 99)
        let context = SpinContext(
            trayEntries: [Fixture.dog],                       // noun banked, no verb
            triesRemaining: config.pityVerbTriesThreshold,    // running out
            excludedWords: []
        )
        let (_, diagnostics) = resolver.spin(reels: [0, 1, 2, 3, 4], context: context, rng: &rng)
        XCTAssertTrue(diagnostics.verbPityApplied)
    }

    func testPityStaysAsleepWhenTheTrayAlreadyHasAVerb() {
        let config = EconomyConfig.default
        let resolver = SpinResolver(config: config, pool: Fixture.pool)
        var rng = SeededRNG(seed: 99)
        let context = SpinContext(trayEntries: [Fixture.dog, Fixture.danced], triesRemaining: 1)
        let (_, diagnostics) = resolver.spin(reels: [0, 1, 2, 3, 4], context: context, rng: &rng)
        XCTAssertFalse(diagnostics.verbPityApplied)
    }

    func testSpinNeverRepeatsAWordAlreadyOnTheTable() {
        for seed in UInt64(0)..<100 {
            let (state, _) = reducer.replay(seed: seed, playerID: "p1", actions: [.spin])
            let texts = state.reels.compactMap(\.token?.word?.text)
            XCTAssertEqual(Set(texts).count, texts.count, "seed \(seed) produced a duplicate face")
        }
    }

    // MARK: Bonuses

    func testExtraTryGrantsASpinImmediately() {
        var state = startedTurn()
        let before = state.triesRemaining
        var effects: [Effect] = []
        // Force a known bonus onto a reel rather than fishing for one.
        state.reels[2] = ReelFace(token: .bonus(.extraTry))
        (state, effects) = reducer.reduce(state, .bank(reel: 2))
        XCTAssertEqual(state.triesRemaining, before + 1)
        XCTAssertTrue(effects.contains(.tryGranted(remaining: before + 1)))
    }

    func testWordGemAttachesToTheNextWordBankedOnly() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .bonus(.wordGem(multiplier: 3)))
        state.reels[1] = ReelFace(token: .word(Fixture.octopus))
        state.reels[2] = ReelFace(token: .word(Fixture.dog))

        (state, _) = reducer.reduce(state, .bank(reel: 0))
        (state, _) = reducer.reduce(state, .bank(reel: 1))
        (state, _) = reducer.reduce(state, .bank(reel: 2))

        XCTAssertEqual(state.tray[0].gemMultiplier, 3)
        XCTAssertEqual(state.tray[1].gemMultiplier, 1, "a gem must not bleed onto later words")
    }

    func testSentenceStarsAccumulate() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .bonus(.sentenceStar))
        state.reels[1] = ReelFace(token: .bonus(.sentenceStar))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        (state, _) = reducer.reduce(state, .bank(reel: 1))
        XCTAssertEqual(state.sentenceStars, 2)
    }

    func testRustDecaysWhileYouHesitate() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .bonus(.rust(entry: Fixture.octopus, remainingValue: 8)))
        (state, _) = reducer.reduce(state, .spin)
        guard case .bonus(.rust(_, let remaining))? = state.reels[0].token else {
            return XCTFail("expected the rust token to survive the spin")
        }
        XCTAssertEqual(remaining, 6)
    }

    func testRustBanksAtItsDecayedValue() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .bonus(.rust(entry: Fixture.octopus, remainingValue: 4)))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        XCTAssertEqual(state.tray.first?.entry.points, 4)
    }

    func testWildCardRequiresARealWord() {
        var state = startedTurn()
        state.heldBonuses = [.wildCard]
        let (rejectedState, effects) = reducer.reduce(state, .playWildCard(word: "zzzqx"))
        XCTAssertTrue(effects.contains(.rejected(.notAWord)))
        XCTAssertTrue(rejectedState.tray.isEmpty)

        let (acceptedState, _) = reducer.reduce(state, .playWildCard(word: "octopus"))
        XCTAssertEqual(acceptedState.tray.first?.entry.text, "octopus")
        XCTAssertTrue(acceptedState.heldBonuses.isEmpty)
    }

    func testSwapReturnsAWordAndRespinsItsReel() {
        var state = startedTurn()
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        state.heldBonuses = [.swap]
        let bankedText = state.tray[0].entry.text

        (state, _) = reducer.reduce(state, .useSwap(trayIndex: 0))
        XCTAssertTrue(state.tray.isEmpty)
        XCTAssertNotNil(state.reels[0].token)
        XCTAssertNotEqual(state.reels[0].token?.word?.text, bankedText)
        XCTAssertTrue(state.heldBonuses.isEmpty)
    }

    func testFrenzySpinsOneReelWithoutSpendingTries() {
        var state = startedTurn()
        state.heldBonuses = [.frenzy]
        (state, _) = reducer.reduce(state, .startFrenzy(reel: 1))
        let tries = state.triesRemaining

        (state, _) = reducer.reduce(state, .spin)
        (state, _) = reducer.reduce(state, .spin)
        XCTAssertEqual(state.triesRemaining, tries, "frenzy spins must be free")
        XCTAssertEqual(state.frenzySpinsUsed, 2)

        (state, _) = reducer.reduce(state, .endFrenzy)
        (state, _) = reducer.reduce(state, .spin)
        XCTAssertEqual(state.triesRemaining, tries - 1)
    }

    // MARK: Lock in

    func testLockInRequiresTwoWords() {
        var state = startedTurn()
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        let (_, effects) = reducer.reduce(state, .lockIn)
        XCTAssertTrue(effects.contains(.rejected(.needTwoWords)))
    }

    func testLockInEmitsAScoreAndFreezesTheTurn() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .word(Fixture.dog))
        state.reels[1] = ReelFace(token: .word(Fixture.danced))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        (state, _) = reducer.reduce(state, .bank(reel: 1))

        let (locked, effects) = reducer.reduce(state, .lockIn)
        XCTAssertEqual(locked.phase, .locked)
        guard case .sentenceLocked(let breakdown)? = effects.last else {
            return XCTFail("expected a score breakdown")
        }
        XCTAssertTrue(breakdown.isValidSentence)
        XCTAssertGreaterThan(breakdown.total, 0)
    }

    // MARK: Remove and restore — arranging is free, the spin is the bet

    func testRemovingAWordReturnsItToItsUntouchedReel() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .word(Fixture.octopus))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        XCTAssertTrue(state.reels[0].isEmpty, "banking should empty the face")

        let (after, effects) = reducer.reduce(state, .removeFromTray(index: 0))
        XCTAssertTrue(after.tray.isEmpty)
        XCTAssertEqual(after.reels[0].token?.word?.text, "octopus", "the word should reappear on its own reel")
        XCTAssertTrue(effects.contains(.wordReturnedToReel(reel: 0, word: "octopus")))
    }

    func testRemovingAWordAfterItsReelRespunDiscardsIt() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .word(Fixture.octopus))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        (state, _) = reducer.reduce(state, .spin)   // the reel moves on
        let newFace = state.reels[0].token?.word?.text

        let (after, effects) = reducer.reduce(state, .removeFromTray(index: 0))
        XCTAssertTrue(after.tray.isEmpty)
        XCTAssertEqual(after.reels[0].token?.word?.text, newFace, "the new face must not be clobbered")
        XCTAssertTrue(effects.contains(.wordDiscarded(word: "octopus")))
    }

    func testRemovingAWildCardWordIsAlwaysDiscarded() {
        var state = startedTurn()
        state.heldBonuses = [.wildCard]
        (state, _) = reducer.reduce(state, .playWildCard(word: "octopus"))

        let (after, effects) = reducer.reduce(state, .removeFromTray(index: 0))
        XCTAssertTrue(after.tray.isEmpty)
        XCTAssertTrue(effects.contains(.wordDiscarded(word: "octopus")))
        XCTAssertFalse(after.heldBonuses.contains(.wildCard), "the spent Wild Card is never refunded")
    }

    func testRemovingAGemmedWordDoesNotRefundTheGem() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .bonus(.wordGem(multiplier: 3)))
        state.reels[1] = ReelFace(token: .word(Fixture.octopus))
        (state, _) = reducer.reduce(state, .bank(reel: 0))   // collects the gem
        (state, _) = reducer.reduce(state, .bank(reel: 1))   // spends it on octopus
        XCTAssertEqual(state.tray.first?.gemMultiplier, 3)

        (state, _) = reducer.reduce(state, .removeFromTray(index: 0))
        XCTAssertEqual(state.reels[1].token?.word?.text, "octopus", "the word returns")
        XCTAssertNil(state.pendingGem, "the gem it was worth is gone, not refunded")
    }

    func testReorderingWithinTheTrayIsAlwaysFreeAndNeverCostsATry() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .word(Fixture.danced))
        state.reels[1] = ReelFace(token: .word(Fixture.dog))
        (state, _) = reducer.reduce(state, .bank(reel: 0))
        (state, _) = reducer.reduce(state, .bank(reel: 1))
        let tries = state.triesRemaining

        (state, _) = reducer.reduce(state, .reorder(from: 1, to: 0))
        XCTAssertEqual(state.triesRemaining, tries, "arranging your own tray must never cost a try")
        XCTAssertEqual(state.tray.map(\.entry.text), ["dog", "danced"])
    }

    func testReorderingChangesValidity() {
        var state = startedTurn()
        state.reels[0] = ReelFace(token: .word(Fixture.danced))
        state.reels[1] = ReelFace(token: .word(Fixture.dog))
        (state, _) = reducer.reduce(state, .bank(reel: 0))   // "danced"
        (state, _) = reducer.reduce(state, .bank(reel: 1))   // "danced dog" — not a sentence
        XCTAssertFalse(reducer.validator.validate(state.tray).isValid)

        (state, _) = reducer.reduce(state, .reorder(from: 1, to: 0))  // "dog danced"
        XCTAssertTrue(reducer.validator.validate(state.tray).isValid)
    }
}
