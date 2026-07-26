import GameCore
import SwiftUI

/// The slot machine's physical presence: cabinet frame, brass bezel, spinning
/// reels with motion blur, payline chevrons and ember sparks.
///
/// Art direction is drawn from the Hearthstone matchmaking reel supplied as
/// reference: heavy gunmetal panelling with visible rivets, a warm brass inner
/// bezel, content dissolving into vertical motion-blur streaks while spinning,
/// gold chevrons aimed at the payline, and embers spraying from the reel edges
/// where the surface is moving fastest.
///
/// **One deliberate divergence.** In the reference the spinning reel is a flat
/// red smear, because it doesn't matter what's on it — it's a loading
/// animation. Here the reels carry *words the player has to read and choose
/// between*, so legibility outranks spectacle: blur is applied only while a
/// reel is actually in motion and resolves completely on settle, and the
/// category colours (GRAPHICS.md §2.2) are never tinted by the cabinet's warm
/// palette. The chrome is atmosphere; the words are the game.
///
/// Everything here is drawn procedurally — no texture assets — so it scales to
/// any device and can be recoloured for skins (GRAPHICS.md §9).

// MARK: - Palette

enum Cabinet {
    static let shadow      = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let dark        = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let mid         = Color(red: 0.24, green: 0.24, blue: 0.27)
    static let light       = Color(red: 0.36, green: 0.36, blue: 0.39)
    static let highlight   = Color(red: 0.48, green: 0.48, blue: 0.52)

    static let brass       = Color(red: 0.78, green: 0.62, blue: 0.30)
    static let brassLight  = Color(red: 0.97, green: 0.87, blue: 0.58)
    static let brassDark   = Color(red: 0.42, green: 0.31, blue: 0.12)

    static let emberCore   = Color(red: 1.00, green: 0.88, blue: 0.52)
    static let emberMid    = Color(red: 1.00, green: 0.58, blue: 0.16)
    static let emberDeep   = Color(red: 0.85, green: 0.24, blue: 0.06)

    /// Brushed-metal fill for panels: a diagonal sheen rather than a flat grey,
    /// which is most of what separates "metal" from "grey rectangle".
    static var panel: LinearGradient {
        LinearGradient(
            colors: [light, mid, dark, mid],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var brassBezel: LinearGradient {
        LinearGradient(
            colors: [brassLight, brass, brassDark, brass],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Rivet

/// A screw head. Small, but rivets are the single cheapest cue that a surface
/// is a manufactured metal object rather than a drawn rectangle.
struct Rivet: View {
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Cabinet.highlight, Cabinet.mid, Cabinet.shadow],
                        center: .topLeading, startRadius: 0, endRadius: size
                    )
                )
            Circle()
                .strokeBorder(Cabinet.shadow.opacity(0.8), lineWidth: 0.5)
            // Slot in the screw head, angled so they don't all look identical.
            Capsule()
                .fill(Cabinet.shadow.opacity(0.7))
                .frame(width: size * 0.55, height: size * 0.14)
                .rotationEffect(.degrees(28))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
    }
}

// MARK: - Cabinet frame

/// Heavy panelled housing. Wraps the reel block so the machine reads as a
/// physical object sitting on the screen rather than a floating row of cards.
struct CabinetFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Cabinet.panel)

                    // Inset recess the reels sit inside.
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Cabinet.shadow.opacity(0.9), lineWidth: 3)
                        .blur(radius: 2)
                        .padding(6)

                    // Top-edge sheen: implies a light source above the cabinet.
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            LinearGradient(
                                colors: [Cabinet.highlight.opacity(0.9), .clear, Cabinet.shadow.opacity(0.8)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                }
            }
            .overlay(alignment: .topLeading) { Rivet().padding(7) }
            .overlay(alignment: .topTrailing) { Rivet().padding(7) }
            .overlay(alignment: .bottomLeading) { Rivet().padding(7) }
            .overlay(alignment: .bottomTrailing) { Rivet().padding(7) }
            .shadow(color: .black.opacity(0.7), radius: 12, y: 6)
    }
}

