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
    /// This account's own failure: its account fetch, or its rewards query. The
    /// stages shared by every account, supply and the challenge seed, fail for
    /// the cycle rather than for one address and are reported there.
    public let failure: PollFailure?

    public init(
        address: AlgorandAddress,
        account: AccountState? = nil,
        absence: AbsenceAssessment? = nil,
        challenge: ChallengeState? = nil,
        keyExpiry: KeyExpiry? = nil,
        rewards: RewardsSummary? = nil,
        failure: PollFailure? = nil
    ) {
        self.address = address
        self.account = account
        self.absence = absence
        self.challenge = challenge
        self.keyExpiry = keyExpiry
        self.rewards = rewards
        self.failure = failure
    }
}
