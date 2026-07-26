import Foundation

/// Story Mode continuity bonuses (GAME_DESIGN.md §5.1).
public struct ComboResult: Codable, Hashable, Sendable {
    public var callbackWords: [String] = []
    public var threadWords: [String] = []
    public var openedWithConnector = false
    public var closedChapter = false

    public var callbackPoints = 0
    public var threadPoints = 0
    public var connectorPoints = 0
    public var chapterPoints = 0

    /// Multiplier from the running continuity chain.
    public var chainMultiplier: Double = 1.0
    /// Chain level after this turn.
    public var resultingChainLevel = 0

    public init() {}

    public var totalBonus: Int { callbackPoints + threadPoints + connectorPoints + chapterPoints }
    /// Whether this turn kept the chain alive.
    public var carriedContinuity: Bool { !callbackWords.isEmpty || !threadWords.isEmpty }
    public var isEmpty: Bool { totalBonus == 0 && chainMultiplier == 1.0 }
}

public struct ComboDetector: Sendable {
    public let config: EconomyConfig

    public init(config: EconomyConfig) { self.config = config }

    /// - Parameters:
    ///   - tray: the locked sentence.
    ///   - story: story so far, or nil outside Story Mode.
    ///   - isFinalTurnOfChapter: enables the chapter-close bonus.
    public func detect(tray: [PlacedWord], story: Story?, isFinalTurnOfChapter: Bool) -> ComboResult {
        var result = ComboResult()
        guard let story, !tray.isEmpty else { return result }

        let entries = tray.map(\.entry)

        // Thread: reuse a noun from the immediately previous sentence.
        // Callback: reuse a noun from anywhere earlier, or a pronoun standing in
        // for one. Thread supersedes Callback for the same word.
        var threads: [String] = []
        var callbacks: [String] = []
        var seen = Set<String>()

        for entry in entries {
            let text = entry.text
            guard !seen.contains(text) else { continue }

            if entry.isNounCapable && story.recentNouns.contains(text) {
                seen.insert(text)
                threads.append(text)
            } else if entry.isNounCapable && story.knownNouns.contains(text) {
                seen.insert(text)
                callbacks.append(text)
            } else if PronounMap.refersToStoryNoun(entry, knownNouns: story.knownNouns) {
                seen.insert(text)
                callbacks.append(text)
            }
        }

        result.threadWords = threads
        result.threadPoints = threads.count * config.threadBonus

        // Callbacks are capped so a tray stuffed with old nouns can't farm them.
        let cappedCallbacks = Array(callbacks.prefix(config.maxCallbacksPerTurn))
        result.callbackWords = cappedCallbacks
        result.callbackPoints = cappedCallbacks.count * config.callbackBonus

        // Connector open.
        if let first = entries.first, first.can(be: .conjunction), entries.count > 2 {
            result.openedWithConnector = true
            result.connectorPoints = config.connectorOpenBonus
        }

        // Chapter close.
        if isFinalTurnOfChapter, entries.contains(where: { $0.text == story.endingWord.lowercased() }) {
            result.closedChapter = true
            result.chapterPoints = config.chapterCloseBonus
        }

        // Chain: grows while continuity holds, resets when a turn drops it.
        let newLevel = result.carriedContinuity ? story.chainLevel + 1 : 0
        result.resultingChainLevel = newLevel
        result.chainMultiplier = min(1.0 + config.chainStep * Double(newLevel), config.chainMultiplierCap)

        return result
    }
}
