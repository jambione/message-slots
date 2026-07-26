import GameCore
import SwiftUI

/// The whole Phase 0 prototype in one screen: category, reels, tray, lever.
/// Deliberately plain — this exists to answer one question, "is a turn fun?",
/// not to be the shipping look.
struct GameScreen: View {
    @State private var model = GameViewModel()

    /// Index of the tray letter being dragged and how far it has moved. Both
    /// are purely visual — the reducer only ever sees the final `.reorder` on
    /// release, so a cancelled drag costs nothing.
    @State private var dragIndex: Int?
    @State private var dragTranslation: CGFloat = 0

    /// Reels currently mid-spin. Presentational only: the reducer has already
    /// resolved the result before the animation starts, so the spin is a
    /// reveal, never a source of truth.
    @State private var spinningReels: Set<Int> = []

    /// Set when the player taps a held blank and must choose its letter.
    @State private var choosingBlank = false

    private let tileWidth: CGFloat = 46
    private let tileSpacing: CGFloat = 5
    private var tileStride: CGFloat { tileWidth + tileSpacing }

    private var proposedIndex: Int? {
        guard let dragIndex else { return nil }
        let shift = Int((dragTranslation / tileStride).rounded())
        return max(0, min(model.tray.count - 1, dragIndex + shift))
    }

    private func dragOffset(for index: Int) -> CGFloat {
        guard let from = dragIndex, let to = proposedIndex else { return 0 }
        if index == from { return dragTranslation }
        if from < to, index > from, index <= to { return -tileStride }
        if to < from, index >= to, index < from { return tileStride }
        return 0
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            VStack(spacing: 12) {
                header
                CategoryBanner(name: model.categoryName, hint: model.categoryHint)
                reelRow
                trayArea
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                        .padding(.bottom, 180)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if model.isCPUThinking {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("\(model.currentPlayerName) is taking a turn…")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onAppear { model.startAudio() }
        .sheet(isPresented: $model.showScoreSheet) {
            if let turn = model.lastTurn {
                ScoreSheet(
                    turn: turn,
                    teamBank: model.teamBank,
                    target: model.targetScore,
                    onContinue: {
                        dragIndex = nil
                        dragTranslation = 0
                        model.continueToNextTurn()
                    }
                )
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
        }
        .alert("Play blank as…", isPresented: $choosingBlank) {
            // A-Z is too many buttons for an alert, so this is a stopgap: the
            // real control is a letter grid, noted in FUNCTIONALITY.md.
            ForEach(["A", "E", "S", "T", "R", "N"], id: \.self) { letter in
                Button(letter) { model.playBlank(letter) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A blank spells any letter but scores nothing.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentPlayerName.uppercased())
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.orange)
                Text("\(model.teamBank) / \(model.targetScore)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()

            Button(action: { model.toggleAudio() }) {
                Image(systemName: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(model.audioOn ? 0.75 : 0.35))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(model.audioOn ? "Mute sound" : "Unmute sound")

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(0..<model.maxTries, id: \.self) { index in
                        Circle()
                            .fill(index < model.triesRemaining ? Color.orange : Color.white.opacity(0.15))
                            .frame(width: 9, height: 9)
                    }
                }
                HStack(spacing: 6) {
                    if model.teamStreak > 0 { badge("🔥 \(model.teamStreak)") }
                    if model.wordMultiplier > 1 { badge("word ×\(model.wordMultiplier)") }
                    if let gem = model.pendingGem, gem > 1 { badge("×\(gem) ready") }
                    ForEach(Array(model.heldBonuses.enumerated()), id: \.offset) { _, bonus in
                        Button(action: { if bonus == .blank { choosingBlank = true } }) {
                            badge(bonus.displayName)
                        }
                        .disabled(bonus != .blank)
                    }
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    // MARK: Reels

    private var reelRow: some View {
        ReelBlock(
            faces: model.reels,
            spinning: spinningReels,
            isEnabled: !model.isCPUTurn,
            onTapReel: { model.bank(reel: $0) }
        )
    }

    /// Starts every reel spinning, then stops them left to right.
    ///
    /// The stagger is the point (GRAPHICS.md §4.2): if all five landed together
    /// the result would simply appear and read as a state change. Stopping in
    /// sequence means the eye reaches reel 1 while 4 and 5 still move — the
    /// anticipation beat the turn loop is built on.
    private func runSpinAnimation() {
        let base = 0.42
        let stagger = 0.13
        spinningReels = Set(model.reels.indices)

        for index in model.reels.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + base + Double(index) * stagger) {
                _ = withAnimation(.easeOut(duration: 0.12)) {
                    spinningReels.remove(index)
                }
            }
        }
    }

    // MARK: Tray

    private var trayArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.wordPreview)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(model.tray.isEmpty ? .white.opacity(0.3) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            WordCheckMeter(check: model.check)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tileSpacing) {
                    ForEach(Array(model.tray.enumerated()), id: \.element.id) { index, placed in
                        ZStack(alignment: .topLeading) {
                            LetterTileView(tile: placed.tile, multiplier: placed.multiplier)
                                .scaleEffect(dragIndex == index ? 1.1 : 1)
                                .shadow(color: .black.opacity(dragIndex == index ? 0.5 : 0), radius: 8, y: 4)
                                .highPriorityGesture(reorderGesture(for: index))

                            // Drawn after the tile so it wins the hit test — a
                            // tap on × must never be read as a tiny drag.
                            Button(action: { model.removeFromTray(index) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .offset(x: -5, y: -5)
                            .accessibilityLabel("Remove \(String(placed.tile.letter))")
                        }
                        .offset(x: dragOffset(for: index))
                        .zIndex(dragIndex == index ? 1 : 0)
                        .animation(.easeOut(duration: 0.16), value: proposedIndex)
                    }

                    if model.tray.isEmpty {
                        Text("no letters yet")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.25))
                            .frame(height: 46)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 58)
            .scrollDisabled(dragIndex != nil)

            Text("Tap a reel to take a letter · drag to reorder · tap × to remove")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    /// Immediate-response reorder drag. Small enough to feel instant, large
    /// enough that a tap on × is never mistaken for a drag.
    private func reorderGesture(for index: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragIndex == nil { dragIndex = index }
                dragTranslation = value.translation.width
            }
            .onEnded { _ in
                if let from = dragIndex, let to = proposedIndex, from != to {
                    model.move(from: from, to: to)
                }
                dragIndex = nil
                dragTranslation = 0
            }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            PullToSpin(
                enabled: model.canSpin,
                triesRemaining: model.triesRemaining,
                onSpin: {
                    model.spin()
                    runSpinAnimation()
                }
            )

            // Out of spins with nothing submittable is a real possibility once
            // a category gates the word, so the turn must always have an exit.
            // Better a turn that scores nothing than one that cannot end.
            if model.isStuck {
                Button(action: { model.pass() }) {
                    VStack(spacing: 2) {
                        Text("GIVE UP THIS TURN")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        Text("no \(model.categoryName.lowercased()) word in these letters")
                            .font(.system(size: 10, design: .rounded))
                            .opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.85)))
                    .foregroundStyle(.black)
                }
            } else {
                Button(action: { model.lockIn() }) {
                    Text(model.canLockIn ? "SUBMIT \(model.word)" : "SUBMIT")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(model.canLockIn ? Color.green : Color.white.opacity(0.08))
                        )
                        .foregroundStyle(model.canLockIn ? .white : .white.opacity(0.3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .disabled(!model.canLockIn)
            }
        }
    }
}
