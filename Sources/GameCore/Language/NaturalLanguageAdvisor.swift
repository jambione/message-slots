import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Second-opinion tagger backed by Apple's on-device `NLTagger`.
///
/// Advisory only, by design (ARCHITECTURE.md §6): it can turn a green validity
/// light yellow and feed telemetry, but it can never reject a sentence the
/// template grammar accepted. False positives are funny; false negatives make
/// players quit.
public struct NaturalLanguageAdvisor: AdvisoryTagger {
    public init() {}

    public func agrees(with sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence

        var sawNounLike = false
        var sawVerb = false
        tagger.enumerateTags(
            in: sentence.startIndex..<sentence.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            switch tag {
            case .noun?, .pronoun?: sawNounLike = true
            case .verb?: sawVerb = true
            default: break
            }
            return true
        }
        return sawNounLike && sawVerb
    }
}
#endif

/// Advisory tagger that always agrees. Used in tests, on non-Apple platforms,
/// and any time we want the template grammar to speak for itself.
public struct PermissiveAdvisor: AdvisoryTagger {
    public init() {}
    public func agrees(with sentence: String) -> Bool { true }
}
