import Foundation

/// State of the periodic heartbeat challenge for one account.
public struct ChallengeState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Within the grace period; answer now.
        case grace
        /// Past grace; a proposer may suspend this account at any block.
        case enforcing
    }

    public let challengeRound: UInt64
    /// Whether this address's leading bits matched the challenge seed.
    public let isChallenged: Bool
    /// Whether the account has proposed or heartbeated since the challenge.
    public let hasAnswered: Bool
    public let roundsUntilDeadline: Int64

    /// Derived from the countdown rather than stored beside it, so the two can
    /// never disagree at the boundary: zero rounds left is `.enforcing`, which
    /// matches every consumer that renders zero remaining time as overdue.
    public var phase: Phase { roundsUntilDeadline > 0 ? .grace : .enforcing }

    /// Challenged and still silent. During `.grace` this is a countdown; in
    /// `.enforcing` the account is already suspendable.
    public var isFailing: Bool { isChallenged && !hasAnswered }

    public func timeUntilDeadline(roundTime: TimeInterval) -> TimeInterval {
        TimeInterval(roundsUntilDeadline) * roundTime
    }
}

/// Mirrors `FindChallenge` / `bitsMatch` in go-algorand `ledger/apply/challenge.go`.
///
/// Every `challengeInterval` rounds a challenge is drawn from that block's seed.
/// An account is challenged when the leading `challengeBits` of its public key
/// match the leading bits of the seed. With `challengeBits == 5`, roughly one
/// online account in 32 per interval. It must then have proposed or heartbeated
/// by `challengeRound + challengeGracePeriod`.
///
/// The whole computation is local: one block header plus the account record, no
/// node access and no credentials. algod normally answers challenges by itself,
/// so a firing alert here means the node is down or its heartbeat service is
/// broken, and at 200 rounds the user has roughly nine minutes.
public enum Challenge {

    /// The most recent challenge round, if challenges have begun. It names spent challenges too;
    /// `evaluate` decides whether the challenge is still in force.
    public static func challengeRound(for currentRound: UInt64, params: ConsensusParams) -> UInt64?
    {
        let interval = params.challengeInterval
        guard interval > 0, currentRound >= interval else { return nil }
        return (currentRound / interval) * interval
    }

    public static func evaluate(
        address: AlgorandAddress,
        seed: Data,
        challengeRound: UInt64,
        currentRound: UInt64,
        lastSeen: UInt64?,
        params: ConsensusParams
    ) -> ChallengeState? {
        // go-algorand's `FindChallenge(ChActive)` treats a challenge as spent
        // once `currentRound > challengeRound + 2 × grace`: past that no
        // proposer can suspend for it, so claiming "suspendable at any block"
        // for the rest of the 1000-round window would be an invented threat.
        guard currentRound <= challengeRound + 2 * params.challengeGracePeriod else { return nil }

        let challenged = bitsMatch([UInt8](seed), address.publicKey, params.challengeBits)
        let deadline = challengeRound + params.challengeGracePeriod
        // go-algorand's `Failed` treats the account as having answered when it
        // was seen at or after the challenge was issued.
        let answered = (lastSeen ?? 0) >= challengeRound

        return ChallengeState(
            challengeRound: challengeRound,
            isChallenged: challenged,
            hasAnswered: answered,
            // Clamping, not trapping: rounds are decoded from a user-configured
            // endpoint, and a garbage value above Int64.max must degrade the
            // countdown, not crash the poller.
            roundsUntilDeadline: Int64(clamping: deadline) - Int64(clamping: currentRound)
        )
    }

    /// True when the first `n` bits of both byte sequences are equal.
    ///
    /// Ported from `bitsMatch`; only ever called with small `n` (5 today).
    public static func bitsMatch(_ a: [UInt8], _ b: [UInt8], _ n: Int) -> Bool {
        guard n >= 0 else { return false }
        let fullBytes = n / 8
        guard a.count >= fullBytes, b.count >= fullBytes else { return false }
        for index in 0..<fullBytes where a[index] != b[index] { return false }

        let remaining = n % 8
        if remaining == 0 { return true }
        guard a.count > fullBytes, b.count > fullBytes else { return false }

        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
        return (a[fullBytes] & mask) == (b[fullBytes] & mask)
    }
}

/// Participation key validity, derived from the on-chain account record, so no
/// admin token is required.
public struct KeyExpiry: Sendable, Equatable {
    public let firstValid: UInt64
    public let lastValid: UInt64
    public let currentRound: UInt64

    /// Clamping for the same reason as `roundsUntilDeadline`: these values come
    /// from a user-configured endpoint and are not trusted to be sane.
    public var roundsRemaining: Int64 { Int64(clamping: lastValid) - Int64(clamping: currentRound) }
    public var hasExpired: Bool { currentRound > lastValid }

    /// The key's whole validity span. Zero when the record is malformed with
    /// `firstValid` past `lastValid`, which otherwise underflows: nothing
    /// validates the ordering on decode, deliberately, since one bad field
    /// should degrade one meter rather than reject the whole account.
    public var totalRounds: UInt64 { lastValid >= firstValid ? lastValid - firstValid : 0 }

    public func timeRemaining(roundTime: TimeInterval) -> TimeInterval {
        TimeInterval(roundsRemaining) * roundTime
    }

    public init(participation: AccountState.Participation, currentRound: UInt64) {
        self.firstValid = participation.voteFirstValid
        self.lastValid = participation.voteLastValid
        self.currentRound = currentRound
    }
}
