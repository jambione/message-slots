import Foundation

/// Everything outside the turn that the reducer needs in order to spin fairly
/// and score correctly.
public struct TurnContext: Sendable {
    public var mode: GameMode
    public var teamStreak: Int
    public var category: WordCategory

    public init(mode: GameMode = .passAndPlay, teamStreak: Int = 0, category: WordCategory) {
        self.mode = mode
        self.teamStreak = teamStreak
        self.category = category
    }
}

/// The pure heart of the game.
///
/// `reduce` is side-effect free: it takes a state and an action and returns a
/// new state plus a list of `Effect` values for the UI to perform. Every source
/// of randomness runs through `state.rng` in a defined order, so replaying
/// `(seed, actions)` reproduces a turn exactly — which is what makes remote
/// play verifiable without a server and lets a teammate's turn be replayed as
/// an animation rather than a video.
public struct TurnReducer: Sendable {
    public let config: EconomyConfig
    public let resolver: SpinResolver

    public init(config: EconomyConfig = .default, bag: LetterBag = LetterBag()) {
        self.config = config
        self.resolver = SpinResolver(config: config, bag: bag)
    }

    public func reduce(
        _ state: TurnState,
        _ action: TurnAction,
        context: TurnContext
    ) -> (TurnState, [Effect]) {
        var state = state
        var effects: [Effect] = []

        guard state.phase != .locked else {
            return (state, [.rejected(.turnAlreadyLocked)])
        }

        state.actionLog.append(action)

        switch action {
        case .spin:
            performSpin(&state, context: context, effects: &effects)

        case .bank(let reel):
            bank(reel: reel, &state, context: context, effects: &effects)

        case .reorder(let from, let to):
            guard state.tray.indices.contains(from), to >= 0, to <= state.tray.count else {
                return reject(.invalidIndex, &state, effects)
            }
            let letter = state.tray.remove(at: from)
            state.tray.insert(letter, at: min(to, state.tray.count))
            effects.append(.trayChanged)

        case .removeFromTray(let index):
            removeFromTray(index: index, &state, effects: &effects)

        case .useSwap(let trayIndex):
            useSwap(trayIndex: trayIndex, &state, context: context, effects: &effects)

        case .playBlank(let letter):
            playBlank(letter, &state, effects: &effects)

        case .startFrenzy(let reel):
            guard let held = state.heldBonuses.firstIndex(of: .frenzy) else {
                return reject(.invalidIndex, &state, effects)
            }
            state.heldBonuses.remove(at: held)
            state.frenzyReel = reel
            state.frenzySpinsUsed = 0
            effects.append(.frenzyStarted(reel: reel))

        case .endFrenzy:
            state.frenzyReel = nil
            effects.append(.frenzyEnded)

        case .lockIn:
            lockIn(&state, context: context, effects: &effects)

        case .pass:
            // A passed turn scores nothing and breaks the streak. That is a
            // real cost, but it is always better than a turn that cannot end.
            state.phase = .locked
            effects.append(.wordLocked(ScoreBreakdown()))
        }

        // Every mutation re-checks the word so the UI's submit button and nudge
        // text are always in step with the tray. Cheap: a set lookup.
        if state.phase != .locked {
            effects.append(.wordChecked(check(state, context: context)))
        }

        return (state, effects)
    }

    // MARK: Word check

    /// The single source of truth for "can this be submitted?".
    ///
    /// Binary and explainable, unlike the sentence era's confidence levels: the
    /// word is in the category or it isn't, and the rejection can say exactly
    /// why in words the player will accept.
    public func check(_ state: TurnState, context: TurnContext) -> WordCheck {
        let word = state.word
        guard !word.isEmpty else { return WordCheck(verdict: .empty) }
        guard word.count >= config.minimumWordLength else {
            return WordCheck(verdict: .tooShort(minimum: config.minimumWordLength))
        }
        guard context.category.accepts(word) else {
            return WordCheck(verdict: .notInCategory(word: word, category: context.category.name))
        }
        return WordCheck(verdict: .valid(word: word))
    }

    // MARK: Spin

    private func performSpin(_ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        let inFrenzy = state.frenzyReel != nil

        if inFrenzy {
            if state.frenzySpinsUsed >= config.maxFrenzySpins {
                state.frenzyReel = nil
                effects.append(.frenzyEnded)
                return
            }
            state.frenzySpinsUsed += 1
        } else {
            guard state.triesRemaining > 0 else {
                effects.append(.rejected(.noTriesLeft))
                return
            }
            state.triesRemaining -= 1
        }

        // Frenzy re-spins a single reel; a normal spin re-rolls every reel that
        // still holds something the player hasn't banked, plus every empty one.
        let reels: [Int] = inFrenzy
            ? [state.frenzyReel!]
            : Array(0..<config.reelCount)

        let spinContext = SpinContext(
            category: context.category,
            banked: state.tray.map(\.tile.letter),
            triesRemaining: state.triesRemaining,
            blanksHeld: state.heldBonuses.filter { $0 == .blank }.count
        )

        let faces = resolver.spin(
            reels: reels,
            state: state,
            context: spinContext,
            rng: &state.rng
        )
        for (reel, face) in faces { state.reels[reel] = face }

        if state.phase == .ready {
            state.phase = .playing
            state.openingLetters = String(state.reels.compactMap { $0.tile?.letter })
        }

        effects.append(.reelsSpun(reels.sorted()))
    }

    // MARK: Bank

