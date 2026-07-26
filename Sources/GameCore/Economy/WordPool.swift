import Foundation

/// A loaded set of words plus the indexes the spin resolver needs to draw from
/// it quickly and deterministically.
public struct WordPool: Codable, Hashable, Sendable {
    public let id: String
    public let words: [WordEntry]

    /// word indices grouped by tier, then by part of speech.
    private let byTierAndPOS: [Rarity: [PartOfSpeech: [Int]]]
    private let byText: [String: Int]

    public init(id: String, words: [WordEntry]) {
        self.id = id
        self.words = words

        var index: [Rarity: [PartOfSpeech: [Int]]] = [:]
        var texts: [String: Int] = [:]
        for (i, word) in words.enumerated() {
            // Indexed lowercased so lookups (Wild Card input, ending words) are
            // case-insensitive regardless of how a pool was authored.
            texts[word.text.lowercased()] = i
            for pos in word.pos {
                index[word.tier, default: [:]][pos, default: []].append(i)
            }
        }
        self.byTierAndPOS = index
        self.byText = texts
    }

    private enum CodingKeys: String, CodingKey { case id, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            words: try c.decode([WordEntry].self, forKey: .words)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(words, forKey: .words)
    }

    // MARK: Lookup

    public var isEmpty: Bool { words.isEmpty }
    public func contains(_ text: String) -> Bool { byText[text.lowercased()] != nil }
    public func entry(for text: String) -> WordEntry? {
        guard let i = byText[text.lowercased()] else { return nil }
        return words[i]
    }

    public func candidates(tier: Rarity, pos: PartOfSpeech) -> [WordEntry] {
        (byTierAndPOS[tier]?[pos] ?? []).map { words[$0] }
    }

    public func words(tagged tag: String) -> [WordEntry] {
        words.filter { $0.tags.contains(tag) }
    }

    /// Merge in a theme pack. The base pool wins on duplicate text, so a theme
    /// can add words but never silently restate an existing one's point value.
    public func merging(_ other: WordPool) -> WordPool {
        var combined = words
        let existing = Set(words.map(\.text))
        combined.append(contentsOf: other.words.filter { !existing.contains($0.text) })
        return WordPool(id: "\(id)+\(other.id)", words: combined)
    }

    // MARK: Bundled content

    public enum LoadError: Error, CustomStringConvertible {
        case resourceMissing(String)
        public var description: String {
            switch self {
            case .resourceMissing(let name): return "word pool resource '\(name)' not found in bundle"
            }
        }
    }

    /// Load a compiled pool (`Content/*.csv` compiled by `tools/compile_pools.py`).
    ///
    /// Resolves from the SwiftPM resource bundle when built as a package, and
    /// from the app bundle when the sources are compiled directly into an app
    /// target — so the same engine code serves `swift test` and the iOS app.
    public static func bundled(_ name: String = "words_starter", in bundle: Bundle? = nil) throws -> WordPool {
        var candidates: [Bundle] = []
        if let bundle { candidates.append(bundle) }
        #if SWIFT_PACKAGE
        candidates.append(Bundle.module)
        #endif
        candidates.append(Bundle.main)
        candidates.append(Bundle(for: BundleToken.self))

        for candidate in candidates {
            if let url = candidate.url(forResource: name, withExtension: "json") {
                return try JSONDecoder().decode(WordPool.self, from: Data(contentsOf: url))
            }
        }
        throw LoadError.resourceMissing(name)
    }
}

/// Anchors `Bundle(for:)` to whichever bundle this framework ended up in.
private final class BundleToken {
}
