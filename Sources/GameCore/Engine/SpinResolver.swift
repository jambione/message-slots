import Foundation

/// Context a spin needs to know about the turn around it.
public struct SpinContext: Sendable {
    public var category: WordCategory
    /// Letters already banked — the spin needs these to judge what would help.
    public var banked: [Character]
    public var triesRemaining: Int
    public var blanksHeld: Int

    public init(
        category: WordCategory,
        banked: [Character] = [],
        triesRemaining: Int = 3,
        blanksHeld: Int = 0
    ) {
        self.category = category
        self.banked = banked
        self.triesRemaining = triesRemaining
        self.blanksHeld = blanksHeld
    }
}

/// Decides what each reel lands on.
///
/// **The central problem this solves.** The category gates submission, so a
/// rack of letters that can't spell anything in the category is a wasted turn.
/// Drawing uniformly from the Scrabble bag produces exactly that, constantly —
/// measured at 13% solvability for musical instruments, 31% for jobs. The
/// resolver therefore weights letters by how much they *advance a real word in
/// the active category*, on top of the normal distribution.
///
/// The player must never perceive this as assistance. They should simply feel
/// like the machine is being kind today. The old design's verb-pity system used
/// the same principle as a rarely-fired safety net; here it runs on every spin
/// and is the reason the game is playable at all.
public struct SpinResolver: Sendable {
    public let config: EconomyConfig
    public let bag: LetterBag

    public init(config: EconomyConfig = .default, bag: LetterBag = LetterBag()) {
        self.config = config
        self.bag = bag
    }

    /// Resolves the given reels, returning new faces.
    public func spin(
        reels: [Int],
        state: TurnState,
        context: SpinContext,
        rng: inout SeededRNG
    ) -> [Int: ReelFace] {
        var faces: [Int: ReelFace] = [:]
        var bonusCount = 0

        // Letters that would move the player toward a word they can finish.
        let helpful = helpfulLetters(context: context)

        for reel in reels.sorted() {
            let rate = config.bonusRate
                * (reel == config.reelCount - 1 ? config.lastReelBonusMultiplier : 1.0)
            if bonusCount < config.maxBonusFacesPerSpin, rng.nextUnit() < rate {
                if let bonus = rollBonus(rng: &rng) {
                    faces[reel] = ReelFace(token: .bonus(bonus))
                    bonusCount += 1
                    continue
                }
            }
            let letter = drawLetter(helpful: helpful, rng: &rng)
            faces[reel] = ReelFace(token: .letter(LetterTile(letter)))
        }

        applyGuarantees(faces: &faces, state: state, context: context, helpful: helpful, rng: &rng)
        return faces
    }

    // MARK: Category biasing

    /// Letters that appear in at least one category word still reachable from
    /// what the player holds.
    ///
    /// "Reachable" matters: once someone has banked C and A, the useful letters
    /// are the ones completing CAT, CAP, CAR — not every letter appearing
    /// anywhere in the category. Weighting by how many candidate words a letter
    /// unlocks means common completions surface more often than obscure ones.
    private func helpfulLetters(context: SpinContext) -> [Character: Double] {
        var counts: [Character: Double] = [:]

        var have: [Character: Int] = [:]
        for letter in context.banked { have[letter, default: 0] += 1 }

        for word in context.category.words {
            guard word.count <= config.trayCapacity else { continue }

            // How many of this word's letters the player still needs.
            var needed: [Character: Int] = [:]
            var remaining = have
            var blanks = context.blanksHeld
            for character in word {
                if let count = remaining[character], count > 0 {
                    remaining[character] = count - 1
                } else {
                    needed[character, default: 0] += 1
                }
            }

            // Ignore words that are already further out of reach than the
            // remaining spins could possibly fix.
            let shortfall = needed.values.reduce(0, +) - blanks
            let reachable = shortfall <= max(1, context.triesRemaining) * config.reelCount
            guard reachable else { continue }
            blanks = 0

            // Shorter words weigh more: they're what actually gets played, and
            // a category's short words are its lifeline (see the solvability
            // measurements in tools/compile_categories.py).
            let weight = 1.0 / Double(max(word.count, 1))
            for (character, count) in needed {
                counts[character, default: 0] += weight * Double(count)
            }
        }

        return counts
    }

    private func drawLetter(helpful: [Character: Double], rng: inout SeededRNG) -> Character {
        let (letters, baseWeights) = bag.weightedLetters
        guard !letters.isEmpty else { return "E" }

        // Normalise the helpfulness scores so `categoryBias` means the same
        // thing regardless of how large the category is.
        let peak = helpful.values.max() ?? 0
        let weights: [Double] = zip(letters, baseWeights).map { letter, base in
            guard peak > 0, let score = helpful[letter] else { return base }
            let normalised = score / peak
            return base * (1.0 + normalised * (config.categoryBias - 1.0))
        }

        return rng.pick(letters, weights: weights) ?? "E"
    }

