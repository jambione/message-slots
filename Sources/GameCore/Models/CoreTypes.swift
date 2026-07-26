import Foundation

// MARK: - Bonus tokens

/// The bonus set. Each one exists to protect or amplify a specific part of the
/// turn's tension, not as decoration.
public enum BonusKind: Codable, Hashable, Sendable {
    /// Multiplies the value of the next letter banked.
    case letterGem(multiplier: Int)
    /// Multiplies the whole word's score.
    case wordGem(multiplier: Int)
    /// +1 spin this turn. With only three tries, this is a large gift.
    case extraTry
    /// Unlimited free re-spins of one reel for a short window.
    case frenzy
    /// A blank tile: becomes any letter the player chooses, and scores zero —
    /// exactly the Scrabble rule. The flexibility *is* the payment, which is
    /// why it needs no further balancing.
    case blank
    /// Return a banked letter to its reel and re-spin it free.
    case swap
    /// Passes a bonus to your teammate's next turn, at +1 potency.
    case gift

    /// Bonuses the player keeps until they choose to use them.
    public var isHeld: Bool {
        switch self {
        case .swap, .gift, .blank: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .letterGem(let m): return "×\(m) Letter"
        case .wordGem(let m):   return "×\(m) Word"
        case .extraTry:         return "Extra Try"
        case .frenzy:           return "Free Spin Frenzy"
        case .blank:            return "Blank Tile"
        case .swap:             return "Swap"
        case .gift:             return "Gift"
        }
    }

    public var shortLabel: String {
        switch self {
        case .letterGem(let m): return "×\(m)"
        case .wordGem(let m):   return "W×\(m)"
        case .extraTry:         return "+1"
        case .frenzy:           return "∞"
        case .blank:            return "?"
        case .swap:             return "⇄"
        case .gift:             return "gift"
        }
    }
}

/// Identifies a bonus slot for weighted drawing, separate from `BonusKind` so
/// the economy can weight "a ×2 letter gem" without encoding the multiplier.
public enum BonusSlot: String, Codable, Hashable, Sendable, CaseIterable {
    case letterGem2, letterGem3, wordGem2, extraTry, frenzy, blank, swap, gift
}

// MARK: - Reel contents

/// What a reel can land on.
public enum ReelToken: Codable, Hashable, Sendable {
    case letter(LetterTile)
    case bonus(BonusKind)

    public var tile: LetterTile? {
        if case .letter(let t) = self { return t }
        return nil
    }

    public var isBonus: Bool { if case .bonus = self { return true }; return false }
}

// MARK: - Tray

/// A letter committed to the player's word.
public struct PlacedLetter: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public var tile: LetterTile
    /// Letter multiplier applied at bank time (1 = none).
    public var multiplier: Int
    /// Index of the reel it came from, or nil for blanks played from hand.
    /// Used to decide whether removal can return it (GAME_LOGIC.md §2.1).
    public var sourceReel: Int?

    public init(id: Int, tile: LetterTile, multiplier: Int = 1, sourceReel: Int? = nil) {
        self.id = id
        self.tile = tile
        self.multiplier = multiplier
        self.sourceReel = sourceReel
    }

    public var value: Int { tile.value * multiplier }
    public var isBlank: Bool { tile.isBlank }
}

// MARK: - Players and modes

/// How good the CPU is. Skill changes patience and ambition, never the rules —
/// a CPU teammate plays the same game you do, from the same reducer.
public enum CPUSkill: String, Codable, Hashable, Sendable, CaseIterable {
    /// Takes the first word it finds. Fun, chaotic, easy to out-score.
    case rookie
    /// Finds a solid word, then pushes for a better one if the odds look good.
    case steady
    /// Patient. Holds out for high-value letters and long words.
    case sharp

    /// Minimum word score the bot will settle for early in a turn.
    var greedThreshold: Int {
        switch self {
        case .rookie: return 1
        case .steady: return 8
        case .sharp:  return 16
        }
    }

    /// Word length it tries to reach before locking in.
    var targetLength: Int {
        switch self {
        case .rookie: return 3
        case .steady: return 4
        case .sharp:  return 6
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
        let defaults: [CPUSkill: String] = [
            .rookie: "Sprocket", .steady: "Wordsworth", .sharp: "Professor Cogsworth"
        ]
        return Player(id: id, name: name ?? defaults[skill] ?? "CPU", kind: .cpu(skill: skill))
    }

    public var isCPU: Bool { kind.isCPU }
}

public enum GameMode: String, Codable, Hashable, Sendable, CaseIterable {
    case passAndPlay
    case beatTheHouse
    case solo
    case dailySpin
}

/// How the players' devices are connected. The rules never differ by transport —
/// this only tells the UI how to route turns.
public enum Connectivity: String, Codable, Hashable, Sendable {
    case localDevice     // pass and play
    case remoteAsync     // Game Center turn based
    case sameRoomLive    // MultipeerConnectivity
}
