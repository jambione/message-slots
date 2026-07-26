import Foundation
@testable import GameCore

/// Hand-built fixtures so tests never depend on the shipping content.
enum Fixture {

    // MARK: Categories

    /// A deliberately small category with good short-word coverage, so tests
    /// can reason about exactly which words are reachable.
    static let animals = WordCategory(
        id: "animals",
        name: "Animals",
        hint: "Any creature",
        words: ["CAT", "COW", "DOG", "RAT", "BAT", "OWL", "APE", "BEAR", "CRAB", "GOAT", "TIGER"]
    )

    /// Long words only — models the real "musical instruments" problem, where a
    /// category is nearly unplayable without the resolver biasing letters.
    static let longOnly = WordCategory(
        id: "long",
        name: "Long Things",
        words: ["ACCORDION", "HARPSICHORD", "SAXOPHONE"]
    )

    static var pack: CategoryPack {
        CategoryPack(id: "test", categories: [animals, longOnly])
    }

    // MARK: Tiles

    static func tile(_ letter: Character, blank: Bool = false) -> LetterTile {
        LetterTile(letter, isBlank: blank)
    }

    /// Builds a tray spelling `word`, assigning ids in order.
    static func tray(_ word: String, multipliers: [Int: Int] = [:], blanks: Set<Int> = []) -> [PlacedLetter] {
        Array(word.uppercased()).enumerated().map { index, letter in
            PlacedLetter(
                id: index,
                tile: LetterTile(letter, isBlank: blanks.contains(index)),
                multiplier: multipliers[index] ?? 1,
                sourceReel: index
            )
        }
    }

    // MARK: Engine

    static func reducer(config: EconomyConfig = .default) -> TurnReducer {
        TurnReducer(config: config)
    }

    static func turn(
        category: WordCategory = Fixture.animals,
        config: EconomyConfig = .default,
        seed: UInt64 = 20_260_726
    ) -> TurnState {
        TurnState(
            playerID: "test",
            categoryID: category.id,
            categoryName: category.name,
            config: config,
            rng: SeededRNG(seed: seed)
        )
    }

    static func context(
        category: WordCategory = Fixture.animals,
        streak: Int = 0
    ) -> TurnContext {
        TurnContext(mode: .passAndPlay, teamStreak: streak, category: category)
    }

    /// Forces specific letters onto the reels so a test can bank deterministically.
    static func withReels(_ state: TurnState, _ letters: String) -> TurnState {
        var state = state
        state.phase = .playing
        for (index, letter) in Array(letters.uppercased()).enumerated() where index < state.reels.count {
            state.reels[index] = ReelFace(token: .letter(LetterTile(letter)))
        }
        return state
    }
}
