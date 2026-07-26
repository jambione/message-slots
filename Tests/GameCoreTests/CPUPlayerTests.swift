import XCTest
@testable import GameCore

final class CPUPlayerTests: XCTestCase {

    private func engine() -> MatchEngine {
        MatchEngine(reducer: Fixture.reducer(), pack: Fixture.pack)
    }

    private func match() -> MatchState {
        MatchState(
            players: [Player(id: "a", name: "Ann"), Player.cpu(.steady, id: "bot")],
            targetScore: 300,
            seed: 31_337
        )
    }

    /// The bot must actually solve the puzzle, not flail. Whatever it submits
    /// has to be a real member of the category.
    func testEverySkillSubmitsAWordInTheCategory() {
        for skill in CPUSkill.allCases {
            let engine = engine()
            var match = match()
            let (state, _, breakdown) = engine.playCPUTurn(&match, skill: skill)
            let category = engine.category(for: match)

            guard let breakdown else {
                XCTFail("\(skill) never locked in a word")
                continue
            }
            XCTAssertTrue(
                category.accepts(breakdown.word),
                "\(skill) submitted \(breakdown.word), which isn't in \(category.name)"
            )
            XCTAssertEqual(state.phase, .locked)
        }
    }

    func testCPUTurnsAreDeterministic() {
        func run() -> String {
            let engine = engine()
            var match = match()
            let (_, _, breakdown) = engine.playCPUTurn(&match, skill: .steady)
            return breakdown?.word ?? ""
        }
        XCTAssertEqual(run(), run(), "a replayed CPU turn must play identically")
    }

    /// Skill is patience and ambition, never privilege — but it should still
    /// show up in the results.
    func testSharperSkillsReachLongerWordsOnAverage() {
        func averageLength(_ skill: CPUSkill) -> Double {
            var total = 0
            var count = 0
            for seed in UInt64(1)...25 {
                let engine = engine()
                var match = MatchState(
                    players: [Player.cpu(skill, id: "bot")],
                    targetScore: 9_999,
                    seed: seed &* 7919
                )
                let (_, _, breakdown) = engine.playCPUTurn(&match, skill: skill)
                if let breakdown, !breakdown.word.isEmpty {
                    total += breakdown.word.count
                    count += 1
                }
            }
            return count == 0 ? 0 : Double(total) / Double(count)
        }

        XCTAssertGreaterThanOrEqual(
            averageLength(.sharp), averageLength(.rookie),
            "a patient bot should not do worse than a hasty one"
        )
    }

    /// A bot playing by different rules would be detectable, and the moment a
    /// player suspects that, the co-op framing collapses.
    func testCPUPlaysThroughTheSameReducer() {
        let engine = engine()
        var match = match()
        let (state, _, _) = engine.playCPUTurn(&match, skill: .steady)

        // Replaying the bot's own action log must reproduce its turn exactly.
        var replay = TurnState(
            playerID: state.playerID,
            categoryID: state.categoryID,
            categoryName: state.categoryName,
            config: engine.reducer.config,
            rng: SeededRNG(seed: state.rng.seed)
        )
        let context = engine.context(for: match)
        for action in state.actionLog {
            (replay, _) = engine.reducer.reduce(replay, action, context: context)
        }
        XCTAssertEqual(replay.word, state.word)
    }

    func testCPUNeverSpendsMoreThanItsTries() {
        let engine = engine()
        var match = match()
        let (state, _, _) = engine.playCPUTurn(&match, skill: .sharp)
        XCTAssertGreaterThanOrEqual(state.triesRemaining, 0)
    }
}
