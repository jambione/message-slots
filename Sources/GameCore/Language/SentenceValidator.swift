import Foundation

// MARK: - Templates

/// One element of a sentence template, e.g. `ART?`, `ADJ*`, `(NOUN|PRON)`.
public struct TemplateElement: Hashable, Sendable {
    public enum Quantifier: String, Sendable { case one = "", optional = "?", star = "*", plus = "+" }

    public let alternatives: Set<PartOfSpeech>
    public let quantifier: Quantifier

    func accepts(_ wordPOS: Set<PartOfSpeech>) -> Bool { !alternatives.isDisjoint(with: wordPOS) }
}

/// A sentence shape expressed over parts of speech. Templates are data, not
/// code, so playtesting can widen the grammar without a rebuild
/// (ARCHITECTURE.md §6).
public struct SentenceTemplate: Hashable, Sendable {
    public let name: String
    public let pattern: String
    public let elements: [TemplateElement]

    public init?(name: String, pattern: String) {
        var parsed: [TemplateElement] = []
        for raw in pattern.split(separator: " ") {
            var symbol = String(raw)
            var quantifier = TemplateElement.Quantifier.one
            if let last = symbol.last, let q = TemplateElement.Quantifier(rawValue: String(last)), q != .one {
                quantifier = q
                symbol.removeLast()
            }
            symbol = symbol.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let parts = symbol.split(separator: "|").map(String.init)
            let posSet = Set(parts.compactMap { PartOfSpeech(rawValue: $0) })
            guard posSet.count == parts.count, !posSet.isEmpty else { return nil }
            parsed.append(TemplateElement(alternatives: posSet, quantifier: quantifier))
        }
        guard !parsed.isEmpty else { return nil }
        self.name = name
        self.pattern = pattern
        self.elements = parsed
    }

    /// Backtracking match of a clause against this template.
    public func matches(_ clause: [Set<PartOfSpeech>]) -> Bool {
        func go(_ ei: Int, _ wi: Int) -> Bool {
            guard ei < elements.count else { return wi == clause.count }
            let element = elements[ei]
            switch element.quantifier {
            case .one:
                guard wi < clause.count, element.accepts(clause[wi]) else { return false }
                return go(ei + 1, wi + 1)
            case .optional:
                if wi < clause.count, element.accepts(clause[wi]), go(ei + 1, wi + 1) { return true }
                return go(ei + 1, wi)
            case .star, .plus:
                var consumed = 0
                if element.quantifier == .plus {
                    guard wi < clause.count, element.accepts(clause[wi]) else { return false }
                    consumed = 1
                }
                while true {
                    if go(ei + 1, wi + consumed) { return true }
                    guard wi + consumed < clause.count, element.accepts(clause[wi + consumed]) else { return false }
                    consumed += 1
                }
            }
        }
        return go(0, 0)
    }

    /// The shipping grammar. Deliberately generous: accepting nonsense is funny,
    /// rejecting a sentence a player believes in is a rage-quit.
    public static let standard: [SentenceTemplate] = [
        SentenceTemplate(name: "subject-verb", pattern: "ART? ADJ* (NOUN|PRON) ADV? VERB ADV?"),
        SentenceTemplate(name: "subject-verb-object", pattern: "ART? ADJ* (NOUN|PRON) ADV? VERB ART? ADJ* (NOUN|PRON) ADV?"),
        SentenceTemplate(name: "predicate-adjective", pattern: "ART? ADJ* (NOUN|PRON) ADV? VERB ADV? ADJ+"),
        SentenceTemplate(name: "subject-verb-place", pattern: "ART? ADJ* (NOUN|PRON) ADV? VERB ADV? PREP ART? ADJ* (NOUN|PRON)"),
        SentenceTemplate(name: "subject-verb-object-place", pattern: "ART? ADJ* (NOUN|PRON) ADV? VERB ART? ADJ* (NOUN|PRON) PREP ART? ADJ* (NOUN|PRON)"),
        SentenceTemplate(name: "fronted-adverb", pattern: "ADV ART? ADJ* (NOUN|PRON) ADV? VERB ART? ADJ* (NOUN|PRON)?")
    ].compactMap { $0 }
}

