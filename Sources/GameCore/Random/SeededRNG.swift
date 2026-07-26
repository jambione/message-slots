import Foundation

/// Deterministic, serializable random number generator (SplitMix64).
///
/// Everything random in a turn draws from this in a defined order, so a turn is
/// fully described by `(seed, [TurnAction])`. That single property buys us:
/// replayable score animations, "watch your teammate's turn" in remote play,
/// server-free cheat detection, and reproducible bug reports.
///
/// Deliberately *not* `SystemRandomNumberGenerator` anywhere in GameCore.
public struct SeededRNG: RandomNumberGenerator, Codable, Hashable, Sendable {
    public private(set) var state: UInt64
    /// The value the generator started from, retained so a turn can be replayed
    /// after the state has advanced.
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    /// Fresh, unpredictable seed for starting a real turn.
    public static func random() -> SeededRNG {
        SeededRNG(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    /// A generator rewound to its original seed.
    public var rewound: SeededRNG { SeededRNG(seed: seed) }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0..<upperBound`. Returns 0 for a non-positive bound.
    public mutating func nextInt(below upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform double in `0..<1`.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^53
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        guard p > 0 else { return false }
        guard p < 1 else { return true }
        return nextUnit() < p
    }

    /// Weighted choice over parallel arrays of items and non-negative weights.
    /// Returns nil when every weight is zero or the input is empty.
    public mutating func pick<T>(_ items: [T], weights: [Double]) -> T? {
        guard !items.isEmpty, items.count == weights.count else { return nil }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var roll = nextUnit() * total
        for (item, weight) in zip(items, weights) where weight > 0 {
            roll -= weight
            if roll <= 0 { return item }
        }
        return items.last
    }

    /// Uniform choice.
    public mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[nextInt(below: items.count)]
    }
}
