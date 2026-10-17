import Foundation

/// The ordered list of watched accounts: how a stored one reads back, and what
/// a list of edited rows amounts to.
///
/// Both rules live here rather than in the settings layer so they can be
/// exercised without a preference store or a window behind them, and so every
/// surface that resolves rows into accounts resolves them identically.
public enum WatchList {

    /// The stored addresses, in the order they were watched in.
    ///
    /// A store holds either the list or a lone address, and a lone address
    /// names exactly one watched account, so it reads back as a one-element
    /// list with nothing lost and nothing to ask the user. The list wins
    /// wherever both are present, and an empty list stands: a list emptied on
    /// purpose must not be answered with the lone value it was emptied of.
    public static func restore(list: [String]?, single: String?) -> [String] {
        let stored = list ?? single.map { [$0] } ?? []
        return
            stored
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One edited row: what it says now, and the account it held when the list
    /// was last applied.
    public struct Row: Sendable {
        public var text: String
        public var held: AlgorandAddress?

        public init(text: String, held: AlgorandAddress? = nil) {
            self.text = text
            self.held = held
        }

        /// The account this row watches: the one its text names, or, while the
        /// text names none, the one it held, so an edit in progress leaves its
        /// account watched. A blank row watches nothing, which is how clearing
        /// a row removes its account.
        public var watched: AlgorandAddress? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (try? AlgorandAddress(trimmed)) ?? held
        }
    }

    /// The accounts a list of edited rows amounts to.
    ///
    /// A blank row is skipped rather than refused: a row added and not yet
    /// typed into is not a mistake, and rejecting the whole list over it would
    /// stop the completed rows from being watched. A half-typed row stands for
    /// the account it held, or for none, so it holds back nothing else: a
    /// removal or an addition made beside it still applies. Repeats are
    /// dropped, keeping the first, because the same address twice would cost
    /// two fetches a cycle and appear twice on every surface.
    public static func resolve(_ rows: [Row]) -> [AlgorandAddress] {
        var seen = Set<AlgorandAddress>()
        var resolved = [AlgorandAddress]()
        for row in rows {
            guard let address = row.watched else { continue }
            if seen.insert(address).inserted { resolved.append(address) }
        }
        return resolved
    }

    /// The positions of the rows that `resolve` drops as repeats: those whose
    /// account an earlier row already watches, by its text or by the account
    /// it holds while half-typed.
    public static func repeats(_ rows: [Row]) -> Set<Int> {
        var seen = Set<AlgorandAddress>()
        var found = Set<Int>()
        for (index, row) in rows.enumerated() {
            guard let address = row.watched else { continue }
            if !seen.insert(address).inserted { found.insert(index) }
        }
        return found
    }
}
