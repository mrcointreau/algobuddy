import Foundation

/// How much slack an online account has before the protocol may suspend it for
/// absenteeism.
public struct AbsenceAssessment: Sendable, Equatable {
    /// `absentFactor ×` the account's expected interval between proposals.
    /// Exceeding this permits suspension.
    public let allowableLag: UInt64
    public let roundsSinceLastSeen: UInt64
    /// Negative once the account is suspendable.
    public let headroomRounds: Int64
    /// 0 = just seen, 1.0 = at the suspension boundary.
    public let ratio: Double
    public let isAbsent: Bool

    public func headroom(roundTime: TimeInterval) -> TimeInterval {
        TimeInterval(headroomRounds) * roundTime
    }
}

/// Mirrors `isAbsent` in go-algorand `ledger/eval/eval.go`.
///
/// The shape is worth internalising: `allowableLag` is inversely proportional to
/// stake, so a **large staker is suspended sooner** than a small one after going
/// dark. That is the opposite of most people's intuition and worth saying out
/// loud in the UI.
public enum Absence {

    public static func assess(
        accountStake: MicroAlgos,
        totalOnlineStake: MicroAlgos,
        lastSeen: UInt64?,
        currentRound: UInt64,
        params: ConsensusParams
    ) -> AbsenceAssessment? {
        // go-algorand carves these out explicitly: an account that has never been seen was online
        // before payouts began, and it is noticed at its next proposal or keyreg rather than
        // treated as absent.
        guard let lastSeen, lastSeen > 0, accountStake.raw > 0 else { return nil }

        guard
            let allowableLag = muldiv(params.absentFactor, totalOnlineStake.raw, accountStake.raw),
            allowableLag <= UInt64(UInt32.max)
        else {
            // Overflow, or a lag longer than any network could survive. Source
            // returns "not absent" rather than attempting the arithmetic.
            return nil
        }

        let elapsed = currentRound > lastSeen ? currentRound - lastSeen : 0
        // Clamping and reordering, not trapping: the rounds come from a
        // user-configured endpoint, and `elapsed` above Int64.max or a
        // `lastSeen + allowableLag` sum past UInt64.max must degrade the
        // numbers rather than crash the poller.
        let headroom = Int64(clamping: allowableLag) - Int64(clamping: elapsed)

        return AbsenceAssessment(
            allowableLag: allowableLag,
            roundsSinceLastSeen: elapsed,
            headroomRounds: headroom,
            ratio: allowableLag > 0 ? Double(elapsed) / Double(allowableLag) : 0,
            // The overflow-safe form of the source's `lastSeen + allowableLag
            // < currentRound`.
            isAbsent: elapsed > allowableLag
        )
    }

    /// `a × b / c` at full 128-bit intermediate width, as `basics.Muldiv` does.
    /// Returns `nil` on overflow rather than trapping.
    static func muldiv(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64? {
        guard c != 0 else { return nil }
        let product = a.multipliedFullWidth(by: b)
        // `dividingFullWidth` traps if the quotient does not fit.
        guard product.high < c else { return nil }
        return c.dividingFullWidth(product).quotient
    }
}
