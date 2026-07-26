import Foundation

// MARK: - Reel

public struct ReelFace: Codable, Hashable, Sendable {
    public var token: Token?
    /// Rust tokens lose value while the player hesitates.
    public var rustDecayApplied: Int

    public init(token: Token? = nil, rustDecayApplied: Int = 0) {
        self.token = token
        self.rustDecayApplied = rustDecayApplied
    }

    /// Banking a word moves it to the tray for good and empties the face; the
    /// reel then refills on the next spin. This is what lets a sentence grow
    /// past five words — the tray is the memory, the reels are the churn.
    public var isEmpty: Bool { token == nil }

    /// Every face re-spins except rust, which stays put so its decay is a real
    /// decision rather than a coin flip.
    public var isSpinnable: Bool { !holdsRust }

    public var holdsRust: Bool {
        if case .bonus(.rust)? = token { return true }
        return false
    }
}

// MARK: - Phase

public enum TurnPhase: String, Codable, Hashable, Sendable {
    case ready       // before the first spin
    case playing     // spins remain, or the player may still bank/arrange
    case locked      // sentence submitted and scored
}

// MARK: - Turn state

/// The complete, serializable state of one player's turn.
///
/// A turn is fully reproducible from `rng.seed` plus `actionLog`, which is what
/// makes remote play verifiable and teammate-turn replay possible.
public struct TurnState: Codable, Hashable, Sendable {
    public var playerID: String
    public var reels: [ReelFace]
    public var tray: [PlacedWord]
    public var triesRemaining: Int
    public var phase: TurnPhase

    /// Multiplier waiting to attach to the next word banked.
    public var pendingGem: Int?
    public var sentenceStars: Int
    /// Bonuses the player is holding (swap, gift, wild card).
    public var heldBonuses: [BonusKind]
    /// Reel index currently enjoying free re-spins, if any.
    public var frenzyReel: Int?
    public var frenzySpinsUsed: Int

    /// Words shown on the opening spin, for the "Full House" style bonus.
    public var openingReelWords: Set<String>
    /// Gifts received from a teammate, applied at turn start.
    public var receivedGifts: [BonusKind]

    public var rng: SeededRNG
    public var actionLog: [TurnAction]
    public var diagnostics: [SpinDiagnostics]
    private var nextWordID: Int

    public init(playerID: String, reelCount: Int, tries: Int, seed: UInt64) {
        self.playerID = playerID
        self.reels = Array(repeating: ReelFace(), count: reelCount)
        self.tray = []
        self.triesRemaining = tries
        self.phase = .ready
        self.pendingGem = nil
        self.sentenceStars = 0
        self.heldBonuses = []
        self.frenzyReel = nil
        self.frenzySpinsUsed = 0
        self.openingReelWords = []
        self.receivedGifts = []
        self.rng = SeededRNG(seed: seed)
        self.actionLog = []
        self.diagnostics = []
        self.nextWordID = 0
    }

    // MARK: Derived

    public var trayEntries: [WordEntry] { tray.map(\.entry) }
    public var hasVerb: Bool { trayEntries.contains(where: \.isVerbCapable) }
    public var hasNoun: Bool { trayEntries.contains(where: \.isNounCapable) }
    public var wordsOnTable: Set<String> { Set(reels.compactMap(\.token?.word?.text)) }
    public var canSpin: Bool { phase != .locked && (triesRemaining > 0 || frenzyReel != nil) }
    /// Free spins left in the current Frenzy, if one is running.
    public func frenzySpinsRemaining(_ config: EconomyConfig) -> Int? {
        frenzyReel == nil ? nil : max(0, config.maxFrenzySpins - frenzySpinsUsed)
    }
    public var canLockIn: Bool { phase == .playing && tray.count >= 2 }

    /// Categories the tray still needs before it can be a sentence. Drives the
    /// "you need a verb!" nudge and the pity system.
    public var missingCategories: [PartOfSpeech] {
        var missing: [PartOfSpeech] = []
        if !hasNoun { missing.append(.noun) }
        if !hasVerb { missing.append(.verb) }
        return missing
    }

    mutating func takeWordID() -> Int {
        defer { nextWordID += 1 }
        return nextWordID
    }
}

// MARK: - Actions

/// Everything a player can do. The action log plus the seed reproduces the turn
/// exactly, so this enum is also the multiplayer wire format.
public enum TurnAction: Codable, Hashable, Sendable {
    case spin
    case bank(reel: Int)
    case reorder(from: Int, to: Int)
    case removeFromTray(index: Int)
    case useSwap(trayIndex: Int)
    case playWildCard(word: String)
    case startFrenzy(reel: Int)
    case endFrenzy
    case lockIn
}

// MARK: - Effects

/// Side effects for the UI layer to perform. Emitting these as values keeps the
/// reducer pure and makes the whole turn replayable through the same code path
/// that played it live.
public enum Effect: Hashable, Sendable {
    case reelsSpun([Int])
    case wordBanked(trayIndex: Int, fromReel: Int)
    case gemAttached(multiplier: Int, word: String)
    case bonusCollected(BonusKind)
    case tryGranted(remaining: Int)
    case frenzyStarted(reel: Int)
    case frenzyEnded
    case trayChanged
    /// A word pulled from the tray went back to the exact reel it came from —
    /// only possible when that reel hasn't been touched since banking.
    case wordReturnedToReel(reel: Int, word: String)
    /// A word pulled from the tray could not be returned (its reel has moved
    /// on, or it was a Wild Card) and is gone for the rest of the turn.
    case wordDiscarded(word: String)
    case rustDecayed(word: String, remaining: Int)
    case validityChanged(ValidationResult)
    case sentenceLocked(ScoreBreakdown)
    case rejected(Rejection)

    public enum Rejection: String, Hashable, Sendable {
        case noTriesLeft
        case turnAlreadyLocked
        case reelNotReady
        case trayFull
        case needTwoWords
        case notAWord
        case nothingToSwap
        case noSwapHeld
        case noWildCardHeld
        case invalidIndex
    }
}
