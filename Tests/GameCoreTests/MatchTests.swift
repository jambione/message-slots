import XCTest
@testable import GameCore

final class MatchTests: XCTestCase {
    private let reducer = Fixture.reducer()
    private var engine: MatchEngine { MatchEngine(reducer: reducer) }

    private func newMatch(mode: GameMode = .passAndPlay, players: Int = 2) -> MatchState {
        MatchState(
            mode: mode,
            players: (0..<players).map { Player(id: "p\($0)", name: "Player \($0)") },
            targetScore: 1_000,
            story: mode.usesStory ? Story(endingWord: "finally") : nil,
            seed: 2_024
        )
    }

    /// Plays one scripted turn: forces two known words onto reels, banks them, locks in.
    @discardableResult
    private func playTurn(_ match: inout MatchState, words: [WordEntry]) -> CompletedTurn {
        var state = engine.beginTurn(&match)
        let context = engine.context(for: match)
        (state, _) = reducer.reduce(state, .spin, context: context)
        for (i, word) in words.enumerated() where i < state.reels.count {
            state.reels[i] = ReelFace(token: .word(word))
        }
        for i in words.indices where i < state.reels.count {
            (state, _) = reducer.reduce(state, .bank(reel: i), context: context)
        }
        let (locked, effects) = reducer.reduce(state, .lockIn, context: context)
        guard case .sentenceLocked(let breakdown)? = effects.last(where: {
            if case .sentenceLocked = $0 { return true }; return false
        }) else {
            XCTFail("turn did not lock")
            return CompletedTurn(id: -1, playerID: "", playerName: "", seed: 0, actions: [],
                                 giftsReceived: [], sentence: "", words: [], breakdown: ScoreBreakdown())
        }
        return engine.completeTurn(&match, state: locked, breakdown: breakdown)
    }

    // MARK: Turn order and the shared bank

    func testTurnPassesToTheNextPlayer() {
        var match = newMatch()
        XCTAssertEqual(match.currentPlayer.id, "p0")
        playTurn(&match, words: [Fixture.dog, Fixture.danced])
        XCTAssertEqual(match.currentPlayer.id, "p1")
        playTurn(&match, words: [Fixture.cat, Fixture.danced])
        XCTAssertEqual(match.currentPlayer.id, "p0")
    }

