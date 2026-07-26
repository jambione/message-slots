import Foundation
@testable import GameCore

/// Hand-built fixtures so tests never depend on the shipping pool's contents.
enum Fixture {
    static func word(
        _ text: String, _ pos: PartOfSpeech..., tier: Rarity = .common, points: Int = 1,
        tags: [String] = [], semantics: Set<SemanticCategory> = [], weight: Double = 1.0
    ) -> WordEntry {
        WordEntry(text: text, pos: Set(pos), tier: tier, points: points,
                  tags: tags, semantics: semantics, weight: weight)
    }

    static let the = word("the", .article)
    static let a = word("a", .article)
    static let dog = word("dog", .noun)
    static let cat = word("cat", .noun)
    static let octopus = word("octopus", .noun, tier: .uncommon, points: 5)
    static let grumpy = word("grumpy", .adjective, points: 2)
    static let tangoed = word("tangoed", .verb, tier: .uncommon, points: 5)
    static let danced = word("danced", .verb, points: 2)
    static let magnificently = word("magnificently", .adverb, tier: .uncommon, points: 7)
    static let quickly = word("quickly", .adverb, points: 2)
    static let under = word("under", .preposition)
    static let table = word("table", .noun)
    static let and = word("and", .conjunction)
    static let meanwhile = word("meanwhile", .conjunction, tier: .uncommon, points: 4)
    static let it = word("it", .pronoun)
    static let they = word("they", .pronoun)
    static let happy = word("happy", .adjective)
    static let isVerb = word("is", .verb, semantics: Set(SemanticCategory.allCases))
    static let banana = word("banana", .noun, points: 2)
    static let pirate = word("pirate", .noun, points: 2, tags: ["pirate"])
    static let finally = word("finally", .adverb, tier: .uncommon, points: 3, tags: ["ending"])

    // MARK: Semantic coherence fixtures
    // A compatible pair (parrot/flew both "animate"), an incompatible-but-still-
    // grammatical pair (parrot/overflowed — no shared category), and an
    // untagged pair reusing `dog`/`danced` above, all live side by side so
    // tests can assert the bonus fires, silently doesn't, and never rejects.
    static let parrot = word("parrot", .noun, points: 2, semantics: [.animate])
    static let flew = word("flew", .verb, points: 2, semantics: [.animate])
    static let pond = word("pond", .noun, points: 2, semantics: [.place])
    static let overflowed = word("overflowed", .verb, points: 2, semantics: [.place, .object])
    static let melted = word("melted", .verb, points: 2, semantics: [.food, .object, .abstract])

    /// Builds a tray, assigning ids in order.
    static func tray(_ entries: [WordEntry], gems: [Int: Int] = [:], sourceReels: Bool = false) -> [PlacedWord] {
        entries.enumerated().map { index, entry in
            PlacedWord(
                id: index,
                entry: entry,
                gemMultiplier: gems[index] ?? 1,
                isWild: false,
                sourceReel: sourceReels ? index : nil
            )
        }
    }

    /// A small but sentence-capable pool for engine tests.
    static var pool: WordPool {
        WordPool(id: "test", words: [
            the, a, dog, cat, octopus, grumpy, tangoed, danced, magnificently, they,
            quickly, under, table, and, meanwhile, it, happy, isVerb, banana,
            pirate, finally, parrot, flew, pond, overflowed, melted,
            word("ran", .verb),
            word("sang", .verb, points: 2),
            word("moon", .noun, points: 2),
            word("robot", .noun, points: 2),
            word("tiny", .adjective, points: 2),
            word("because", .conjunction, points: 2),
            word("beyond", .preposition, tier: .uncommon, points: 3),
            word("kerfuffle", .noun, tier: .legendary, points: 10),
            word("flabbergasted", .verb, tier: .rare, points: 8),
            word("iridescent", .adjective, tier: .rare, points: 7)
        ])
    }

    static var validator: SentenceValidator { SentenceValidator() }

    static func reducer(config: EconomyConfig = .default) -> TurnReducer {
        TurnReducer(config: config, pool: pool, validator: validator)
    }
}