    private func bank(reel: Int, _ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        guard state.reels.indices.contains(reel), let token = state.reels[reel].token else {
            effects.append(.rejected(.reelNotReady))
            return
        }

        switch token {
        case .bonus(let kind):
            collect(kind, &state, effects: &effects)
            state.reels[reel] = ReelFace()

        case .letter(let tile):
            guard state.tray.count < config.trayCapacity else {
                effects.append(.rejected(.trayFull))
                return
            }
            let multiplier = state.pendingLetterGem ?? 1
            state.pendingLetterGem = nil

            let placed = PlacedLetter(
                id: state.nextTrayID,
                tile: tile,
                multiplier: multiplier,
                sourceReel: reel
            )
            state.tray.append(placed)
            // The face empties and refills next spin — banking never retires a
            // reel, which is what lets a word outgrow the reel count.
            state.reels[reel] = ReelFace()

            effects.append(.letterBanked(trayIndex: state.tray.count - 1, fromReel: reel))
            if multiplier > 1 {
                effects.append(.gemAttached(multiplier: multiplier, letter: String(tile.letter)))
            }
        }
    }

    private func collect(_ kind: BonusKind, _ state: inout TurnState, effects: inout [Effect]) {
        switch kind {
        case .letterGem(let multiplier):
            state.pendingLetterGem = max(state.pendingLetterGem ?? 1, multiplier)
        case .wordGem(let multiplier):
            state.wordMultiplier *= multiplier
            effects.append(.wordMultiplierRaised(multiplier: state.wordMultiplier))
        case .extraTry:
            state.triesRemaining += 1
            effects.append(.tryGranted(remaining: state.triesRemaining))
        case .frenzy, .blank, .swap, .gift:
            state.heldBonuses.append(kind)
        }
        effects.append(.bonusCollected(kind))
    }

    // MARK: Remove

    /// Un-banks a letter.
    ///
    /// It returns to its origin reel only if that reel hasn't been spun since —
    /// otherwise the spin has moved on and pulling the letter back would be a
    /// free second look at a try already spent. Arranging is always free;
    /// spinning is the only real bet (GAME_LOGIC.md §2.1).
    private func removeFromTray(index: Int, _ state: inout TurnState, effects: inout [Effect]) {
        guard state.tray.indices.contains(index) else {
            effects.append(.rejected(.invalidIndex))
            return
        }
        let removed = state.tray.remove(at: index)

        if let reel = removed.sourceReel,
           state.reels.indices.contains(reel),
           state.reels[reel].isEmpty,
           !removed.isBlank {
            state.reels[reel] = ReelFace(token: .letter(removed.tile))
            effects.append(.letterReturnedToReel(reel: reel, letter: String(removed.tile.letter)))
        } else {
            effects.append(.letterDiscarded(letter: String(removed.tile.letter)))
        }
        // No resource is ever refunded: a gem spent placing a letter is spent,
        // whether or not the letter survives.
        effects.append(.trayChanged)
    }

    private func useSwap(trayIndex: Int, _ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        guard let held = state.heldBonuses.firstIndex(of: .swap) else {
            effects.append(.rejected(.noSwapHeld))
            return
        }
        guard state.tray.indices.contains(trayIndex) else {
            effects.append(.rejected(.nothingToSwap))
            return
        }
        state.heldBonuses.remove(at: held)
        let removed = state.tray.remove(at: trayIndex)

        let reel = removed.sourceReel ?? 0
        let spinContext = SpinContext(
            category: context.category,
            banked: state.tray.map(\.tile.letter),
            triesRemaining: state.triesRemaining,
            blanksHeld: state.heldBonuses.filter { $0 == .blank }.count
        )
        let faces = resolver.spin(reels: [reel], state: state, context: spinContext, rng: &state.rng)
        for (index, face) in faces { state.reels[index] = face }

        effects.append(.letterDiscarded(letter: String(removed.tile.letter)))
        effects.append(.reelsSpun([reel]))
    }

    private func playBlank(_ letter: String, _ state: inout TurnState, effects: inout [Effect]) {
        guard let held = state.heldBonuses.firstIndex(of: .blank) else {
            effects.append(.rejected(.noBlankHeld))
            return
        }
        guard let character = letter.uppercased().first, character.isLetter else {
            effects.append(.rejected(.invalidIndex))
            return
        }
        guard state.tray.count < config.trayCapacity else {
            effects.append(.rejected(.trayFull))
            return
        }
        state.heldBonuses.remove(at: held)

        // Blanks score zero, exactly as in Scrabble. The flexibility is the
        // payment, so they need no further balancing — and a gem is wasted on
        // one, which is a real decision rather than a trap because the tray
        // shows the value immediately.
        let placed = PlacedLetter(
            id: state.nextTrayID,
            tile: LetterTile(character, isBlank: true),
            multiplier: 1,
            sourceReel: nil
        )
        state.tray.append(placed)
        state.pendingLetterGem = nil
        effects.append(.blankPlayed(letter: String(character)))
        effects.append(.trayChanged)
    }

    // MARK: Lock in

    private func lockIn(_ state: inout TurnState, context: TurnContext, effects: inout [Effect]) {
        let verdict = check(state, context: context)
        guard verdict.isSubmittable else {
            switch verdict.verdict {
            case .tooShort: effects.append(.rejected(.wordTooShort))
            default:        effects.append(.rejected(.notInCategory))
            }
            return
        }

        let scorer = ScoreCalculator(config: config)
        let breakdown = scorer.score(
            tray: state.tray,
            context: .init(
                triesRemaining: state.triesRemaining,
                teamStreak: context.teamStreak,
                wordMultiplier: state.wordMultiplier,
                openingLetters: Array(state.openingLetters),
                reelCount: config.reelCount
            )
        )

        state.phase = .locked
        effects.append(.wordLocked(breakdown))
    }

    // MARK: Helpers

    private func reject(
        _ reason: Effect.Rejection,
        _ state: inout TurnState,
        _ effects: [Effect]
    ) -> (TurnState, [Effect]) {
        (state, effects + [.rejected(reason)])
    }
}
