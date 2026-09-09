import Foundation

/// What several watched accounts amount to together.
///
/// The two countdowns take the closest deadline rather than an average or a
/// total: a portfolio is as healthy as its worst account, and the number worth
/// showing is the one that runs out first. The rewards figures and the stake
/// are sums, because those genuinely add up across accounts.
///
/// Pure over the entries of one cycle, so it can be derived wherever it is
/// needed rather than carried and kept in step.
public struct PortfolioSummary: Sendable, Equatable {
    /// How many of the watched accounts are Online. Accounts whose fetch failed
    /// count towards neither this nor `accountCount`, since nothing is known
    /// about them this cycle.
    public var onlineAccounts = 0
    /// How many accounts contributed data at all.
    public var accountCount = 0
    public var totalStake = MicroAlgos.zero
    /// Time until the first account may be suspended for absenteeism. Nil when
    /// no account has an assessment, rather than zero, which would read as a
    /// suspension due right now. Negative once an account is already past the
    /// limit, which is the deadline that most deserves to win.
    public var closestAbsenceHeadroom: TimeInterval?
    /// Time until the first account's participation keys expire, on the same
    /// terms as `closestAbsenceHeadroom`.
    public var closestKeyExpiry: TimeInterval?
    public var proposals24h = 0
    public var proposals7d = 0
    public var earned24h = MicroAlgos.zero
    public var earned7d = MicroAlgos.zero
    /// Whether any account has reported a proposal history at all. The sums
    /// below read as zero both before the first indexer answer and for a
    /// portfolio that has genuinely proposed nothing, and only this tells the
    /// two apart, so a surface can stay silent rather than claim "0 blocks".
    public var hasRewards = false
    /// Any account whose proposal history was cut short by the page budget
    /// makes the totals above a floor, so the caveat travels with them.
    public var isTruncated = false

    public init() {}

    public init(entries: [AccountUpdate], roundTime: TimeInterval) {
        self.init()

        for entry in entries {
            if let account = entry.account {
                accountCount += 1
                totalStake = MicroAlgos(totalStake.raw &+ account.amount.raw)
                if account.status == .online { onlineAccounts += 1 }
            }

            if let absence = entry.absence {
                closestAbsenceHeadroom = Self.closest(
                    closestAbsenceHeadroom, absence.headroom(roundTime: roundTime))
            }
            if let expiry = entry.keyExpiry {
                closestKeyExpiry = Self.closest(
                    closestKeyExpiry, expiry.timeRemaining(roundTime: roundTime))
            }

            if let rewards = entry.rewards {
                hasRewards = true
                proposals24h += rewards.proposals24h
                proposals7d += rewards.proposals7d
                earned24h = MicroAlgos(earned24h.raw &+ rewards.earned24h.raw)
                earned7d = MicroAlgos(earned7d.raw &+ rewards.earned7d.raw)
                isTruncated = isTruncated || rewards.isTruncated
            }
        }
    }

    private static func closest(_ current: TimeInterval?, _ candidate: TimeInterval) -> TimeInterval
    {
        min(current ?? candidate, candidate)
    }
}
