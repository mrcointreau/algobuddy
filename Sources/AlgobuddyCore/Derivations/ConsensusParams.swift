import Foundation

/// Consensus constants that govern incentives and suspension.
///
/// These are **protocol-version dependent** and hardcoded to v40. Nothing checks
/// the version the chain actually reports, so when a new consensus version ships,
/// `Absence` and `Challenge` will go on using these numbers without saying so.
/// Keying them by `/v2/status.last-version` is the fix.
///
/// Values transcribed from go-algorand `config/consensus.go` (`v40`) and
/// `ledger/eval/eval.go` (`absentFactor`), not from documentation.
public struct ConsensusParams: Sendable, Equatable {
    /// Incentive eligibility requires a balance within [min, max].
    public let minBalance: MicroAlgos
    public let maxBalance: MicroAlgos
    public let challengeInterval: UInt64
    public let challengeGracePeriod: UInt64
    public let challengeBits: Int
    /// Multiplier on the expected proposal interval before an account counts as
    /// absent. This is 20, not 10; see `ledger/eval/eval.go`.
    public let absentFactor: UInt64

    public static let v40 = ConsensusParams(
        minBalance: MicroAlgos(30_000_000_000),
        maxBalance: MicroAlgos(70_000_000_000_000),
        challengeInterval: 1000,
        challengeGracePeriod: 200,
        challengeBits: 5,
        absentFactor: 20
    )

    /// Whether a balance sits in the window that earns proposer payouts.
    public func isBalanceEligible(_ amount: MicroAlgos) -> Bool {
        amount >= minBalance && amount <= maxBalance
    }
}
