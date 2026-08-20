import Foundation

public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// Estimates wall-clock seconds per round by watching the round advance.
///
/// Every countdown the UI shows (days of key validity, hours of absence
/// headroom, minutes to a challenge deadline) is rounds multiplied by this. It
/// starts at the nominal 2.8 s and converges on the observed rate within a few
/// polls, so early countdowns on a chain with a different round time carry the
/// nominal figure's error until then.
public struct RoundClock: Sendable, Equatable {
    public static let nominal: TimeInterval = 2.8
    /// Samples outside this band are discarded as observation artefacts rather
    /// than folded into the estimate.
    static let plausible: ClosedRange<TimeInterval> = 0.5...30
    static let smoothing = 0.2

    public private(set) var estimate: TimeInterval = RoundClock.nominal
    public private(set) var sampleCount = 0

    private var lastRound: UInt64?
    private var lastObservedAt: Date?

    public init() {}

    public mutating func observe(round: UInt64, at date: Date) {
        defer {
            lastRound = round
            lastObservedAt = date
        }
        guard let previousRound = lastRound,
            let previousDate = lastObservedAt,
            round > previousRound
        else { return }

        let elapsed = date.timeIntervalSince(previousDate)
        let rounds = Double(round - previousRound)
        guard elapsed > 0, rounds > 0 else { return }

        // A machine waking from sleep is self-correcting here: both the elapsed
        // time and the round delta grow together, so the ratio still holds.
        let sample = elapsed / rounds
        guard Self.plausible.contains(sample) else { return }

        estimate = sampleCount == 0 ? sample : estimate + Self.smoothing * (sample - estimate)
        sampleCount += 1
    }
}
