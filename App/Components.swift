import SwiftUI

// MARK: - Category colour coding

extension PartOfSpeech {
    /// Colourblind-safe hues, paired with the abbreviation on every token so
    /// colour is never the only signal.
    /// Okabe–Ito derived categorical palette, brightened for a dark background.
    /// Every pair in this set stays distinguishable under deuteranopia,
    /// protanopia, and tritanopia by construction — not just noun vs. verb.
    /// See docs/GRAPHICS.md §2.2 for the full rationale (this superseded an
    /// earlier noun-green/verb-red concept that failed under red-green color
    /// blindness). The on-token abbreviation is still the real disambiguator.
    var tint: Color {
        switch self {
        case .noun: return Color(red: 0.30, green: 0.58, blue: 0.86)        // blue
        case .verb: return Color(red: 0.92, green: 0.48, blue: 0.20)        // vermillion
        case .adjective: return Color(red: 0.20, green: 0.75, blue: 0.58)   // teal-green
        case .adverb: return Color(red: 0.92, green: 0.68, blue: 0.20)      // amber
        case .conjunction: return Color(red: 0.85, green: 0.55, blue: 0.75) // reddish purple
        case .preposition: return Color(red: 0.45, green: 0.78, blue: 0.94) // sky blue
        case .article, .pronoun: return Color(white: 0.55)                 // neutral glue
        }
    }
}

extension WordEntry {
    /// The category a token displays when a word can play several roles.
    var primaryCategory: PartOfSpeech {
        for category in [PartOfSpeech.noun, .verb, .adjective, .adverb, .conjunction, .preposition, .pronoun, .article]
        where pos.contains(category) {
            return category
        }
        return .noun
    }

    var categoryLabel: String {
        pos.count > 1 ? pos.map(\.abbreviation).sorted().joined(separator: "/") : primaryCategory.abbreviation
    }
}

// MARK: - Word token

struct TokenChip: View {
    let entry: WordEntry
    var gem: Int = 1
    var compact = false

    var body: some View {
        VStack(spacing: 2) {
            Text(entry.text)
                .font(.system(size: compact ? 15 : 17, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            HStack(spacing: 3) {
                Text(entry.categoryLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .opacity(0.75)
                Text("\(entry.effectivePoints * gem)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(entry.primaryCategory.tint.gradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(gem > 1 ? .yellow : .white.opacity(0.15), lineWidth: gem > 1 ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if gem > 1 {
                Text("×\(gem)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.yellow))
                    .offset(x: 4, y: -6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.text), \(entry.primaryCategory.displayName), \(entry.effectivePoints * gem) points")
    }
}

// MARK: - Bonus token

struct BonusChip: View {
    let kind: BonusKind

    private var symbol: String {
        switch kind {
        case .wordGem(let m): return "×\(m)"
        case .sentenceStar: return "★"
        case .extraTry: return "+1"
        case .frenzy: return "∞"
        case .wildCard: return "?"
        case .swap: return "⇄"
        case .gift: return "🎁"
        case .rust: return "⧗"
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(symbol)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
            Text(shortName)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.gradient))
        .accessibilityLabel("Bonus, \(kind.displayName)")
    }

    private var shortName: String {
        switch kind {
        case .wordGem: return "gem"
        case .sentenceStar: return "star"
        case .extraTry: return "try"
        case .frenzy: return "frenzy"
        case .wildCard: return "wild"
        case .swap: return "swap"
        case .gift: return "gift"
        case .rust(_, let v): return "\(v) pts"
        }
    }
}

// MARK: - Reel

struct ReelView: View {
    let face: ReelFace
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))

                switch face.token {
                case .word(let entry):
                    TokenChip(entry: entry)
                case .bonus(.rust(let entry, let remaining)):
                    TokenChip(entry: WordEntry(text: entry.text, pos: entry.pos, tier: entry.tier,
                                               points: remaining, tags: entry.tags))
                        .overlay(alignment: .top) {
                            Text("RUSTING")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(.orange)
                                .offset(y: -4)
                        }
                case .bonus(let kind):
                    BonusChip(kind: kind)
                case nil:
                    Image(systemName: "circle.dotted")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.2))
                }
            }
            .frame(height: 74)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || face.token == nil)
        .opacity(face.token == nil ? 0.5 : 1)
    }
}

// MARK: - Validity meter

struct ValidityMeter: View {
    let result: ValidationResult
    let nudge: String?

    private var color: Color {
        switch result.confidence {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red.opacity(0.7)
        }
    }

    private var label: String {
        guard result.isValid else { return nudge ?? "Not a sentence yet" }
        return result.confidence == .green ? "Valid sentence — grammar bonus ×2" : "Reads oddly, but it counts"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: result)
    }
}

// MARK: - Pull to spin

/// The lever. Drag down anywhere on the machine; the further you pull, the more
/// tension you feel and the longer the reels run. Release above the threshold
/// and nothing happens — no accidental tries burned.
struct PullToSpin: View {
    let enabled: Bool
    let triesRemaining: Int
    let onSpin: () -> Void

