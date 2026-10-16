import Foundation

public struct BlockHeaderResponse: Decodable, Sendable {
    public let block: BlockHeader
}

/// `GET /v2/blocks/{round}?header-only=true`.
///
/// The JSON uses the block's msgpack short keys rather than the friendly names
/// found elsewhere in the API, and there is no generated schema for them. Only
/// what the poller reads is decoded: the seed, which derives the heartbeat
/// challenge, the round, which shows a header is the one asked for, and the
/// timestamp, which with the round times the round clock against a block in
/// the past. Proposal history comes from the indexer's own block-header shape
/// instead.
///
/// Every field is optional because it can be absent from a proxied or trimmed
/// response. A missing seed must surface as a poll failure rather than fail the
/// decode of an otherwise valid header. A missing round cannot be checked, so
/// the seed is taken without it, while the round clock, as without a
/// timestamp, is left to time itself.
public struct BlockHeader: Decodable, Sendable, Equatable {
    public let seed: Data?
    public let round: UInt64?
    /// Seconds since 1970, as the block's proposer set it.
    public let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case seed
        case round = "rnd"
        case timestamp = "ts"
    }
}
