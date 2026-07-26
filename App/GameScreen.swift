import SwiftUI

/// The whole Phase 0 prototype in one screen: story, reels, tray, lever.
/// Deliberately plain — this exists to answer one question, "is a turn fun?",
/// not to be the shipping look.
struct GameScreen: View {
    @State private var model = GameViewModel()

    /// Index of the tray word being dragged and how far it has moved. Both are
    /// purely visual — the reducer only ever sees the final `.reorder` on
    /// release, so a drag that gets cancelled costs nothing and changes nothing.
    @State private var dragIndex: Int?
    @State private var dragTranslation: CGFloat = 0

    private let tokenWidth: CGFloat = 92
    private let tokenSpacing: CGFloat = 6
    private var tokenStride: CGFloat { tokenWidth + tokenSpacing }

    /// Where the dragged word would land if released right now.
    private var proposedIndex: Int? {
        guard let dragIndex else { return nil }
        let shift = Int((dragTranslation / tokenStride).rounded())
        return max(0, min(model.tray.count - 1, dragIndex + shift))
    }

    /// Live gap-opening: the dragged token follows the finger, and the words it
    /// has passed slide over to show where it will land.
    private func dragOffset(for index: Int) -> CGFloat {
        guard let from = dragIndex, let to = proposedIndex else { return 0 }
        if index == from { return dragTranslation }
        if from < to, index > from, index <= to { return -tokenStride }
        if to < from, index >= to, index < from { return tokenStride }
        return 0
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            VStack(spacing: 14) {
                header
                storyStrip
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
                        // Clear any in-flight drag so the next turn starts clean.
                        dragIndex = nil
                        dragTranslation = 0
                        model.continueToNextTurn()
                    }
                )
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
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
            // Audio toggle. Prominent rather than buried in a settings screen
            // that doesn't exist yet — someone playing in public needs to
            // silence this in one tap, not go hunting for it.
            Button {
                model.toggleAudio()
            } label: {
                Image(systemName: model.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(model.audioOn ? .white.opacity(0.75) : .white.opacity(0.35))
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
                    if model.teamStreak > 0 {
                        badge("🔥 \(model.teamStreak)")
                    }
                    if model.sentenceStars > 0 {
                        badge("★ \(model.sentenceStars)")
                    }
                    if let gem = model.pendingGem, gem > 1 {
                        badge("×\(gem) ready")
                    }
                    ForEach(Array(model.heldBonuses.enumerated()), id: \.offset) { _, bonus in
                        badge(bonus.displayName)
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

    // MARK: Story

    private var storyStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("THE STORY SO FAR")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("end on “\(model.endingWord)”")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.purple.opacity(0.9))
            }
            Text(model.storyText.isEmpty ? "Your sentence starts the story." : model.storyText)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }

    // MARK: Reels

    private var reelRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.reels.enumerated()), id: \.offset) { index, face in
                ReelView(face: face, isEnabled: !model.isCPUTurn) {
                    model.bank(reel: index)
                }
            }
        }
    }

    // MARK: Tray

    private var trayArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.sentencePreview)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(model.tray.isEmpty ? .white.opacity(0.3) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            ValidityMeter(result: model.validity, nudge: model.nudge)

            // Arranging your own tray is always free — the only thing that
            // costs a try is spinning for a *new* word (GAME_LOGIC.md §2).
            // So reordering here is a plain drag, no confirmation, no cost.
            // Reordering uses a plain DragGesture rather than SwiftUI's
            // `.draggable`/`.dropDestination`. The native drag-and-drop API is
            // built for moving data *between* views and deliberately waits for
            // a press-and-hold before it starts a drag session — which meant a
            // quick flick did nothing at all, and rearranging your own sentence
            // felt broken. A 6pt drag threshold responds instantly instead.
            //
            // (An earlier on-device check appeared to pass only because the
            // synthetic drag held for a full second before moving.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tokenSpacing) {
                    ForEach(Array(model.tray.enumerated()), id: \.element.id) { index, placed in
                        ZStack(alignment: .topLeading) {
                            TokenChip(entry: placed.entry, gem: placed.gemMultiplier, compact: true)
                                .frame(width: tokenWidth)
                                .scaleEffect(dragIndex == index ? 1.08 : 1)
                                .shadow(color: .black.opacity(dragIndex == index ? 0.5 : 0),
                                        radius: 8, y: 4)
                                .highPriorityGesture(reorderGesture(for: index))

                            // Drawn after the chip so it wins the hit test —
                            // a tap on × must never be read as a tiny drag.
                            Button(action: { model.removeFromTray(index) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .offset(x: -4, y: -4)
                            .accessibilityLabel("Remove \(placed.entry.text) from sentence")
                        }
                        .offset(x: dragOffset(for: index))
                        .zIndex(dragIndex == index ? 1 : 0)
                        .animation(.easeOut(duration: 0.16), value: proposedIndex)
                    }

                    if model.tray.isEmpty {
                        Text("empty tray")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.25))
                            .frame(height: 46)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 58)
            // While a word is in hand, the scroll view must not also pan.
            .scrollDisabled(dragIndex != nil)

            Text("Tap a reel to bank · drag tray words to reorder · tap × to remove")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    /// Immediate-response reorder drag. `minimumDistance` is small enough to
    /// feel instant but large enough that a tap on the × button, or a tap
    /// meant for the chip itself, is never mistaken for a drag.
    private func reorderGesture(for index: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragIndex == nil { dragIndex = index }
                dragTranslation = value.translation.width
            }
            .onEnded { _ in
                if let from = dragIndex, let to = proposedIndex, from != to {
                    // `.reorder` is remove-then-insert, so a target index in
                    // 0..<count maps straight across with no adjustment.
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
                onSpin: { model.spin() }
            )

            Button(action: { model.lockIn() }) {
                Text("LOCK IN SENTENCE")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(model.canLockIn ? Color.green : Color.white.opacity(0.12))
                    )
                    .foregroundStyle(model.canLockIn ? .white : .white.opacity(0.35))
            }
            .disabled(!model.canLockIn)
        }
    }
}

#Preview {
    GameScreen().preferredColorScheme(.dark)
}
