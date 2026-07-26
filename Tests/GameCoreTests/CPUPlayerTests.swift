import XCTest
@testable import GameCore

final class CPUPlayerTests: XCTestCase {
    private let reducer = Fixture.reducer()

    private func bot(_ skill: CPUSkill) -> CPUPlayer { CPUPlayer(skill: skill, reducer: reducer) }

    // MARK: It finishes, and it finishes legally

    func testBotAlwaysCompletesItsTurn() {
        for seed in UInt64(0)..<120 {
            let start = reducer.startTurn(playerID: "cpu", seed: seed)
            let (finished, breakdown) = bot(.steady).playTurn(start, context: TurnContext())
            XCTAssertEqual(finished.phase, .locked, "seed \(seed): bot failed to finish its turn")
            XCTAssertNotNil(breakdown, "seed \(seed): no score produced")
            XCTAssertGreaterThan(breakdown?.total ?? 0, 0)
        }
    }

    func testBotUsuallyBuildsAValidSentence() {
        var valid = 0
        let trials = 120
        for seed in UInt64(0)..<UInt64(trials) {
            let start = reducer.startTurn(playerID: "cpu", seed: seed)
            let (_, breakdown) = bot(.steady).playTurn(start, context: TurnContext())
            if breakdown?.isValidSentence == true { valid += 1 }
        }
        let rate = Double(valid) / Double(trials)
        XCTAssertGreaterThan(rate, 0.75, "a steady CPU teammate should mostly produce sentences (got \(rate))")
    }

    func testBotNeverExceedsItsTries() {
        for seed in UInt64(0)..<60 {
            let start = reducer.startTurn(playerID: "cpu", seed: seed)
            let (finished, _) = bot(.sharp).playTurn(start, context: TurnContext())
            XCTAssertGreaterThanOrEqual(finished.triesRemaining, 0)
            XCTAssertLessThanOrEqual(finished.tray.count, EconomyConfig.default.traySize)
        }
    }

    // MARK: Determinism — bot turns must replay like human ones

    func testBotTurnsAreDeterministicAndReplayable() {
        let start = reducer.startTurn(playerID: "cpu", seed: 777)
        let (finished, breakdown) = bot(.steady).playTurn(start, context: TurnContext())

        let (replayed, _) = reducer.replay(seed: 777, playerID: "cpu", actions: finished.actionLog)
        XCTAssertEqual(replayed.tray.map(\.entry.text), finished.tray.map(\.entry.text))
        XCTAssertEqual(replayed.triesRemaining, finished.triesRemaining)
        XCTAssertNotNil(breakdown)
    }

    func testBotTurnVerifiesLikeAHumanTurn() {
        var match = MatchState(
            mode: .passAndPlay,
            players: [Player.cpu(.steady, id: "cpu0"), Player(id: "p1", name: "You")],
            seed: 5
        )
        let engine = MatchEngine(reducer: reducer)
        let context = engine.context(for: match)
        guard let turn = engine.playCPUTurn(&match) else { return XCTFail("CPU turn did not complete") }

        XCTAssertTrue(engine.verify(turn, context: context), "a CPU turn must be verifiable by the same rules")
        XCTAssertEqual(match.currentPlayer.id, "p1", "turn should pass to the human")
        XCTAssertGreaterThan(match.teamBank, 0)
    }

    // MARK: Skill actually means something

    func testSharperSkillScoresHigherOnAverage() {
        func averageScore(_ skill: CPUSkill) -> Double {
            var total = 0
            let trials = 80
            for seed in UInt64(0)..<UInt64(trials) {
                let start = reducer.startTurn(playerID: "cpu", seed: seed)
                let (_, breakdown) = bot(skill).playTurn(start, context: TurnContext())
                total += breakdown?.total ?? 0
            }
            return Double(total) / Double(trials)
        }
        XCTAssertGreaterThan(averageScore(.sharp), averageScore(.rookie))
    }

    func testRookieBanksFasterThanSharp() {
        func averageLength(_ skill: CPUSkill) -> Double {
            var total = 0
            let trials = 60
            for seed in UInt64(0)..<UInt64(trials) {
                let start = reducer.startTurn(playerID: "cpu", seed: seed)
                let (finished, _) = bot(skill).playTurn(start, context: TurnContext())
                total += finished.tray.count
            }
            return Double(total) / Double(trials)
        }
        XCTAssertLessThan(averageLength(.rookie), averageLength(.sharp))
    }

    // MARK: Mixed matches

    func testHumanAndCPUCanShareAMatch() {
        var match = MatchState(
            mode: .story,
            players: [Player(id: "p0", name: "You"), Player.cpu(.steady, id: "cpu1")],
            story: Story(endingWord: "finally"),
            seed: 11
        )
        let engine = MatchEngine(reducer: reducer)

        // Human turn.
        var state = engine.beginTurn(&match)
        let context = engine.context(for: match)
        (state, _) = reducer.reduce(state, .spin, context: context)
        state.reels[0] = ReelFace(token: .word(Fixture.the))
        state.reels[1] = ReelFace(token: .word(Fixture.octopus))
        state.reels[2] = ReelFace(token: .word(Fixture.danced))
        for reel in 0...2 { (state, _) = reducer.reduce(state, .bank(reel: reel), context: context) }
        let (locked, effects) = reducer.reduce(state, .lockIn, context: context)
        guard case .sentenceLocked(let breakdown)? = effects.last else { return XCTFail("no score") }
        engine.completeTurn(&match, state: locked, breakdown: breakdown)

        // CPU teammate answers.
        XCTAssertTrue(match.currentPlayer.isCPU)
        XCTAssertNotNil(engine.playCPUTurn(&match))
        XCTAssertEqual(match.story?.sentences.count, 2)
        XCTAssertEqual(match.currentPlayer.id, "p0")
    }

    func testPlayCPUTurnDeclinesForHumanPlayers() {
        var match = MatchState(mode: .passAndPlay, players: [Player(id: "p0", name: "You")], seed: 1)
        let engine = MatchEngine(reducer: reducer)
        XCTAssertNil(engine.playCPUTurn(&match))
    }
}
