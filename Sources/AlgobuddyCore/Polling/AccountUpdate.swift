import Foundation

/// One watched address's share of a poll cycle.
///
/// The round, the round time and the online-stake denominator are the same for
/// every account in a cycle, so they belong to the cycle rather than here. What
/// remains is what differs from one address to the next.
public struct AccountUpdate: Sendable {
    public let address: AlgorandAddress
    public let account: AccountState?
    public let absence: AbsenceAssessment?
    public let challenge: ChallengeState?
    public let keyExpiry: KeyExpiry?
    public let rewards: RewardsSummary?
    /// This account's own failure: its account fetch, or its latest rewards
    /// query. The stages shared by every account, supply and the challenge
    /// seed, fail for the cycle rather than for one address and are reported
    /// there.
    public let failure: PollFailure?
    /// When the figures above were fetched: the cycle's own time, or earlier
    /// for a stale entry. Nil when nothing has been fetched for the account.
    public let fetchedAt: Date?
    /// Whether this cycle's fetch of the account failed and the figures are
    /// its last good ones, carried forward as they were rather than derived
    /// again against a round they do not belong to.
    public let isStale: Bool

    public init(
        address: AlgorandAddress,
        account: AccountState? = nil,
        absence: AbsenceAssessment? = nil,
        challenge: ChallengeState? = nil,
        keyExpiry: KeyExpiry? = nil,
        rewards: RewardsSummary? = nil,
        failure: PollFailure? = nil,
        fetchedAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.address = address
        self.account = account
        self.absence = absence
        self.challenge = challenge
        self.keyExpiry = keyExpiry
        self.rewards = rewards
        self.failure = failure
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }

    /// This entry, carried into a later cycle whose fetch of the account failed.
    func stale(failure: PollFailure?) -> AccountUpdate {
        AccountUpdate(
            address: address, account: account, absence: absence, challenge: challenge,
            keyExpiry: keyExpiry, rewards: rewards, failure: failure, fetchedAt: fetchedAt,
            isStale: true)
    }
}
