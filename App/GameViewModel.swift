import Foundation
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
    private(set) var validity: ValidationResult = .empty
    private(set) var lastTurn: CompletedTurn?

    /// Transient banner text ("Extra try!", "Tray full").
    private(set) var toast: String?
    private(set) var isHandoff = false
    private(set) var isCPUThinking = false

    var showScoreSheet: Bool = false

    /// Master audio switch, surfaced in the header.
    private(set) var audioOn = true

    func startAudio() {
        audio.start()
    }

    func toggleAudio() {
        audioOn.toggle()
        audio.setMusicEnabled(audioOn)
        audio.setEffectsEnabled(audioOn)
    }

    // MARK: Setup

    init() {
        let pool = (try? WordPool.bundled()) ?? WordPool(id: "empty", words: [])
        let reducer = TurnReducer(pool: pool, validator: SentenceValidator(advisory: NaturalLanguageAdvisor()))
        self.reducer = reducer
        self.engine = MatchEngine(reducer: reducer)

        var match = MatchState(
            mode: .story,
            players: [Player(id: "you", name: "You"), Player.cpu(.steady, id: "cpu")],
            targetScore: 600,
            story: Story(endingWord: MatchEngine.drawEndingWord(pool: pool, rng: &Self.bootRNG) ?? "finally"),
            seed: UInt64.random(in: 1...UInt64.max)
        )
        self.turn = MatchEngine(reducer: reducer).beginTurn(&match)
        self.match = match
    }

    private static var bootRNG = SeededRNG.random()

    // MARK: Derived state for the view

    var currentPlayerName: String { match.currentPlayer.name }
    var isCPUTurn: Bool { match.currentPlayer.isCPU }
    var triesRemaining: Int { turn.triesRemaining }
    var maxTries: Int { reducer.config.triesPerTurn }
    var tray: [PlacedWord] { turn.tray }
    var reels: [ReelFace] { turn.reels }
    var teamBank: Int { match.teamBank }
    var targetScore: Int { match.targetScore ?? 0 }
    var teamStreak: Int { match.teamStreak }
    var storyText: String { match.story?.text ?? "" }
    var endingWord: String { match.story?.endingWord ?? "" }
    var pendingGem: Int? { turn.pendingGem }
    var sentenceStars: Int { turn.sentenceStars }
    var heldBonuses: [BonusKind] { turn.heldBonuses }
    var canSpin: Bool { turn.canSpin && !isHandoff && !isCPUTurn }
    var canLockIn: Bool { turn.canLockIn && !isHandoff && !isCPUTurn }
    var hasSpun: Bool { turn.phase != .ready }

    var sentencePreview: String {
        tray.isEmpty ? "Drag words down to build a sentence" : Sentence.text(from: tray)
    }

    /// What the tray still needs, phrased for a nudge under the meter.
    var nudge: String? {
        guard hasSpun, !tray.isEmpty, !validity.isValid else { return nil }
        let missing = turn.missingCategories
        if missing.isEmpty { return "Try reordering the words" }
        return "Needs a " + missing.map(\.displayName).joined(separator: " and a ")
    }

    // MARK: Intent

    func spin() {
        guard canSpin else { return }
        send(.spin)
    }

    func bank(reel: Int) {
        send(.bank(reel: reel))
    }

    func move(from: Int, to: Int) {
        guard from != to else { return }
        send(.reorder(from: from, to: to))
    }

    func removeFromTray(_ index: Int) {
        send(.removeFromTray(index: index))
    }

    func lockIn() {
        guard canLockIn else { return }
        send(.lockIn)
    }

    // MARK: Turn flow

    private func send(_ action: TurnAction) {
        let (next, effects) = reducer.reduce(turn, action, context: engine.context(for: match))
        turn = next
        handle(effects)
    }

    private func handle(_ effects: [Effect]) {
        for effect in effects {
            // Audio reads the *previous* validity to detect the transition into
            // a valid sentence, so it has to run before `validity` is updated
            // below — otherwise the "yes" chime would fire on every tray change
            // while the sentence stayed valid.
            audio.handle(effect, turn: turn, validity: validity)

            switch effect {
            case .validityChanged(let result):
                validity = result

            case .tryGranted(let remaining):
                flash("Extra try — \(remaining) left")

            case .gemAttached(let multiplier, let word):
                flash("×\(multiplier) on \(word)")

            case .bonusCollected(let kind):
                flash(kind.displayName)

            case .rustDecayed(let word, let remaining):
                flash("\(word) rusting — \(remaining) pts")

            case .wordReturnedToReel:
                break  // the word reappearing on its reel is feedback enough

            case .wordDiscarded(let word):
                flash("\(word) is gone — its reel already moved on")

            case .sentenceLocked(let breakdown):
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
        isHandoff = true
    }

    /// Called when the player dismisses the score sheet.
    func continueToNextTurn() {
        showScoreSheet = false
        validity = .empty

        if match.currentPlayer.isCPU {
            playCPUTurn()
        } else {
            turn = engine.beginTurn(&match)
            isHandoff = false
        }
    }

    private func playCPUTurn() {
        isCPUThinking = true
        // Deliberately paced: watching a teammate play is part of the fun, and
        // an instant result would rob the table of the spin.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if let completed = engine.playCPUTurn(&match) {
                lastTurn = completed
                showScoreSheet = true
            }
            isCPUThinking = false
            turn = engine.beginTurn(&match)
            isHandoff = false
        }
    }

    // MARK: Feedback

    private func flash(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if toast == text { toast = nil }
        }
    }

    private func message(for reason: Effect.Rejection) -> String {
        switch reason {
        case .noTriesLeft: return "No tries left — lock in your sentence"
        case .trayFull: return "Tray is full"
        case .needTwoWords: return "Bank at least two words"
        case .notAWord: return "Not a word in this pool"
        case .turnAlreadyLocked: return "Turn is finished"
        case .reelNotReady, .invalidIndex, .nothingToSwap, .noSwapHeld, .noWildCardHeld:
            return "Can't do that yet"
        }
    }
}