    @State private var pull: CGFloat = 0
    @State private var isPulling = false
    /// Guards against one physical pull firing more than one spin. A try is 20%
    /// of a turn, so a double-fire is not a cosmetic bug.
    @State private var hasFiredThisPull = false

    private let threshold: CGFloat = 70
    private let maxPull: CGFloat = 130

    private var progress: CGFloat { min(pull / threshold, 1) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Capsule()
                    .fill(Color(white: 0.16))
                    .frame(height: 54)
                Capsule()
                    .fill(progress >= 1 ? Color.green.gradient : Color.orange.gradient)
                    .frame(width: max(60, 300 * progress), height: 54)
                    .opacity(0.85)
                HStack(spacing: 8) {
                    Image(systemName: progress >= 1 ? "arrow.down.circle.fill" : "arrow.down")
                        .font(.headline)
                    Text(progress >= 1 ? "Release to spin" : (isPulling ? "Keep pulling…" : "Pull down to spin"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .offset(y: min(pull, maxPull) * 0.25)
            .scaleEffect(y: 1 + min(pull, maxPull) / 500, anchor: .top)
            .animation(isPulling ? nil : .spring(response: 0.32, dampingFraction: 0.55), value: pull)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard enabled else { return }
                        if !isPulling { hasFiredThisPull = false }
                        isPulling = true
                        pull = max(0, value.translation.height)
                    }
                    .onEnded { _ in
                        let shouldSpin = isPulling && !hasFiredThisPull && pull >= threshold && enabled
                        hasFiredThisPull = true
                        isPulling = false
                        pull = 0
                        if shouldSpin { onSpin() }
                    }
            )
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)

            // Always available, and the only path for VoiceOver and Switch Control.
            Button(action: { if enabled { onSpin() } }) {
                Text("SPIN  ·  \(triesRemaining) \(triesRemaining == 1 ? "try" : "tries") left")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .disabled(!enabled)
            .accessibilityLabel("Spin. \(triesRemaining) tries remaining")
        }
    }
}

// MARK: - Score sheet

struct ScoreSheet: View {
    let turn: CompletedTurn
    let teamBank: Int
    let target: Int
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(turn.playerName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(turn.sentence)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                let b = turn.breakdown
                // "Word points", not "Words" — this line is a point total, and it
                // sits directly above a line whose value really is a word count.
                // Labelling both "Words" made the sheet read as if it contradicted
                // itself ("Words 5" over "Length ×1 · 3 words").
                line("Word points", "\(b.rawWordPoints)")
                line("Length ×\(fmt(b.lengthMultiplier))", "\(b.wordCount) words")
                line(b.isValidSentence ? "Grammar ×2" : "Word salad ×0.25",
                     b.isValidSentence ? "valid" : "no sentence")
                if b.sentenceStars > 0 { line("Stars ×\(fmt(b.starMultiplier))", "\(b.sentenceStars)") }
                ForEach(b.styleBonuses, id: \.name) { bonus in
                    styleLine(bonus)
                }
                if b.tryBonusPoints > 0 { line("Unused tries", "+\(b.tryBonusPoints)") }
                if b.teamStreak > 0 { line("Team streak ×\(fmt(b.streakMultiplier))", "\(b.teamStreak)") }

                if !b.combo.isEmpty {
                    Divider()
                    if !b.combo.threadWords.isEmpty { line("Thread", "+\(b.combo.threadPoints)") }
                    if !b.combo.callbackWords.isEmpty { line("Callback", "+\(b.combo.callbackPoints)") }
                    if b.combo.openedWithConnector { line("Conjunction opening", "+\(b.combo.connectorPoints)") }
                    if b.combo.closedChapter { line("Chapter closed", "+\(b.combo.chapterPoints)") }
                    if b.combo.chainMultiplier > 1 { line("Chain ×\(fmt(b.combo.chainMultiplier))", "level \(b.combo.resultingChainLevel)") }
                }

                Divider()
                HStack {
                    Text("Turn score").font(.headline)
                    Spacer()
                    Text("\(turn.score)").font(.system(size: 30, weight: .heavy, design: .rounded))
                }

                HStack {
                    Text("Team bank").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(teamBank) / \(target)").fontWeight(.semibold)
                }
                .font(.subheadline)

                Button(action: onContinue) {
                    Text("Next turn")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)
            }
            .padding(22)
        }
    }

    /// A style bonus plus the reason it fired. Every style bonus already carries
    /// a `detail` string in the turn payload; showing it turns an unexplained
    /// "+30" into something the player can learn from ("Makes Sense · friend ate")
    /// — which matters most for the coherence bonus, whose entire job is to teach
    /// that sentences making sense is worth points (GAME_LOGIC.md §5.1).
    @ViewBuilder
    private func styleLine(_ bonus: ScoreBreakdown.StyleBonus) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            line(bonus.name, "+\(bonus.points)")
            if let detail = bonus.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 14, design: .rounded))
    }

    /// Multipliers must read exactly — "×1.2" for a ×1.25 length bonus makes the
    /// score sheet look like it is lying about its own arithmetic.
    private func fmt(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f", value) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
