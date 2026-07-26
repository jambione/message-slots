import Foundation

// MARK: - Word categories (parts of speech)

/// Every word token belongs to one or more grammatical categories. These drive
/// reel roles, the sentence grammar, the pity system and the tray's colour
/// coding, so this is the single most important taxonomy in the game.
///
/// The six core categories players actually think about:
///
///   noun · verb · adjective · adverb · conjunction · preposition
///
/// plus two function-word categories the grammar needs in order to accept
/// natural sentences (`article`, `pronoun`). They are grouped with conjunctions
/// and prepositions as "glue" — low points, high utility.
public enum PartOfSpeech: String, Codable, Hashable, Sendable, CaseIterable {
    /// A person, place, thing or idea — *octopus*, *lighthouse*.
    case noun = "NOUN"
    /// An action or state — *tangoed*, *is*.
    case verb = "VERB"
    /// Describes a noun — *grumpy*, *iridescent*.
    case adjective = "ADJ"
    /// Modifies a verb or adjective — *magnificently*, *slowly*.
    case adverb = "ADV"
    /// Joins clauses — *and*, *because*, *meanwhile*. The engine of Story Mode.
    case conjunction = "CONJ"
    /// Relates a noun to the rest of the sentence — *under*, *beyond*.
    case preposition = "PREP"
    /// Determiner — *the*, *a*, *every*.
    case article = "ART"
    /// Stands in for a noun — *it*, *they*. Carries story callbacks.
    case pronoun = "PRON"

    /// The six categories surfaced in the UI legend and tutorial.
    public static let coreCategories: [PartOfSpeech] = [.noun, .verb, .adjective, .adverb, .conjunction, .preposition]

    /// Words that can anchor a subject or object.
    public var isNounLike: Bool { self == .noun || self == .pronoun }

    /// The connective tissue that makes sentences legal. Pools starved of these
    /// produce beautiful words that can never form a sentence.
    public var isGlue: Bool {
        switch self {
        case .article, .pronoun, .conjunction, .preposition: return true
        default: return false
        }
    }

    /// Player-facing category name.
    public var displayName: String {
        switch self {
        case .noun: return "noun"
        case .verb: return "verb"
        case .adjective: return "adjective"
        case .adverb: return "adverb"
        case .conjunction: return "conjunction"
        case .preposition: return "preposition"
        case .article: return "article"
        case .pronoun: return "pronoun"
        }
    }

    /// Short tag shown on the token itself.
    public var abbreviation: String {
        switch self {
        case .noun: return "n."
        case .verb: return "v."
        case .adjective: return "adj."
        case .adverb: return "adv."
        case .conjunction: return "conj."
        case .preposition: return "prep."
        case .article: return "art."
        case .pronoun: return "pron."
        }
    }

    /// Accepts the legacy `CONN` spelling from older content files.
    public init?(rawValue: String) {
        switch rawValue.uppercased() {
        case "NOUN": self = .noun
        case "VERB": self = .verb
        case "ADJ": self = .adjective
        case "ADV": self = .adverb
        case "CONJ", "CONN": self = .conjunction
        case "PREP": self = .preposition
        case "ART", "DET": self = .article
        case "PRON": self = .pronoun
        default: return nil
        }
    }
}

// MARK: - Rarity

public enum Rarity: String, Codable, Hashable, Sendable, CaseIterable {
    case common, uncommon, rare, legendary
}

// MARK: - Word entry

/// One row of a word pool. Immutable content, loaded from a compiled JSON pool.
public struct WordEntry: Codable, Hashable, Sendable {
    public let text: String
    public let pos: Set<PartOfSpeech>
    public let tier: Rarity
    public let points: Int
    public let tags: [String]
    /// Hand-authored semantic class(es) — e.g. a noun's kind, or the subject
    /// kinds a verb plausibly takes. Optional and sparse by design: an
    /// untagged word simply has no opinion in coherence scoring rather than
    /// being treated as wrong (see Language/SemanticCoherence.swift).
    public let semantics: Set<SemanticCategory>

    /// How often this word should surface relative to others of its category.
    ///
    /// Rarity already controls *value*; this controls *frequency*, and they are
    /// not the same thing. Every determiner in the pool is `common`, but "the"
    /// and "a" carry far more of real English than "every" or "some" — left
    /// equally weighted, the determiner slot spread across ten words and the two
    /// that sentences actually need showed up on roughly 6% of spins, so trays
    /// read "Friend ate" instead of "The friend ate".
    ///
    /// 1.0 is the neutral default, so a pool that never sets this behaves
    /// exactly as it did before.
    public let weight: Double

    public init(
        text: String, pos: Set<PartOfSpeech>, tier: Rarity, points: Int,
        tags: [String] = [], semantics: Set<SemanticCategory> = [], weight: Double = 1.0
    ) {
        self.text = text
        self.pos = pos
        self.tier = tier
        self.points = points
        self.tags = tags
        self.semantics = semantics
        self.weight = weight
    }

    public func can(be part: PartOfSpeech) -> Bool { pos.contains(part) }
    public var isNounCapable: Bool { pos.contains(.noun) || pos.contains(.pronoun) }
    public var isVerbCapable: Bool { pos.contains(.verb) }

    /// Words that can play more than one role are strictly more useful, so the
    /// design grants them a small premium (GAME_DESIGN.md §3.1).
    public var effectivePoints: Int { pos.count > 1 ? points + 1 : points }

