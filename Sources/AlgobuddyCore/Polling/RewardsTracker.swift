import Foundation

/// Proposal and payout totals over the two spans the panel shows.
public struct RewardsSummary: Sendable, Equatable {
    public var proposals24h = 0
    public var proposals7d = 0
    public var earned24h = MicroAlgos.zero
    public var earned7d = MicroAlgos.zero
    /// Blocks proposed in the last 7 days that paid nothing, because the account
    /// was not eligible or balance sat outside the payout window. Scoped to the
    /// widest span the summary itself shows, so the count can never exceed the
    /// 7-day proposal figure it is presented beside.
    public var unpaidProposals = 0
    /// The indexer had more pages than the fetch was willing to read, so these
    /// totals are a floor rather than the whole window. Surfaced instead of
    /// silently truncated, because a bounded fetch that presents itself as complete
    /// is worse than one that admits the bound.
    public var isTruncated = false

    public init() {}
}

/// Accumulates proposed blocks fetched from an indexer.
///
/// Live monitoring never needs this. It exists so a freshly installed app can
/// show "earned this week" instead of starting from zero. Deriving it from the
/// indexer rather than polling every block header keeps this to a handful of
/// requests per hour against a public endpoint.
public struct RewardsTracker: Sendable, Equatable {
    private var blocks: [UInt64: IndexerClient.ProposedBlock] = [:]
    public private(set) var windowStartRound: UInt64?

    public init() {}

    public var count: Int { blocks.count }

    public mutating func ingest(
        _ proposed: [IndexerClient.ProposedBlock], windowStartRound: UInt64?
    ) {
        for block in proposed { blocks[block.round] = block }
        if let windowStartRound {
            self.windowStartRound = windowStartRound
            // Drop anything older than the window being claimed, so a summary
            // never mixes a wider earlier history into the current span.
            blocks = blocks.filter { $0.key >= windowStartRound }
        }
    }

    /// The newest round in the cache, so an incremental fetch can resume past
    /// what is already held instead of re-downloading the whole window.
    public var highestRound: UInt64? { blocks.keys.max() }

    public func summary(now: Date) -> RewardsSummary {
        var summary = RewardsSummary()

        let dayAgo = now.addingTimeInterval(-86_400)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        for block in blocks.values {
            let payout = block.proposerPayout ?? .zero

            guard let timestamp = block.timestamp else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            if date >= weekAgo {
                summary.proposals7d += 1
                summary.earned7d = MicroAlgos(summary.earned7d.raw &+ payout.raw)
                if payout.raw == 0 { summary.unpaidProposals += 1 }
            }
            if date >= dayAgo {
                summary.proposals24h += 1
                summary.earned24h = MicroAlgos(summary.earned24h.raw &+ payout.raw)
            }
        }

        return summary
    }
}
