import Foundation

/// `GET /v2/accounts/{address}`.
///
/// Every field algobuddy needs for participation monitoring is here, and this is
/// a `public` endpoint with no admin token. That is what lets the whole chain
/// run against any public API provider.
public struct AccountState: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        case online = "Online"
        case offline = "Offline"
        case notParticipating = "NotParticipating"
    }

    public let address: String
    public let status: Status
    public let amount: MicroAlgos
    public let round: UInt64
    /// Whether the account opted into consensus incentives. An Online account
    /// with this false proposes blocks and earns nothing.
    public let incentiveEligible: Bool?
    public let lastProposed: UInt64?
    public let lastHeartbeat: UInt64?
    public let participation: Participation?

    public struct Participation: Decodable, Sendable, Equatable {
        public let voteFirstValid: UInt64
        public let voteLastValid: UInt64
        public let voteKeyDilution: UInt64

        public init(voteFirstValid: UInt64, voteLastValid: UInt64, voteKeyDilution: UInt64) {
            self.voteFirstValid = voteFirstValid
            self.voteLastValid = voteLastValid
            self.voteKeyDilution = voteKeyDilution
        }

        enum CodingKeys: String, CodingKey {
            case voteFirstValid = "vote-first-valid"
            case voteLastValid = "vote-last-valid"
            case voteKeyDilution = "vote-key-dilution"
        }
    }

    /// The input to the absenteeism check: the most recent round at which the
    /// protocol saw this account, by either route.
    ///
    /// `nil` when the account has never been seen. `isAbsent` in go-algorand
    /// treats `lastSeen == 0` as never-absent rather than maximally overdue.
    public var lastSeen: UInt64? {
        let candidates = [lastProposed, lastHeartbeat].compactMap { $0 }.filter { $0 > 0 }
        return candidates.max()
    }

    enum CodingKeys: String, CodingKey {
        case address, amount, round, status, participation
        case incentiveEligible = "incentive-eligible"
        case lastProposed = "last-proposed"
        case lastHeartbeat = "last-heartbeat"
    }
}
