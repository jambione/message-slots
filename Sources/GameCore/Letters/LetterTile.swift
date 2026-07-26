import Foundation

/// A single letter on a reel.
///
/// Values are the standard English Scrabble set. They aren't arbitrary — they
/// encode how hard a letter is to use, which is exactly the information a
/// player needs to judge a risk. Everyone already knows Q is worth a lot and
/// hard to place, so the scoring is legible from the first turn with nothing to
/// teach.
public struct LetterTile: Codable, Hashable, Sendable {
    /// Always uppercase A–Z. A blank carries the letter it was assigned.
    public let letter: Character
    /// True for a wild tile. Blanks score zero, exactly as in Scrabble — the
    /// flexibility *is* the payment.
    public let isBlank: Bool

    public init(_ letter: Character, isBlank: Bool = false) {
        self.letter = Character(letter.uppercased())
        self.isBlank = isBlank
    }

    /// Points this tile contributes.
    public var value: Int { isBlank ? 0 : LetterTile.value(of: letter) }

    public var text: String { String(letter) }

    // MARK: Scrabble values

    /// Standard English Scrabble point values.
    public static func value(of letter: Character) -> Int {
        switch Character(letter.uppercased()) {
        case "A", "E", "I", "O", "U", "L", "N", "S", "T", "R": return 1
        case "D", "G":                                          return 2
        case "B", "C", "M", "P":                                return 3
        case "F", "H", "V", "W", "Y":                           return 4
        case "K":                                               return 5
        case "J", "X":                                          return 8
        case "Q", "Z":                                          return 10
        default:                                                return 0
        }
    }

    /// Rarity band, used for the reel's visual treatment. Derived from value so
    /// the colour coding and the score always agree.
    public var band: LetterBand {
        switch value {
        case 0:      return .blank
        case 1:      return .common
        case 2...3:  return .uncommon
        case 4...5:  return .rare
        default:     return .legendary
        }
    }

    private enum CodingKeys: String, CodingKey { case letter, isBlank }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .letter)
        letter = Character(raw.uppercased())
        isBlank = try c.decodeIfPresent(Bool.self, forKey: .isBlank) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(letter), forKey: .letter)
        if isBlank { try c.encode(true, forKey: .isBlank) }
    }
}

public enum LetterBand: String, Codable, Hashable, Sendable, CaseIterable {
    case blank, common, uncommon, rare, legendary
}

// MARK: - Letter bag

/// The distribution letters are drawn from.
///
/// This is the Scrabble 100-tile distribution, and it is doing the same job the
/// word-frequency `weight` field did in the sentence version: E appears twelve
/// times and Q once because that is roughly how often English needs them. Draw
/// uniformly from the alphabet instead and most racks become unusable — the
/// distribution is what makes a random handful of letters spellable at all.
public struct LetterBag: Codable, Hashable, Sendable {
    /// letter → how many of that tile exist in a standard set.
    public static let standardDistribution: [Character: Int] = [
        "A": 9, "B": 2, "C": 2, "D": 4, "E": 12, "F": 2, "G": 3, "H": 2,
        "I": 9, "J": 1, "K": 1, "L": 4, "M": 2, "N": 6,  "O": 8, "P": 2,
        "Q": 1, "R": 6, "S": 4, "T": 6, "U": 4, "V": 2,  "W": 2, "X": 1,
        "Y": 2, "Z": 1
    ]

    /// Vowels get their own accounting because a rack with no vowel is a dead
    /// rack — see `SpinResolver`'s vowel guarantee.
    public static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]

    public var distribution: [Character: Int]

    public init(distribution: [Character: Int] = LetterBag.standardDistribution) {
        self.distribution = distribution
    }

    // `Character` isn't Codable, so the wire format keys on single-letter
    // strings and converts on the way in and out. Worth the small ceremony to
    // keep the in-memory API working in Characters, which is what every caller
    // actually has.
    private enum CodingKeys: String, CodingKey { case distribution }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Int].self, forKey: .distribution)
        if let raw {
            distribution = raw.reduce(into: [:]) { acc, pair in
                if let letter = pair.key.uppercased().first { acc[letter] = pair.value }
            }
        } else {
            distribution = LetterBag.standardDistribution
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let raw = distribution.reduce(into: [String: Int]()) { acc, pair in
            acc[String(pair.key)] = pair.value
        }
        try c.encode(raw, forKey: .distribution)
    }

    /// Letters paired with their draw weights, sorted for determinism — reel
    /// results must be identical on every device replaying a turn.
    public var weightedLetters: (letters: [Character], weights: [Double]) {
        let sorted = distribution.keys.sorted()
        return (sorted, sorted.map { Double(distribution[$0] ?? 0) })
    }

    public func isVowel(_ letter: Character) -> Bool {
        LetterBag.vowels.contains(Character(letter.uppercased()))
    }
}
