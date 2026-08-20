import Foundation

public struct BlockHeaderResponse: Decodable, Sendable {
    public let block: BlockHeader
}

/// `GET /v2/blocks/{round}?header-only=true`.
///
/// The JSON uses the block's msgpack short keys rather than the friendly names
/// found elsewhere in the API, and there is no generated schema for them. Only
/// the seed is decoded, because deriving the heartbeat challenge is the sole
/// reason this endpoint is fetched; proposal history comes from the indexer's
/// own block-header shape instead.
public struct BlockHeader: Decodable, Sendable, Equatable {
    /// Optional because the field can be absent from a proxied or trimmed
    /// response, and a missing seed must surface as a poll failure rather than
    /// fail the decode of an otherwise valid header.
    public let seed: Data?
}
