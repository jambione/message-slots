import Foundation

/// One playable category — "Animals", "Musical Instruments" — and every word
/// that counts for it.
///
/// **The category list is the dictionary.** There is no separate general
/// word list: a word is submittable if and only if it appears in the active
/// category. That falls out of the rule directly — under "Musical Instruments"
/// you cannot submit CAT, so a general dictionary would never be consulted for
/// anything except to say no more politely.
///
/// This has a real cost worth naming: any word a player is *certain* belongs
/// but that isn't in the list will be refused, and being refused a word you
/// know is right is the single most trust-destroying thing a word game can do.
/// Three things are in place because of it:
///
///   1. `alternates` accepts spellings and plurals that map onto a listed word.
///   2. `SpinResolver` guarantees at least one listed word is reachable from the
///      letters on offer, so a turn is never a dead end.
///   3. Refusals are surfaced to telemetry rather than silently dropped, so the
///      lists improve from real play instead of from guesswork.
public struct WordCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Player-facing name, shown before the first spin.
    public var name: String
    /// A short nudge for the category's edges ("instruments, not the music").
    public var hint: String?
    /// Every accepted word, uppercased.
    public private(set) var words: Set<String>

    public init(id: String, name: String, hint: String? = nil, words: Set<String>) {
        self.id = id
        self.name = name
        self.hint = hint
        self.words = Set(words.map { $0.uppercased() })
    }

    /// Whether the word counts for this category.
    ///
    /// Accepts regular plurals of listed words, because the first live run of
    /// the game refused TIES under "Clothing" — the list had TIE. A player who
    /// spells an obviously correct word and is told no does not conclude the
    /// word list is incomplete; they conclude the game is broken. Since every
    /// category is hand-authored, plurals would otherwise have to be written
    /// out for every entry, and the one time someone forgot would be the one
    /// the player hit.
    ///
    /// Deliberately narrow: this only *widens* acceptance from an existing
    /// listed word, so it can never let in something unrelated to the category.
    public func accepts(_ word: String) -> Bool {
        let candidate = word.uppercased()
        if words.contains(candidate) { return true }

        // CATS → CAT, BOXES → BOX, PUPPIES → PUPPY
        if candidate.hasSuffix("S") {
            let singular = String(candidate.dropLast())
            if words.contains(singular) { return true }

            if candidate.hasSuffix("ES") {
                let dropped = String(candidate.dropLast(2))
                // Only for stems that genuinely take -ES.
                if ["CH", "SH", "S", "X", "Z"].contains(where: dropped.hasSuffix),
                   words.contains(dropped) {
                    return true
                }
            }

            if candidate.hasSuffix("IES") {
                let stem = String(candidate.dropLast(3)) + "Y"
                if words.contains(stem) { return true }
            }
        }
        return false
    }

    /// Shortest accepted word, which is what the reachability guarantee and the
    /// CPU player both need to reason about.
    public var shortestLength: Int {
        words.map(\.count).min() ?? 0
    }

    /// Words that can be spelled from `available`, respecting letter counts —
    /// having one E does not let you spell a word needing two.
    public func words(spellableFrom available: [Character], blanks: Int = 0) -> [String] {
        var pool: [Character: Int] = [:]
        for letter in available { pool[Character(letter.uppercased()), default: 0] += 1 }

        return words.filter { word in
            var remaining = pool
            var blanksLeft = blanks
            for character in word {
                let count = remaining[character] ?? 0
                if count > 0 {
                    remaining[character] = count - 1
                } else if blanksLeft > 0 {
                    blanksLeft -= 1
                } else {
                    return false
                }
            }
            return true
        }
    }
}

// MARK: - Pack

/// A loaded set of categories.
public struct CategoryPack: Codable, Hashable, Sendable {
    public let id: String
    public let categories: [WordCategory]

    public init(id: String, categories: [WordCategory]) {
        self.id = id
        self.categories = categories
    }

    public func category(id: String) -> WordCategory? {
        categories.first { $0.id == id }
    }

    /// Deterministic draw — a replayed turn must select the same category.
    public func draw(using rng: inout SeededRNG, excluding recent: Set<String> = []) -> WordCategory? {
        let fresh = categories.filter { !recent.contains($0.id) }
        return rng.pick(fresh.isEmpty ? categories : fresh)
    }

    // MARK: Loading

    public enum LoadError: Error, CustomStringConvertible {
        case missingResource(String)

        public var description: String {
            switch self {
            case .missingResource(let name): return "category pack '\(name)' not found in any bundle"
            }
        }
    }

    /// Loads the compiled pack from the app or package bundle.
    ///
    /// Mirrors `WordPool.bundled` so a larger authored pack can replace the
    /// starter content without any code change.
    public static func bundled(_ name: String = "categories_starter", in bundle: Bundle? = nil) throws -> CategoryPack {
        var candidates: [Bundle] = []
        if let bundle { candidates.append(bundle) }
        #if SWIFT_PACKAGE
        candidates.append(Bundle.module)
        #endif
        candidates.append(.main)
        candidates.append(Bundle(for: CategoryBundleToken.self))

        for candidate in candidates {
            guard let url = candidate.url(forResource: name, withExtension: "json") else { continue }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CategoryPack.self, from: data)
        }
        throw LoadError.missingResource(name)
    }
}

private final class CategoryBundleToken {}
