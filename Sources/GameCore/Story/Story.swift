import Foundation

/// One locked-in sentence, attributed.
public struct StorySentence: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    public let words: [String]
    public let authorID: String
    public let authorName: String
    public let score: Int

    public init(id: Int, text: String, words: [String], authorID: String, authorName: String, score: Int) {
        self.id = id
        self.text = text
        self.words = words
        self.authorID = authorID
        self.authorName = authorName
        self.score = score
    }
}

/// The shared story a team builds one turn at a time (GAME_DESIGN.md §5.1).
///
/// Continuity is detected mechanically — exact word matches and a pronoun map —
/// never by judging whether the story "makes sense". Players are the judges of
/// that, and the comedy lives in the gap.
public struct Story: Codable, Hashable, Sendable {
    public private(set) var sentences: [StorySentence]
    /// Nouns introduced so far, lowercased, in order of first appearance.
    public private(set) var knownNouns: [String]
    /// Nouns from the most recent sentence — reusing one of these is a Thread.
    public private(set) var recentNouns: Set<String>
    /// Drawn at round start; using it in the final sentence closes the chapter.
    public var endingWord: String
    /// Consecutive sentences that carried continuity forward.
    public private(set) var chainLevel: Int
    /// Chapters completed.
    public private(set) var chapter: Int

    public init(endingWord: String) {
        self.sentences = []
        self.knownNouns = []
        self.recentNouns = []
        self.endingWord = endingWord
        self.chainLevel = 0
        self.chapter = 1
    }

    public var isEmpty: Bool { sentences.isEmpty }
    public var text: String { sentences.map(\.text).joined(separator: " ") }

    /// Append a locked sentence and roll continuity state forward.
    public mutating func append(_ sentence: StorySentence, entries: [WordEntry], carriedContinuity: Bool) {
        sentences.append(sentence)

        let nouns = entries.filter(\.isNounCapable).map(\.text)
        for noun in nouns where !knownNouns.contains(noun) {
            knownNouns.append(noun)
        }
        recentNouns = Set(nouns)
        chainLevel = carriedContinuity ? chainLevel + 1 : 0
    }

    public mutating func closeChapter(nextEndingWord: String) {
        chapter += 1
        chainLevel = 0
        recentNouns = []
        endingWord = nextEndingWord
    }
}

/// Maps nouns to the pronouns that may stand in for them, so "the octopus…"
/// followed by "it danced" still counts as a callback.
public enum PronounMap {
    public static let pronouns: Set<String> = ["it", "he", "she", "they", "them", "him", "her"]

    /// Pronouns are treated as referring to any noun already in the story: the
    /// engine cannot know which one the player meant, and guessing wrong to the
    /// player's disadvantage would feel arbitrary. Generosity wins.
    public static func refersToStoryNoun(_ word: WordEntry, knownNouns: [String]) -> Bool {
        guard !knownNouns.isEmpty else { return false }
        return word.can(be: .pronoun) && pronouns.contains(word.text)
    }
}
