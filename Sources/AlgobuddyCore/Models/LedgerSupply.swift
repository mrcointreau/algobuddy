import Foundation

/// `GET /v2/ledger/supply`. Supplies the absenteeism denominator.
///
/// Note the inconsistent casing in the live response: `current_round` uses an
/// underscore while the money fields use hyphens.
public struct LedgerSupply: Decodable, Sendable, Equatable {
    public let currentRound: UInt64
    public let onlineMoney: MicroAlgos
    public let onlineStake: MicroAlgos?
    public let totalMoney: MicroAlgos

    /// Prefer `online-stake`, falling back to `online-money` on algod versions
    /// that predate it. The two differ slightly, and `online-stake` is the
    /// figure the absenteeism arithmetic is defined against.
    public var effectiveOnlineStake: MicroAlgos { onlineStake ?? onlineMoney }

    enum CodingKeys: String, CodingKey {
        case currentRound = "current_round"
        case onlineMoney = "online-money"
        case onlineStake = "online-stake"
        case totalMoney = "total-money"
    }
}