    func testScoresPoolIntoOneTeamBank() {
        var match = newMatch()
        let first = playTurn(&match, words: [Fixture.dog, Fixture.danced])
        let second = playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.tangoed])
        XCTAssertEqual(match.teamBank, first.score + second.score)
    }

    func testStreakIsSharedAndBreaksOnWordSalad() {
        var match = newMatch()
        playTurn(&match, words: [Fixture.dog, Fixture.danced])
        XCTAssertEqual(match.teamStreak, 1)
        playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.tangoed])
        XCTAssertEqual(match.teamStreak, 2)

        playTurn(&match, words: [Fixture.dog, Fixture.cat])   // salad
        XCTAssertEqual(match.teamStreak, 0, "a teammate's rough turn is everyone's problem")
    }

    func testRoundsAdvanceAfterEveryPlayerHasTakenTwoTurns() {
        var match = newMatch(players: 2)
        XCTAssertEqual(match.roundIndex, 1)
        for _ in 0..<match.turnsPerRound {
            playTurn(&match, words: [Fixture.dog, Fixture.danced])
        }
        XCTAssertEqual(match.roundIndex, 2)
    }

    // MARK: Story mode

    func testStoryGrowsOneSentencePerTurn() {
        var match = newMatch(mode: .story)
        playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.danced])
        playTurn(&match, words: [Fixture.the, Fixture.dog, Fixture.sangWord])

        XCTAssertEqual(match.story?.sentences.count, 2)
        XCTAssertEqual(match.story?.sentences.first?.text, "The octopus danced.")
        XCTAssertEqual(match.story?.knownNouns.contains("octopus"), true)
    }

    func testContinuityRaisesTheChainAcrossTurns() {
        var match = newMatch(mode: .story)
        playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.danced])
        playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.tangoed])
        XCTAssertEqual(match.story?.chainLevel, 1)
    }

    // MARK: Gifts

    func testGiftLandsOnTheNextPlayerAtHigherPotency() {
        var match = newMatch()
        var state = engine.beginTurn(&match)
        let context = engine.context(for: match)
        (state, _) = reducer.reduce(state, .spin, context: context)
        state.reels[0] = ReelFace(token: .word(Fixture.dog))
        state.reels[1] = ReelFace(token: .word(Fixture.danced))
        state.reels[2] = ReelFace(token: .bonus(.gift))
        (state, _) = reducer.reduce(state, .bank(reel: 0), context: context)
        (state, _) = reducer.reduce(state, .bank(reel: 1), context: context)
        (state, _) = reducer.reduce(state, .bank(reel: 2), context: context)
        XCTAssertTrue(state.heldBonuses.contains(.gift))

        let (locked, effects) = reducer.reduce(state, .lockIn, context: context)
        guard case .sentenceLocked(let breakdown)? = effects.last else { return XCTFail("no score") }
        engine.completeTurn(&match, state: locked, breakdown: breakdown)

        XCTAssertFalse(match.pendingGifts["p1"]?.isEmpty ?? true, "the gift should be waiting for the next player")

        // And it is applied as their turn opens.
        let next = engine.beginTurn(&match)
        let boosted = next.receivedGifts.first
        XCTAssertNotNil(boosted)
        XCTAssertTrue(match.pendingGifts["p1"]?.isEmpty ?? false, "gifts are consumed once applied")
    }

    // MARK: Remote play

    func testAnHonestTurnVerifiesOnAnotherDevice() {
        var match = newMatch()
        let context = engine.context(for: match)
        var state = engine.beginTurn(&match)
        for action in [TurnAction.spin, .bank(reel: 0), .spin, .bank(reel: 1)] {
            (state, _) = reducer.reduce(state, action, context: context)
        }
        let (locked, effects) = reducer.reduce(state, .lockIn, context: context)
        guard case .sentenceLocked(let breakdown)? = effects.last else { return XCTFail("no score") }
        let turn = engine.completeTurn(&match, state: locked, breakdown: breakdown)

        // The receiving phone re-runs the turn from (seed, actions) alone.
        XCTAssertTrue(engine.verify(turn, context: context))
    }

    func testATamperedScoreFailsVerification() {
        var match = newMatch()
        let context = engine.context(for: match)
        var state = engine.beginTurn(&match)
        for action in [TurnAction.spin, .bank(reel: 0), .spin, .bank(reel: 1)] {
            (state, _) = reducer.reduce(state, action, context: context)
        }
        let (locked, effects) = reducer.reduce(state, .lockIn, context: context)
        guard case .sentenceLocked(var breakdown)? = effects.last else { return XCTFail("no score") }
        var turn = engine.completeTurn(&match, state: locked, breakdown: breakdown)

        breakdown.total = 999_999
        turn = CompletedTurn(
            id: turn.id, playerID: turn.playerID, playerName: turn.playerName,
            seed: turn.seed, actions: turn.actions, giftsReceived: turn.giftsReceived,
            sentence: turn.sentence, words: turn.words, breakdown: breakdown, verdict: nil
        )
        XCTAssertFalse(engine.verify(turn, context: context))
    }

    func testMatchStateSurvivesTheWire() throws {
        var match = newMatch(mode: .story)
        playTurn(&match, words: [Fixture.the, Fixture.octopus, Fixture.danced])

        let data = try JSONEncoder().encode(match)
        let restored = try JSONDecoder().decode(MatchState.self, from: data)
        XCTAssertEqual(match, restored)

        // Small enough for a Game Center turn payload.
        XCTAssertLessThan(data.count, 64 * 1024)
    }

    func testAMatchCanChangeTransportMidGame() {
        var match = newMatch()
        playTurn(&match, words: [Fixture.dog, Fixture.danced])
        let bankBefore = match.teamBank

        // Someone has to leave: finish the same match asynchronously.
        match.connectivity = .remoteAsync
        playTurn(&match, words: [Fixture.cat, Fixture.danced])

        XCTAssertGreaterThan(match.teamBank, bankBefore, "rules must not change with the transport")
        XCTAssertEqual(match.history.count, 2)
    }

    // MARK: Judge

    func testJudgeAwardIsCappedAndOptional() async {
        let verdict = JudgeVerdict(readsAsSentence: true, awardTitle: "Most Cinematic", awardPoints: 5_000)
        XCTAssertEqual(verdict.awardPoints, SentenceJudgeLimits.maxAwardPoints)

        let none = await NoJudge().judge(sentence: "The dog danced.", storySoFar: nil)
        XCTAssertEqual(none.awardPoints, 0)
    }

    func testASlowJudgeCannotStallTheResultsScreen() async {
        struct SlowJudge: SentenceJudge {
            func judge(sentence: String, storySoFar: String?) async -> JudgeVerdict {
                try? await Task.sleep(for: .seconds(5))
                return JudgeVerdict(readsAsSentence: true, awardTitle: "Too Late", awardPoints: 50)
            }
        }
        let judge = TimeLimitedJudge(SlowJudge(), limit: .milliseconds(50))
        let verdict = await judge.judge(sentence: "The dog danced.", storySoFar: nil)
        XCTAssertNil(verdict.awardTitle)
    }
}

private extension Fixture {
    static let sangWord = Fixture.word("sang", .verb, points: 2)
}