// MARK: - Motion blur streaks

/// The smear of a reel travelling too fast to read.
///
/// Vertical lines, not horizontal: a spinning reel preserves its vertical edges
/// while horizontal detail smears away, which is why the reference frame reads
/// as speed rather than as static stripes. Line positions are stable per reel
/// and only their brightness scrolls, so the streaks feel like one continuous
/// surface rather than noise.
struct ReelBlur: View {
    /// 0 = stopped, 1 = full speed. Drives brightness and blur.
    var speed: Double
    var seed: Int

    var body: some View {
        // Gate the timeline entirely when stopped.
        //
        // `TimelineView(.animation)` redraws forever once it exists — it does
        // not stop just because the content it draws is transparent. With five
        // reels each running a blur canvas *and* an ember canvas, that was ten
        // views repainting at 60fps for the whole session, including while the
        // player sat reading their sentence. The CPU cost starved the audio
        // render thread and came out as crackling.
        if speed <= 0.01 {
            Color.clear
        } else {
            timeline
        }
    }

    private var timeline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var rng = SplitMix(seed: UInt64(seed &* 2_654_435_761))

                // Warm glow behind the streaks.
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Cabinet.emberDeep.opacity(0.85 * speed),
                            Cabinet.emberMid.opacity(0.55 * speed),
                            Cabinet.emberDeep.opacity(0.85 * speed)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                let lineCount = 34
                for i in 0..<lineCount {
                    let x = size.width * (Double(i) + 0.5) / Double(lineCount)
                    let jitter = rng.nextUnit()
                    // Brightness scrolls vertically so the surface appears to
                    // travel even though the lines themselves stay put.
                    let phase = (t * (5.0 + jitter * 3.0) * speed + jitter * 6.28)
                    let pulse = 0.35 + 0.65 * abs(sin(phase))
                    let alpha = pulse * speed * (0.35 + jitter * 0.5)

                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        line,
                        with: .color(Cabinet.emberCore.opacity(alpha)),
                        lineWidth: 0.6 + jitter * 1.1
                    )
                }

                // Hot centre bleed — the brightest part of the reference frame.
                let centre = size.width / 2
                var glow = Path()
                glow.move(to: CGPoint(x: centre, y: 0))
                glow.addLine(to: CGPoint(x: centre, y: size.height))
                context.stroke(
                    glow,
                    with: .color(Color.white.opacity(0.5 * speed)),
                    lineWidth: 1.5
                )
            }
            .blur(radius: 0.7 + speed * 1.1)
        }
    }
}

/// Tiny deterministic RNG so streak layout is stable per reel across frames.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z % 10_000) / 10_000.0
    }
}

// MARK: - Embers

/// Sparks thrown from the reel edges while spinning. In the reference these
/// cluster at the left and right borders of the fastest reel — friction, not
/// decoration, which is why they belong at the edges rather than scattered.
struct EmberField: View {
    var speed: Double
    var seed: Int

    var body: some View {
        // Same gate as ReelBlur — an early `return` inside the Canvas draws
        // nothing but keeps the 60fps timeline alive, which is the expensive
        // part. The view has to not exist.
        if speed <= 0.05 {
            Color.clear
        } else {
            timeline
        }
    }

    private var timeline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var rng = SplitMix(seed: UInt64(seed &* 6_364_136_223 &+ 17))

                for _ in 0..<14 {
                    let side = rng.nextUnit() < 0.5 ? 0.0 : 1.0
                    let life = rng.nextUnit()
                    // Each spark loops on its own cycle so they don't pulse together.
                    let cycle = (t * (0.8 + life) + life * 3.0).truncatingRemainder(dividingBy: 1.0)
                    let drift = rng.nextUnit()

                    let x = size.width * side + (side == 0 ? -1 : 1) * cycle * 14 * (0.4 + drift)
                    let y = size.height * (0.15 + life * 0.8) - cycle * 26
                    let fade = (1.0 - cycle) * speed
                    let radius = 0.8 + drift * 1.6

                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(Cabinet.emberCore.opacity(fade))
                    )
                    // Soft halo so sparks glow rather than read as dots.
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius * 2.5, y: y - radius * 2.5,
                                               width: radius * 5, height: radius * 5)),
                        with: .color(Cabinet.emberMid.opacity(fade * 0.25))
                    )
                }
            }
            .blur(radius: 0.4)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Payline chevrons