    // MARK: Guarantees

    /// Repairs a spin that would otherwise be unplayable.
    ///
    /// Two invariants: at least one vowel somewhere on the reels, and at least
    /// one category word completable from everything the player can see. Both
    /// repair the *cheapest* face — an empty one, then a bonus-free low-value
    /// letter — so the fix costs the player as little as possible.
    private func applyGuarantees(
        faces: inout [Int: ReelFace],
        state: TurnState,
        context: SpinContext,
        helpful: [Character: Double],
        rng: inout SeededRNG
    ) {
        var protected: Set<Int> = []

        func allVisibleLetters() -> [Character] {
            var letters = context.banked
            for index in 0..<config.reelCount {
                if let face = faces[index] {
                    if let tile = face.tile { letters.append(tile.letter) }
                } else if let tile = state.reels[safe: index]?.tile {
                    letters.append(tile.letter)
                }
            }
            return letters
        }

        /// Cheapest reel to overwrite: prefer one this spin already touched and
        /// that isn't a bonus, since bonuses are the good news of a spin.
        func repairTarget() -> Int? {
            let candidates = faces.keys.sorted().filter { !protected.contains($0) }
            if let plain = candidates.last(where: { faces[$0]?.isBonus == false }) { return plain }
            return candidates.last
        }

        if config.guaranteeVowel, !allVisibleLetters().contains(where: bag.isVowel) {
            if let target = repairTarget() {
                let vowels: [Character] = ["A", "E", "I", "O", "U"]
                let weights = vowels.map { Double(LetterBag.standardDistribution[$0] ?? 1) }
                let vowel = rng.pick(vowels, weights: weights) ?? "E"
                faces[target] = ReelFace(token: .letter(LetterTile(vowel)))
                protected.insert(target)
            }
        }

        if config.guaranteeSolvableSpin {
            let visible = allVisibleLetters()
            let alreadySolvable = !context.category
                .words(spellableFrom: visible, blanks: context.blanksHeld)
                .isEmpty

            if !alreadySolvable {
                // Seed a whole word, not a single letter.
                //
                // Measured the hard way: repairing one reel raised the
                // submittable-turn rate to only 43%, because a word the player
                // can't spell is usually missing *several* letters, and fixing
                // one leaves it just as unspellable. Weighting individual
                // letters has the same flaw — it barely shifts the odds of
                // drawing a specific combination. So the machine picks a word
                // it intends the player to be able to make, and puts the
                // missing letters where they can reach them.
                //
                // This is unashamedly rigged. It's also invisible: the player
                // sees a plausible rack, not a solution handed over. The slot
                // metaphor earns this — nobody expects a slot machine's reels
                // to be independent.
                if let plan = repairPlan(visible: visible, context: context) {
                    for letter in plan {
                        guard let target = repairTarget() else { break }
                        faces[target] = ReelFace(token: .letter(LetterTile(letter)))
                        protected.insert(target)
                    }
                }
            }
        }
    }

    /// The letters needed to make some category word reachable, choosing the
    /// word that demands fewest new letters. Ties break alphabetically so a
    /// replayed turn repairs identically.
    private func repairPlan(visible: [Character], context: SpinContext) -> [Character]? {
        var have: [Character: Int] = [:]
        for letter in visible { have[letter, default: 0] += 1 }

        var best: (word: String, missing: [Character])?

        for word in context.category.words.sorted() {
            guard word.count <= config.trayCapacity else { continue }

            var remaining = have
            var missing: [Character] = []
            for character in word {
                if let count = remaining[character], count > 0 {
                    remaining[character] = count - 1
                } else {
                    missing.append(character)
                }
            }
            // Can't seed more letters than there are reels to put them on.
            guard missing.count <= config.reelCount else { continue }

            if best == nil || missing.count < best!.missing.count {
                best = (word, missing)
            }
            if missing.isEmpty { break }
        }

        return best?.missing
    }

    // MARK: Bonus draw

    private func rollBonus(rng: inout SeededRNG) -> BonusKind? {
        let slots = BonusSlot.allCases.sorted { $0.rawValue < $1.rawValue }
        let weights = slots.map { config.weight(for: $0) }
        guard let slot = rng.pick(slots, weights: weights) else { return nil }

        switch slot {
        case .letterGem2: return .letterGem(multiplier: 2)
        case .letterGem3: return .letterGem(multiplier: 3)
        case .wordGem2:   return .wordGem(multiplier: 2)
        case .extraTry:   return .extraTry
        case .frenzy:     return .frenzy
        case .blank:      return .blank
        case .swap:       return .swap
        case .gift:       return .gift
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
