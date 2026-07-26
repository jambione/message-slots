import Foundation

/// An optional language-model opinion on a locked sentence.
///
/// ## Why the LLM is not the referee
///
/// It is tempting to let a small on-device model decide "is this a sentence?"
/// and delete the template grammar. Three things stop us:
///
/// 1. **Latency.** The validity light updates on every tray drag, inside one
///    frame (16ms). Model inference is two orders of magnitude slower. The
///    template matcher runs in microseconds.
/// 2. **Determinism.** Remote play verifies a teammate's turn by re-running it
///    from `(seed, actions)` and comparing scores. Model output varies by OS
///    version, device, and sampling — two phones would compute two different
///    scores for the same sentence, and the verifier would flag honest players
///    as cheats.
/// 3. **Availability.** On-device models require recent hardware. A player on an
///    older iPhone must not get a different rulebook than their friend.
///
/// ## So where the model earns its keep
///
/// - **Advisory validity** (`AdvisoryTagger`): can turn a green light yellow and
///   feed telemetry about template gaps. Never rejects, never changes score.
/// - **Judge's Award** (this protocol): a small, clearly-labelled flavour bonus
///   for sentences the model finds vivid, funny or coherent. Because it is not
///   reproducible, the verdict is computed once on the author's device and
///   *travels with the turn payload* — receiving clients replay it rather than
///   recompute it. Capped, cosmetic-adjacent, and never required to win.
/// - **Story coherence nudges**: optional "the story is drifting" hints between
///   chapters. Pure flavour text.
/// - **Content pipeline** (offline, not shipped): drafting theme packs, checking
///   category tags, and mining playtest logs for sentences the template grammar
///   wrongly rejected — which is how the grammar gets better without shipping a
///   model at all.
///
/// Verdicts are advisory data attached to a turn, never an input to the
/// deterministic score.
public struct JudgeVerdict: Codable, Hashable, Sendable {
    /// Model's read on whether this parses as a sentence. Telemetry only.
    public var readsAsSentence: Bool
    /// Award name shown on the results screen, e.g. "Most Cinematic".
    public var awardTitle: String?
    /// Bonus points, capped by `SentenceJudgeLimits.maxAwardPoints`.
    public var awardPoints: Int
    /// One-line quip for the results screen and share card.
    public var quip: String?

    public init(readsAsSentence: Bool, awardTitle: String? = nil, awardPoints: Int = 0, quip: String? = nil) {
        self.readsAsSentence = readsAsSentence
        self.awardTitle = awardTitle
        self.awardPoints = min(max(0, awardPoints), SentenceJudgeLimits.maxAwardPoints)
        self.quip = quip
    }

    public static let none = JudgeVerdict(readsAsSentence: true)
}

public enum SentenceJudgeLimits {
    /// Hard ceiling on model-granted points, so a good turn is always earned at
    /// the reels rather than awarded by a black box.
    public static let maxAwardPoints = 50
    /// If the model has not answered in this long, the turn proceeds without it.
    public static let timeout: Duration = .milliseconds(600)
}

public protocol SentenceJudge: Sendable {
    /// - Parameters:
    ///   - sentence: the locked sentence text.
    ///   - storySoFar: preceding story text in Story Mode, for coherence reads.
    func judge(sentence: String, storySoFar: String?) async -> JudgeVerdict
}

/// Default: no model. The game is complete and fair without one.
public struct NoJudge: SentenceJudge {
    public init() {}
    public func judge(sentence: String, storySoFar: String?) async -> JudgeVerdict { .none }
}

/// Wraps any judge with the timeout policy, so a slow or hung model can never
/// stall the results screen.
public struct TimeLimitedJudge: SentenceJudge {
    private let wrapped: SentenceJudge
    private let limit: Duration

    public init(_ wrapped: SentenceJudge, limit: Duration = SentenceJudgeLimits.timeout) {
        self.wrapped = wrapped
        self.limit = limit
    }

    public func judge(sentence: String, storySoFar: String?) async -> JudgeVerdict {
        await withTaskGroup(of: JudgeVerdict?.self) { group in
            group.addTask { await wrapped.judge(sentence: sentence, storySoFar: storySoFar) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? .none
            }
            return .none
        }
    }
}
