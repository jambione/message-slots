import Foundation
import GameCore
import Observation
import SwiftUI

/// Phase 0 prototype view model.
///
/// It owns a `MatchState` and a `TurnState` and does nothing but forward player
/// intent into `TurnReducer` and render what comes back. All rules live in
/// GameCore — if a behaviour is wrong, it is wrong in the engine, not here.
@MainActor
@Observable
final class GameViewModel {

    // MARK: Engine

    private let reducer: TurnReducer
    private let engine: MatchEngine
    let audio = AudioDirector()

    private(set) var match: MatchState
    private(set) var turn: TurnState
    private(set) var check: WordCheck = .empty
    private(set) var lastTurn: CompletedTurn?

    private(set) var toast: String?
    private(set) var isCPUThinking = false

    var showScoreSheet: Bool = false

    /// Audio ships **off**.
    ///
    /// Two separate rounds of synthesised audio were reported as unpleasant by
    /// the only person who can actually hear it, and the simulator's audio
    /// stack is unreliable enough that I can't distinguish a real defect from
    /// its buzzing. Until there's authored audio and a device to judge it on,
    /// silence is the better default — a quiet game is fine, a game that makes
    /// a bad noise is one you put down. The toggle is one tap away.
    private(set) var audioOn = false

    // MARK: Setup

    init() {
        let pack = (try? CategoryPack.bundled())
            ?? CategoryPack(id: "fallback", categories: [
                WordCategory(id: "animals", name: "Animals", words: ["CAT", "DOG", "COW", "BAT", "OWL"])
            ])
        let reducer = TurnReducer()
        self.reducer = reducer
        self.engine = MatchEngine(reducer: reducer, pack: pack)

        var match = MatchState(
            mode: .passAndPlay,
            players: [Player(id: "you", name: "You"), Player.cpu(.steady, id: "cpu")],
            targetScore: 400,
            seed: UInt64.random(in: 1...UInt64.max)
        )
        self.turn = MatchEngine(reducer: reducer, pack: pack).beginTurn(&match)
        self.match = match
    }

    // MARK: Derived state for the view

    var currentPlayerName: String { match.currentPlayer.name }
    var isCPUTurn: Bool { match.currentPlayer.isCPU }
    var teamBank: Int { match.teamBank }
    var targetScore: Int { match.targetScore }
    var teamStreak: Int { match.teamStreak }
    var reels: [ReelFace] { turn.reels }
    var tray: [PlacedLetter] { turn.tray }
    var triesRemaining: Int { turn.triesRemaining }
    var maxTries: Int { reducer.config.triesPerTurn }
    var canSpin: Bool { turn.canSpin && !isCPUTurn }
    var canLockIn: Bool { check.isSubmittable && !isCPUTurn }
    var heldBonuses: [BonusKind] { turn.heldBonuses }
    var pendingGem: Int? { turn.pendingLetterGem }
    var wordMultiplier: Int { turn.wordMultiplier }
    var categoryName: String { turn.categoryName }
    var categoryHint: String? { engine.category(for: match).hint }
    var word: String { turn.word }

    /// What the player has spelled, shown large above the tray.
    var wordPreview: String {
        turn.tray.isEmpty ? "Bank letters to spell a word" : turn.word
    }

    // MARK: Audio

    func startAudio() {
        // Don't even build the audio graph unless the player asks for sound.
        guard audioOn else { return }
        audio.start()
    }

    func toggleAudio() {
        audioOn.toggle()
        if audioOn { audio.start() }
        audio.setMusicEnabled(audioOn)
        audio.setEffectsEnabled(audioOn)
        if !audioOn { audio.stop() }
    }

    // MARK: Player intent

    func spin() { send(.spin) }
    func bank(reel: Int) { send(.bank(reel: reel)) }
    func move(from: Int, to: Int) {
        guard from != to else { return }
        send(.reorder(from: from, to: to))
    }
    func removeFromTray(_ index: Int) { send(.removeFromTray(index: index)) }
    func playBlank(_ letter: String) { send(.playBlank(letter: letter)) }
    func lockIn() {
        guard canLockIn else { return }
        send(.lockIn)
    }

    func pass() { send(.pass) }

    /// True when the player is genuinely stuck: no spins left and nothing
    /// submittable. The UI must offer a way out whenever this is true.
    var isStuck: Bool {
        !isCPUTurn && !turn.canSpin && !check.isSubmittable && turn.phase != .locked
    }

    // MARK: Turn flow

    private func send(_ action: TurnAction) {
        let (next, effects) = reducer.reduce(turn, action, context: engine.context(for: match))
        turn = next
        handle(effects)
    }

    private func handle(_ effects: [Effect]) {
        for effect in effects {
            audio.handle(effect, turn: turn, check: check)

            switch effect {
            case .wordChecked(let result):
                check = result

            case .tryGranted(let remaining):
                flash("Extra try — \(remaining) left")

            case .gemAttached(let multiplier, let letter):
                flash("×\(multiplier) on \(letter)")

            case .wordMultiplierRaised(let multiplier):
                flash("Word ×\(multiplier)")

            case .bonusCollected(let kind):
                flash(kind.displayName)

            case .blankPlayed(let letter):
                flash("Blank played as \(letter)")

            case .letterReturnedToReel:
                break  // the letter reappearing on its reel is feedback enough

            case .letterDiscarded(let letter):
                flash("\(letter) is gone — its reel already moved on")

            case .wordLocked(let breakdown):
                complete(with: breakdown)

            case .rejected(let reason):
                flash(message(for: reason))

            default:
                break
            }
        }
    }

    private func complete(with breakdown: ScoreBreakdown) {
        lastTurn = engine.completeTurn(&match, state: turn, breakdown: breakdown)
        showScoreSheet = true
    }

    /// Called when the player dismisses the score sheet.
    func continueToNextTurn() {
        showScoreSheet = false
        turn = engine.beginTurn(&match)
        check = .empty

        if match.currentPlayer.isCPU {
            runCPUTurn()
        }
    }

    /// Plays the bot's turn at a watchable pace. It uses the same reducer a
    /// human does, so nothing here can give it an advantage.
    private func runCPUTurn() {
        isCPUThinking = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            let (state, _, breakdown) = engine.playCPUTurn(&match, skill: .steady)
            turn = state
            isCPUThinking = false
            if let breakdown {
                lastTurn = engine.completeTurn(&match, state: state, breakdown: breakdown)
                showScoreSheet = true
            }
        }
    }

    // MARK: Toast

    private func flash(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            if toast == text { toast = nil }
        }
    }

    private func message(for reason: Effect.Rejection) -> String {
        switch reason {
        case .noTriesLeft:      return "No tries left — submit your word"
        case .trayFull:         return "No room for more letters"
        case .wordTooShort:     return "Too short — \(reducer.config.minimumWordLength) letters minimum"
        case .notInCategory:    return "Not a \(turn.categoryName.lowercased()) word"
        case .turnAlreadyLocked: return "Turn is finished"
        case .noBlankHeld:      return "No blank tile held"
        case .reelNotReady, .invalidIndex, .nothingToSwap, .noSwapHeld:
            return "Can't do that yet"
        }
    }
}
