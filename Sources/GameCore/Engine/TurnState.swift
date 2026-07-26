import Foundation

// MARK: - Reel face

/// What one reel is currently showing. An empty face refills on the next spin —
/// banking a letter does *not* retire its reel. That is what lets a word grow
/// past five letters across three tries: the tray is the memory, the reels are
/// the churn.
public struct ReelFace: Codable, Hashable, Sendable {
    public var token: ReelToken?

    public init(token: ReelToken? = nil) { self.token = token }

    public var isEmpty: Bool { token == nil }
    public var tile: LetterTile? { token?.tile }
    public var isBonus: Bool { token?.isBonus ?? false }
}

// MARK: - Phase

public enum TurnPhase: String, Codable, Hashable, Sendable {
    case ready       // before the first spin
    case playing     // spins remain, or the player may still bank/arrange
    case locked      // word submitted and scored
}

// MARK: - Validity

/// Why a word can or cannot be submitted.
///
/// Unlike the sentence era's fuzzy red/yellow/green confidence, this is binary
/// and fully explainable: the word is in the category or it isn't. Every
/// rejection can state its own reason in terms the player will accept, which is
/// the whole benefit of moving from sentences to words.
public struct WordCheck: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        case empty
        case tooShort(minimum: Int)
        /// Spelled something, but not a member of the active category.
        case notInCategory(word: String, category: String)
        case valid(word: String)
    }

    public let verdict: Verdict

    public init(verdict: Verdict) { self.verdict = verdict }

    public var isSubmittable: Bool {
        if case .valid = verdict { return true }
        return false
    }

    public var word: String? {
        switch verdict {
        case .valid(let w), .notInCategory(let w, _): return w
        default: return nil
        }
    }

    /// Player-facing nudge shown under the tray.
    public var message: String {
        switch verdict {
        case .empty:
            return "Bank letters to spell a word"
        case .tooShort(let minimum):
            return "Words need at least \(minimum) letters"
        case .notInCategory(let word, let category):
            return "\(word) isn't in \(category)"
        case .valid(let word):
            return "\(word) — good to go"
        }
    }

    public static let empty = WordCheck(verdict: .empty)
}

// MARK: - Turn state

/// The complete, serializable state of one player's turn.
///
/// A turn is fully reproducible from `rng.seed` plus `actionLog`, which is what
/// makes remote play verifiable and teammate-turn replay possible.
public struct TurnState: Codable, Hashable, Sendable {
    public var playerID: String
    /// The category this turn's word must belong to. Chosen before the first
    /// spin so the player can aim at it rather than discover it afterwards.
    public var categoryID: String
    public var categoryName: String

    public var reels: [ReelFace]
    /// Banked letters, in the order they spell the word.
    public var tray: [PlacedLetter]
    public var triesRemaining: Int
    public var phase: TurnPhase

    /// Multiplier waiting to attach to the next letter banked.
    public var pendingLetterGem: Int?
    /// Multiplier applied to the finished word.
    public var wordMultiplier: Int
    /// Bonuses the player is holding (swap, gift, blank).
    public var heldBonuses: [BonusKind]
    /// Reel index currently enjoying free re-spins, if any.
    public var frenzyReel: Int?
    public var frenzySpinsUsed: Int

    /// Letters shown on the opening spin, for the "used the whole opening rack"
    /// bonus. Stored as a string because `Character` isn't `Codable` and this
    /// value has to survive the wire for remote-play verification.
    public var openingLetters: String
    /// Gifts received from a teammate, applied at turn start.
    public var receivedGifts: [BonusKind]

    public var rng: SeededRNG
    public var actionLog: [TurnAction]

    public init(
        playerID: String,
        categoryID: String,
        categoryName: String,
        config: EconomyConfig = .default,
        rng: SeededRNG
    ) {
        self.playerID = playerID
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.reels = Array(repeating: ReelFace(), count: config.reelCount)
        self.tray = []
        self.triesRemaining = config.triesPerTurn
        self.phase = .ready
        self.pendingLetterGem = nil
        self.wordMultiplier = 1
        self.heldBonuses = []
        self.frenzyReel = nil
        self.frenzySpinsUsed = 0
        self.openingLetters = ""
        self.receivedGifts = []
        self.rng = rng
        self.actionLog = []
    }

    // MARK: Derived

    /// The word currently spelled by the tray.
    public var word: String { String(tray.map(\.tile.letter)) }

    /// Letters the player could still use — banked plus everything on the reels.
    public var availableLetters: [Character] {
        tray.map(\.tile.letter) + reels.compactMap { $0.tile?.letter }
    }

    public var nextTrayID: Int { (tray.map(\.id).max() ?? -1) + 1 }

    public var canSpin: Bool {
        phase != .locked && (triesRemaining > 0 || frenzyReel != nil)
    }
}

// MARK: - Actions

public enum TurnAction: Codable, Hashable, Sendable {
    case spin
    case bank(reel: Int)
    case reorder(from: Int, to: Int)
    case removeFromTray(index: Int)
    case useSwap(trayIndex: Int)
    /// Play a held blank as a chosen letter.
    case playBlank(letter: String)
    case startFrenzy(reel: Int)
    case endFrenzy
    case lockIn
    /// End the turn without a submittable word.
    ///
    /// Necessary because the category gate can genuinely strand a player: out
    /// of tries, holding letters that spell nothing in the category. Without
    /// this the turn simply cannot end, which is worse than scoring nothing.
    /// The spin guarantees exist to make this rare; this exists so that rare
    /// isn't the same as impossible.
    case pass
}

// MARK: - Effects

/// Side effects for the UI layer to perform. Emitting these as values keeps the
/// reducer pure and makes the whole turn replayable through the same code path
/// that played it live.
public enum Effect: Hashable, Sendable {
    case reelsSpun([Int])
    case letterBanked(trayIndex: Int, fromReel: Int)
    case gemAttached(multiplier: Int, letter: String)
    case wordMultiplierRaised(multiplier: Int)
    case bonusCollected(BonusKind)
    case tryGranted(remaining: Int)
    case frenzyStarted(reel: Int)
    case frenzyEnded
    case trayChanged
    /// A letter pulled from the tray went back to the exact reel it came from —
    /// only possible when that reel hasn't been touched since banking.
    case letterReturnedToReel(reel: Int, letter: String)
    /// A letter pulled from the tray could not be returned and is gone.
    case letterDiscarded(letter: String)
    case blankPlayed(letter: String)
    case wordChecked(WordCheck)
    case wordLocked(ScoreBreakdown)
    case rejected(Rejection)

    public enum Rejection: String, Hashable, Sendable {
        case noTriesLeft
        case turnAlreadyLocked
        case reelNotReady
        case trayFull
        case wordTooShort
        case notInCategory
        case nothingToSwap
        case noSwapHeld
        case noBlankHeld
        case invalidIndex
    }
}
