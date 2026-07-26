import Foundation

/// A lightweight, hand-authored semantic class for a word — deliberately not a
/// full ontology. This exists to answer one narrow question: does this verb
/// plausibly happen to this kind of subject? "The dog danced" and "the
/// accordion whispered" are both grammatically identical (NOUN VERB); this is
/// the layer that can tell them apart.
///
/// ## Why this exists instead of an LLM verdict
///
/// The obvious alternative is "just ask a language model if the sentence makes
/// sense." That was considered and declined for the same reason the sentence
/// validator itself stays template-based (ARCHITECTURE.md §6.1):
///
/// - **Determinism.** Remote play verifies a teammate's turn by re-running it
///   from `(seed, actions)` and comparing scores. A model's opinion of
///   "coherent" can vary by device and OS version; two phones would compute
///   two different scores for the identical sentence, and the verifier would
///   flag an honest player as a cheat.
/// - **Speed.** This check runs on every tray change, in the same frame as the
///   validity meter. A tag-set intersection is microseconds; model inference
///   is not.
/// - **Fairness across hardware.** A player on an older iPhone must score by
///   the same rules as a friend on a new one.
///
/// So coherence is authored data plus a lookup, exactly like the sentence
/// grammar. It will always be cruder than real semantics — that's the accepted
/// cost. `SentenceJudge` (see that file) remains the sanctioned, already-built
/// slot for a model's opinion, used only for a capped, non-authoritative
/// flavor award that travels with the turn rather than being recomputed.
public enum SemanticCategory: String, Codable, Hashable, Sendable, CaseIterable {
    /// Can act, feel, or be an agent — people, animals, mythical creatures.
    case animate
    /// A location or setting.
    case place
    /// Something edible.
    case food
    /// A generic inanimate thing — tools, vehicles, belongings.
    case object
    /// A concept, event, or non-physical noun.
    case abstract
}

/// The result of checking one sentence for subject/verb coherence.
public struct CoherenceResult: Hashable, Sendable {
    /// True when the tray's subject and verb are both tagged and compatible.
    public let isCoherent: Bool
    /// The words judged, for the score-sheet line and telemetry. Nil when no
    /// subject/verb pair could be identified (too short, no verb, etc).
    public let subject: String?
    public let verb: String?

    public static let none = CoherenceResult(isCoherent: false, subject: nil, verb: nil)
}

/// Finds the sentence's subject and verb and checks whether the data says they
/// plausibly go together.
///
/// **The generosity rule still applies.** A missing tag on either side, or an
/// untagged pool word, never counts as incoherent — it just means the game has
/// no opinion, so no bonus is granted and nothing is penalized. Grammar
/// validity (SentenceValidator) is completely unaffected by this evaluator;
/// coherence is a bonus layered on top, never a gate. A silly-but-grammatical
/// sentence is still a full sentence — GAME_LOGIC.md §2.1's promise that
/// arranging your own words never costs you anything holds here too.
public struct CoherenceEvaluator: Sendable {
    public init() {}

    public func evaluate(_ tray: [PlacedWord]) -> CoherenceResult {
        let entries = tray.map(\.entry)
        guard let verbIndex = entries.firstIndex(where: { $0.can(be: .verb) }) else { return .none }

        // The subject is the nearest noun/pronoun before the verb — true for
        // every template in SentenceTemplate.standard, which all place the
        // subject ahead of the verb (with only articles/adjectives/adverbs
        // allowed to sit between them).
        guard let subjectIndex = entries[..<verbIndex].lastIndex(where: \.isNounCapable) else {
            return .none
        }

        let subject = entries[subjectIndex]
        let verb = entries[verbIndex]

        // Nothing to say if either side has no semantic data. This is the
        // "don't punish, only reward" rule in code: absence of a tag can never
        // resolve to incoherent.
        guard let subjectClass = subject.semantics.first, !verb.semantics.isEmpty else {
            return CoherenceResult(isCoherent: false, subject: subject.text, verb: verb.text)
        }

        let compatible = verb.semantics.contains(subjectClass)
        return CoherenceResult(isCoherent: compatible, subject: subject.text, verb: verb.text)
    }
}
