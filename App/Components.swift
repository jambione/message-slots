import GameCore
import SwiftUI

// MARK: - Letter value colour coding

extension LetterBand {
    /// Tiles are bone-coloured, like real Scrabble tiles.
    ///
    /// An earlier version coloured them by point value on a cool-to-hot ramp.
    /// That was inherited thinking from the sentence design, where colour
    /// carried part-of-speech — information with no other compact
    /// representation on a small chip. It doesn't survive the move to letters:
    /// **the value is already printed on every tile**, so the colour was
    /// duplicating it, and five hues across a five-tile rack read as noise
    /// rather than signal. Real Scrabble tiles are uniform and perfectly
    /// legible for exactly this reason.
    ///
    /// The only surviving distinction is the blank, which is genuinely a
    /// different kind of object — no value, plays as anything — and so is
    /// dimmed rather than tinted.
    var tint: Color {
        switch self {
        case .blank: return Color(red: 0.72, green: 0.70, blue: 0.65)
        default:     return Color(red: 0.94, green: 0.90, blue: 0.80)
        }
    }

    /// Dark ink on bone, the way a physical tile is printed.
    var ink: Color {
        self == .blank
            ? Color(red: 0.35, green: 0.33, blue: 0.30)
            : Color(red: 0.16, green: 0.13, blue: 0.10)
    }
}

// MARK: - Letter tile

/// A Scrabble-style tile. Letter large, value small in the corner — the layout
/// everyone already knows, so it needs no explaining.
struct LetterTileView: View {
    let tile: LetterTile
    var multiplier: Int = 1
    var compact = false

    private var side: CGFloat { compact ? 38 : 46 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [tile.band.tint, tile.band.tint.opacity(0.88)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                // A lit top edge and a dark base give the tile physical
                // thickness, which is what sells it as an object rather than a
                // coloured rectangle — the job the hue used to be doing badly.
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            multiplier > 1 ? Color.yellow : Color.black.opacity(0.28),
                            lineWidth: multiplier > 1 ? 2 : 1
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)

            Text(String(tile.letter))
                .font(.system(size: compact ? 20 : 24, weight: .heavy, design: .serif))
                .foregroundStyle(tile.band.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Blanks show no number at all — they're worth nothing, and printing
            // a 0 reads as a bug rather than a rule.
            if !tile.isBlank {
                Text("\(tile.value)")
                    .font(.system(size: compact ? 9 : 10, weight: .bold, design: .serif))
                    .foregroundStyle(tile.band.ink.opacity(0.75))
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if multiplier > 1 {
                Text("×\(multiplier)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.yellow))
                    .offset(x: 4, y: -5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            tile.isBlank
                ? "Blank played as \(String(tile.letter)), no points"
                : "\(String(tile.letter)), \(tile.value) point\(tile.value == 1 ? "" : "s")"
        )
    }
}

// MARK: - Bonus token

struct BonusChip: View {
    let kind: BonusKind

    var body: some View {
        VStack(spacing: 1) {
            Text(kind.shortLabel)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .opacity(0.85)
        }
        .foregroundStyle(.black)
        .frame(width: 46, height: 46)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.yellow.gradient))
        .accessibilityLabel(kind.displayName)
    }

    private var label: String {
        switch kind {
        case .letterGem: return "letter"
        case .wordGem:   return "word"
        case .extraTry:  return "try"
        case .frenzy:    return "spins"
        case .blank:     return "blank"
        case .swap:      return "swap"
        case .gift:      return "gift"
        }
    }
}

// MARK: - Word check meter

/// Shows whether the current word can be submitted, and why not if it can't.
///
/// The messages come straight from `WordCheck`, which can always state a
/// concrete reason — the payoff of moving from fuzzy sentence grammar to a
/// binary category lookup.
struct WordCheckMeter: View {
    let check: WordCheck

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(check.isSubmittable ? Color.green : Color.orange.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(check.message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Category banner

/// The turn's category, shown before the first spin so the player can aim at
/// it. This is the most important text on screen — it decides what counts.
struct CategoryBanner: View {
    let name: String
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SPELL A".uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Text(name.uppercased())
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(Cabinet.brassLight)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let hint {
                Text(hint)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Cabinet.brass.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Category: \(name). \(hint ?? "")")
    }
}

// MARK: - Pull to spin

/// Lever-style spin control, with an always-available button beneath it for
/// accessibility — the gesture is never the only path to a spin.
struct PullToSpin: View {
    let enabled: Bool
    let triesRemaining: Int
    let onSpin: () -> Void

    @State private var pull: CGFloat = 0
    @State private var hasFiredThisPull = false

    private let threshold: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 54)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                    Text(enabled ? "Pull down to spin" : "No tries left")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.35))

                Circle()
                    .fill(Cabinet.brassBezel)
                    .frame(width: 40, height: 40)
                    .offset(y: pull)
                    .shadow(color: Cabinet.emberMid.opacity(0.5), radius: 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard enabled else { return }
                        pull = max(0, min(value.translation.height, threshold))
                        // Latch, so one physical pull can never fire twice and
                        // silently eat two of only three tries.
                        if pull >= threshold, !hasFiredThisPull {
                            hasFiredThisPull = true
                            onSpin()
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pull = 0 }
                        hasFiredThisPull = false
                    }
            )

            Button(action: { if enabled { onSpin() } }) {
                Text("SPIN · \(triesRemaining) tr\(triesRemaining == 1 ? "y" : "ies") left")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(enabled ? 0.6 : 0.3))
            }
            .disabled(!enabled)
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
            VStack(alignment: .leading, spacing: 10) {
                Text(turn.playerName)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(turn.word)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text(turn.categoryName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Cabinet.brass)
                }

                Divider()

                let b = turn.breakdown
                // Letter-by-letter, so the player can check the arithmetic
                // themselves. With Scrabble values they can, which is exactly
                // why the sheet has to be honest.
                ForEach(Array(b.letters.enumerated()), id: \.offset) { _, letter in
                    line(
                        letter.multiplier > 1
                            ? "\(letter.letter)  (\(letter.base) × \(letter.multiplier))"
                            : letter.letter,
                        "\(letter.value)"
                    )
                }
                line("Letters", "\(b.letterPoints)").fontWeight(.semibold)

                if b.lengthBonus > 0 { line("Length (\(b.length))", "+\(b.lengthBonus)") }
                if b.wordMultiplier > 1 { line("Word ×\(b.wordMultiplier)", "applied") }
                ForEach(b.styleBonuses, id: \.name) { bonus in
                    styleLine(bonus)
                }
                if b.tryBonusPoints > 0 { line("Unused tries", "+\(b.tryBonusPoints)") }
                if b.teamStreak > 0 { line("Team streak ×\(fmt(b.streakMultiplier))", "\(b.teamStreak)") }

                Divider()

                HStack {
                    Text("Turn score").font(.system(size: 17, weight: .heavy, design: .rounded))
                    Spacer()
                    Text("\(b.total)").font(.system(size: 26, weight: .heavy, design: .rounded))
                }
                line("Team bank", "\(teamBank) / \(target)")

                Button(action: onContinue) {
                    Text("Next turn")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

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

    /// Multipliers must read exactly — "×1.2" for a ×1.25 makes the sheet look
    /// like it's lying about its own arithmetic.
    private func fmt(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f", value) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