    private enum CodingKeys: String, CodingKey { case text, pos, tier, points, tags, semantics, weight }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        pos = Set(try c.decode([PartOfSpeech].self, forKey: .pos))
        tier = try c.decode(Rarity.self, forKey: .tier)
        points = try c.decode(Int.self, forKey: .points)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // Absent in older compiled pools — decodes to "no opinion", never "wrong".
        semantics = Set(try c.decodeIfPresent([SemanticCategory].self, forKey: .semantics) ?? [])
        // Absent means neutral frequency, so old pools spin exactly as before.
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(pos.map(\.rawValue).sorted(), forKey: .pos)
        try c.encode(tier, forKey: .tier)
        try c.encode(points, forKey: .points)
        try c.encode(tags, forKey: .tags)
        if !semantics.isEmpty {
            try c.encode(semantics.map(\.rawValue).sorted(), forKey: .semantics)
        }
        if weight != 1.0 {
            try c.encode(weight, forKey: .weight)
        }
    }
}

// MARK: - Bonus tokens

/// The complete bonus set from GAME_DESIGN.md §3.2.
public enum BonusKind: Codable, Hashable, Sendable {
    /// Multiplies the value of the next word banked.
    case wordGem(multiplier: Int)
    /// Multiplies the final sentence score.
    case sentenceStar
    /// +1 spin this turn.
    case extraTry
    /// Unlimited free re-spins of one reel for a short window.
    case frenzy
    /// Becomes any dictionary word the player types.
    case wildCard
    /// Return a banked word to its reel and re-spin it free.
    case swap
    /// Passes a bonus to your teammate's next turn, at +1 potency.
    case gift
    /// A high-value word that decays while you hesitate.
    case rust(entry: WordEntry, remainingValue: Int)

    /// Bonuses the player keeps until they choose to use them.
    public var isHeld: Bool {
        switch self {
        case .swap, .gift, .wildCard: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .wordGem(let m): return "×\(m) Word Gem"
        case .sentenceStar: return "Sentence Star"
        case .extraTry: return "Extra Try"
        case .frenzy: return "Free Spin Frenzy"
        case .wildCard: return "Wild Card"
        case .swap: return "Swap Token"
        case .gift: return "Gift Token"
        case .rust(let e, let v): return "Rust: \(e.text) (\(v))"
        }
    }
}

// MARK: - Tokens

/// What a reel can land on.
public enum Token: Codable, Hashable, Sendable {
    case word(WordEntry)
    case bonus(BonusKind)

    public var word: WordEntry? {
        if case .word(let e) = self { return e }
        if case .bonus(.rust(let e, _)) = self { return e }
        return nil
    }

    public var isBonus: Bool { if case .bonus = self { return true }; return false }
}

// MARK: - Tray

/// A word committed to the player's sentence.
public struct PlacedWord: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let entry: WordEntry
    /// Gem multiplier applied at bank time (1 = none).
    public var gemMultiplier: Int
    /// True when this word came from a Wild Card rather than a reel.
    public var isWild: Bool
    /// Index of the reel it was banked from, or nil for wilds. Used by the
    /// "all five original reels" style bonus.
    public var sourceReel: Int?

    public init(id: Int, entry: WordEntry, gemMultiplier: Int = 1, isWild: Bool = false, sourceReel: Int? = nil) {
        self.id = id
        self.entry = entry
        self.gemMultiplier = gemMultiplier
        self.isWild = isWild
        self.sourceReel = sourceReel
    }

    public var value: Int { entry.effectivePoints * gemMultiplier }
}

// MARK: - Players and modes

/// How good the CPU is at building a sentence. Skill changes patience and
/// ambition, never the rules — a CPU teammate plays the same game you do.
public enum CPUSkill: String, Codable, Hashable, Sendable, CaseIterable {
    /// Grabs the first thing that works. Fun, a bit chaotic, easy to out-score.
    case rookie
    /// Sensible: completes the sentence, then extends while the odds look good.
    case steady
    /// Patient. Holds out for rare words and bonus tokens, banks late.
    case sharp

    /// Minimum word value the bot will spend a slot on early in a turn.
    var greedThreshold: Int {
        switch self {
        case .rookie: return 1
        case .steady: return 2
        case .sharp: return 4
        }
    }

    /// How many words it tries to reach before locking in.
    var targetLength: Int {
        switch self {
        case .rookie: return 3
        case .steady: return 5
        case .sharp: return 7
        }
    }
}

public enum PlayerKind: Codable, Hashable, Sendable {
    case human
    case cpu(skill: CPUSkill)

    public var isCPU: Bool { if case .cpu = self { return true }; return false }
}

public struct Player: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var kind: PlayerKind
    /// Set when the player is on their own device (remote / same-room play).
    public var remoteID: String?

    public init(id: String = UUID().uuidString, name: String, kind: PlayerKind = .human, remoteID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.remoteID = remoteID
    }

    /// A CPU teammate. Names are deliberately warm — this is a co-op partner,
    /// not an opponent.
    public static func cpu(_ skill: CPUSkill = .steady, name: String? = nil, id: String = UUID().uuidString) -> Player {
        let defaultNames: [CPUSkill: String] = [.rookie: "Sprocket", .steady: "Wordsworth", .sharp: "Professor Cogsworth"]
        return Player(id: id, name: name ?? defaultNames[skill] ?? "CPU", kind: .cpu(skill: skill))
    }

    public var isCPU: Bool { kind.isCPU }
}

public enum GameMode: String, Codable, Hashable, Sendable, CaseIterable {
    case passAndPlay
    case story
    case beatTheHouse
    case solo
    case dailySpin

    /// Story combos only apply where there is a story to build on.
    public var usesStory: Bool { self == .story }
}

/// How the players' devices are connected. The rules never differ by transport
/// (GAME_DESIGN.md §5.2) — this only tells the UI how to route turns.
public enum Connectivity: String, Codable, Hashable, Sendable {
    case localDevice     // pass and play
    case remoteAsync     // Game Center turn based
    case sameRoomLive    // MultipeerConnectivity
}
