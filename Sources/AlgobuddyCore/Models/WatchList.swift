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

    /// The accounts a list of edited rows amounts to.
    ///
    /// A blank row is skipped rather than refused: a row added and not yet
    /// typed into is not a mistake, and rejecting the whole list over it would
    /// stop the completed rows from being watched. Repeats are dropped, keeping
    /// the first, because the same address twice would cost two fetches a cycle
    /// and appear twice on every surface.
    ///
    /// - Throws: the first unparseable row's `AlgorandAddress.AddressError`, so
    ///   a caller can leave a running watch alone while a row is half typed.
    public static func resolve(_ rows: [String]) throws -> [AlgorandAddress] {
        var seen = Set<AlgorandAddress>()
        var resolved = [AlgorandAddress]()
        for row in rows where !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let address = try AlgorandAddress(row)
            if seen.insert(address).inserted { resolved.append(address) }
        }
        return resolved
    }
}