/// Gold arrows aimed at the winning row, mounted on the cabinet either side.
struct PaylineChevron: View {
    var pointsRight: Bool

    var body: some View {
        ZStack {
            // Mounting plate
            RoundedRectangle(cornerRadius: 4)
                .fill(Cabinet.panel)
                .frame(width: 20, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Cabinet.shadow.opacity(0.7)))
                .overlay(Rivet(size: 7).offset(y: -9))

            Triangle()
                .fill(Cabinet.brassBezel)
                .frame(width: 14, height: 20)
                .rotationEffect(.degrees(pointsRight ? 90 : -90))
                .shadow(color: Cabinet.emberMid.opacity(0.5), radius: 4)
                .offset(x: pointsRight ? 10 : -10)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Reel

/// One reel: a brass-bezelled window that blurs while spinning and resolves to
/// a readable token when it settles.
struct SlotReel: View {
    let face: ReelFace
    let isSpinning: Bool
    let isEnabled: Bool
    let index: Int
    let onTap: () -> Void

    /// Drives the settle overshoot.
    @State private var settleOffset: CGFloat = 0
    @State private var spinSpeed: Double = 0

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Recessed well behind the reel surface.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Cabinet.shadow)

                ReelBlur(speed: spinSpeed, seed: index)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(spinSpeed)

                if !isSpinning {
                    content
                        .offset(y: settleOffset)
                        .transition(.opacity)
                }

                // Curved-glass shading: the reel is a drum, so it should fall
                // off in brightness top and bottom rather than sit flat.
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)

                EmberField(speed: spinSpeed, seed: index)
            }
            .frame(height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                // Brass bezel
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Cabinet.brassBezel, lineWidth: 2.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Cabinet.brassDark.opacity(0.8), lineWidth: 0.5)
            }
            .shadow(color: Cabinet.emberMid.opacity(spinSpeed * 0.5), radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || face.token == nil || isSpinning)
        .opacity(face.token == nil && !isSpinning ? 0.45 : 1)
        .onChange(of: isSpinning) { _, spinning in
            if spinning {
                withAnimation(.easeIn(duration: 0.18)) { spinSpeed = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.16)) { spinSpeed = 0 }
                settle()
            }
        }
    }

    /// Overshoot and ease back — physical momentum, per GRAPHICS.md §4.2.
    /// A reel that stops dead reads as a state change; one that rebounds reads
    /// as a mechanism.
    private func settle() {
        settleOffset = -16
        withAnimation(.interpolatingSpring(stiffness: 220, damping: 11)) {
            settleOffset = 0
        }
    }

    @ViewBuilder
    private var content: some View {
        switch face.token {
        case .letter(let tile):
            LetterTileView(tile: tile)
        case .bonus(let kind):
            BonusChip(kind: kind)
        case nil:
            Image(systemName: "circle.dotted")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}

// MARK: - Reel block

/// The full machine: chevrons, cabinet, and the row of reels inside it.
struct ReelBlock: View {
    let faces: [ReelFace]
    let spinning: Set<Int>
    let isEnabled: Bool
    let onTapReel: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaylineChevron(pointsRight: true)

            CabinetFrame {
                HStack(spacing: 7) {
                    ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                        SlotReel(
                            face: face,
                            isSpinning: spinning.contains(index),
                            isEnabled: isEnabled,
                            index: index,
                            onTap: { onTapReel(index) }
                        )
                    }
                }
            }

            PaylineChevron(pointsRight: false)
        }
    }
}
