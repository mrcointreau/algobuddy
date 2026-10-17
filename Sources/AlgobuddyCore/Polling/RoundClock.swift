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
/// headroom, minutes to a challenge deadline) is rounds multiplied by this. Once
/// the rounds span half an hour, the estimate is the rate over that whole span.
/// An anchor, a past round whose time a block's timestamp gives, provides such
/// a span from the first poll. Without one the estimate starts at the nominal
/// 2.8 s and moves towards the observed rate with every poll, so early
/// countdowns on a chain with a different round time carry part of the nominal
/// figure's error until the span is long enough.
public struct RoundClock: Sendable, Equatable {
    public static let nominal: TimeInterval = 2.8
    /// The fewest rounds a single sample spans, so one round more or less is
    /// at most a tenth of it. A 30 s poll sees 10 or 11.
    static let minimumSampleRounds: UInt64 = 10
    /// Samples outside this band are discarded as observation artefacts rather
    /// than folded into the estimate.
    static let plausible: ClosedRange<TimeInterval> = 0.5...30
    static let smoothing = 0.2
    /// How long the rounds must have been watched before the estimate is the
    /// rate over the whole span rather than a blend of single polls.
    static let longSpan: TimeInterval = 30 * 60
    /// How far back the span reaches once it is long enough. Older starting
    /// points are dropped, so the estimate still follows a lasting change in
    /// the round time.
    static let spanWindow: TimeInterval = 60 * 60
    static let checkpointSpacing: TimeInterval = 10 * 60

    /// Seconds per round: the rate over the long span once there is one, and
    /// the blend of single-poll samples before that.
    public var estimate: TimeInterval { spanRate ?? smoothed }
    public private(set) var sampleCount = 0

    private var smoothed = RoundClock.nominal
    private var lastRound: UInt64?
    private var lastObservedAt: Date?

    private struct Observation: Sendable, Equatable {
        let round: UInt64
        let date: Date
    }
    /// Where the long span can start, oldest first.
    private var checkpoints: [Observation] = []
    /// The newest observation whose round advanced, where the span ends.
    private var newest: Observation?

    public init() {}

    public mutating func observe(round: UInt64, at date: Date) {
        extendSpan(round: round, at: date)
        guard let previousRound = lastRound, let previousDate = lastObservedAt else {
            lastRound = round
            lastObservedAt = date
            return
        }
        // A round that does not advance is neither a sample nor a new start. A
        // lagging backend's older round would count rounds the chain made
        // before the time recorded with it, and the same round seen again
        // would move the start past the moment that round began: either makes
        // the next sample too short.
        guard round > previousRound else { return }
        // Too few rounds to measure, as when a refresh lands seconds after a
        // poll: a sample over three rounds can be a third off, and would move
        // every countdown by part of that. The earlier observation stays the
        // start, so the next sample spans both.
        guard round - previousRound >= Self.minimumSampleRounds else { return }
        lastRound = round
        lastObservedAt = date

        let elapsed = date.timeIntervalSince(previousDate)
        let rounds = Double(round - previousRound)
        guard elapsed > 0, rounds > 0 else { return }

        // A machine waking from sleep is self-correcting here: both the elapsed
        // time and the round delta grow together, so the ratio still holds.
        let sample = elapsed / rounds
        guard Self.plausible.contains(sample) else { return }

        // Blended from the nominal rather than replaced by the first sample: a
        // single 30 s poll sees whole rounds only, so one sample can be 7% off
        // and would move every countdown by as much at each launch.
        smoothed += Self.smoothing * (sample - smoothed)
        sampleCount += 1
    }

    /// Starts the long span at an earlier round whose time is known, as a
    /// block's timestamp tells it, so the estimate is the rate over a long
    /// span from the first poll on. The block's time is its proposer's clock
    /// and the observations are this Mac's, so the two clocks' difference
    /// divided by the span is the error, a small fraction of a percent over
    /// the span the poller asks for. Ignored unless it is earlier, in round and
    /// in time, than the span's start.
    public mutating func anchor(round: UInt64, at date: Date) {
        if let first = checkpoints.first, round >= first.round || date >= first.date { return }
        checkpoints.insert(Observation(round: round, date: date), at: 0)
    }

    /// Each 30 s poll sees 10 or 11 whole rounds, so single samples swing by
    /// about 5% and their blend still moves by about 1% from poll to poll:
    /// enough to carry a countdown back and forth across an alert threshold.
    /// Over half an hour or more, one round either way is a small fraction of
    /// a percent.
    private var spanRate: TimeInterval? {
        guard let first = checkpoints.first, let newest else { return nil }
        let elapsed = newest.date.timeIntervalSince(first.date)
        guard elapsed >= Self.longSpan, newest.round > first.round else { return nil }
        let rate = elapsed / Double(newest.round - first.round)
        return Self.plausible.contains(rate) ? rate : nil
    }

    private mutating func extendSpan(round: UInt64, at date: Date) {
        // A round that does not advance, as a lagging backend can report, says
        // nothing new about the rate and must not end the span.
        if let newest, round <= newest.round || date <= newest.date { return }
        let observation = Observation(round: round, date: date)
        newest = observation

        if let last = checkpoints.last, date.timeIntervalSince(last.date) < Self.checkpointSpacing {
            return
        }
        checkpoints.append(observation)
        // The oldest starting point goes only once the next one is a full
        // window old, so after a long sleep the span still reaches back across
        // it, and the rate over the sleep holds just as a single sample's does.
        while checkpoints.count > 1,
            date.timeIntervalSince(checkpoints[1].date) >= Self.spanWindow
        {
            checkpoints.removeFirst()
        }
    }
}