// MARK: - Result

public struct ValidationResult: Hashable, Sendable {
    /// Traffic-light shown by the live validity meter.
    public enum Confidence: String, Sendable, Codable {
        case red     // no template match — word salad
        case yellow  // template match, advisory tagger disagrees
        case green   // template match, everything agrees
    }

    public let isValid: Bool
    public let confidence: Confidence
    public let matchedTemplate: String?
    /// True when the sentence opens with a connector (Story Mode combo).
    public let opensWithConnector: Bool
    public let clauseCount: Int

    public static let empty = ValidationResult(
        isValid: false, confidence: .red, matchedTemplate: nil,
        opensWithConnector: false, clauseCount: 0
    )
}

// MARK: - Advisory tagger

/// Optional second opinion on an assembled sentence. Apple's `NLTagger` supplies
/// this on device; it can only downgrade a green to a yellow, never reject.
public protocol AdvisoryTagger: Sendable {
    /// Returns true when the tagger agrees the string reads as a sentence.
    func agrees(with sentence: String) -> Bool
}

// MARK: - Validator

public struct SentenceValidator: Sendable {
    public let templates: [SentenceTemplate]
    public let advisory: AdvisoryTagger?

    public init(templates: [SentenceTemplate] = SentenceTemplate.standard, advisory: AdvisoryTagger? = nil) {
        self.templates = templates
        self.advisory = advisory
    }

    /// A sentence needs at minimum a subject and a verb.
    public func validate(_ tray: [PlacedWord]) -> ValidationResult {
        guard tray.count >= 2 else { return .empty }

        let entries = tray.map(\.entry)
        let opensWithConnector = entries.first?.can(be: .conjunction) ?? false

        // Try the tray as written. If that fails and it opens with a connector,
        // try again without it — "Meanwhile, the dog danced" is a sentence with
        // a decoration on the front, not a broken one.
        var outcome = attemptMatch(entries)
        if outcome == nil, opensWithConnector, entries.count > 2 {
            outcome = attemptMatch(Array(entries.dropFirst()))
        }

        guard let outcome else {
            return ValidationResult(
                isValid: false, confidence: .red, matchedTemplate: nil,
                opensWithConnector: opensWithConnector, clauseCount: 0
            )
        }

        var confidence = ValidationResult.Confidence.green
        if let advisory, !advisory.agrees(with: Sentence.text(from: tray)) {
            confidence = .yellow
        }

        return ValidationResult(
            isValid: true,
            confidence: confidence,
            matchedTemplate: outcome.names.joined(separator: "+"),
            opensWithConnector: opensWithConnector,
            clauseCount: outcome.clauseCount
        )
    }

    /// Splits on interior connectors and requires every clause to match a template.
    private func attemptMatch(_ words: [WordEntry]) -> (names: [String], clauseCount: Int)? {
        var clauses: [[WordEntry]] = []
        var current: [WordEntry] = []
        for (i, word) in words.enumerated() {
            // Split only on words that can serve no role other than connecting,
            // and only when there is material on both sides.
            let isPureConnector = word.pos.subtracting([.conjunction]).isEmpty
            let isInterior = i > 0 && i < words.count - 1
            if isPureConnector && isInterior && !current.isEmpty {
                clauses.append(current)
                current = []
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { clauses.append(current) }
        guard !clauses.isEmpty else { return nil }

        var names: [String] = []
        for clause in clauses {
            guard let name = templateMatch(clause.map(\.pos)) else { return nil }
            names.append(name)
        }
        return (names, clauses.count)
    }

    private func templateMatch(_ clause: [Set<PartOfSpeech>]) -> String? {
        for template in templates where template.matches(clause) { return template.name }
        return nil
    }
}

// MARK: - Rendering

public enum Sentence {
    /// Player-facing sentence text: capitalised, space joined, full stop.
    public static func text(from tray: [PlacedWord]) -> String {
        let joined = tray.map(\.entry.text).joined(separator: " ")
        guard let first = joined.first else { return "" }
        return joined.replacingCharacters(in: joined.startIndex...joined.startIndex,
                                          with: String(first).uppercased()) + "."
    }
}
