import Foundation

/// The optional names the user gives watched addresses.
///
/// A name is a display label only. The address stays the account's identity:
/// a name never replaces it in storage, in a request or on the clipboard, and
/// names stay on this Mac. The rules live here, beside `WatchList`, so they are
/// exercised without a settings window behind them.
public struct AccountNames: Sendable, Equatable {
    /// Long enough for a label, short enough that a list row cannot outgrow
    /// the panel.
    public static let maxLength = 32

    /// Each name by the canonical address it belongs to. Keyed by address
    /// rather than by position, so reordering the list never moves a name.
    public private(set) var stored: [String: String] = [:]

    public init() {}

    /// Names read back from storage. An entry whose key is not a canonical
    /// address, or whose name is empty once trimmed, is dropped.
    public init(stored: [String: String]) {
        for (key, text) in stored {
            guard let address = try? AlgorandAddress(key), address.stringValue == key,
                let name = Self.name(from: text)
            else { continue }
            self.stored[key] = name
        }
    }

    /// The names given beside the accounts of a list. An entry without an
    /// account names nothing, and when two entries share an account the first
    /// one's name stands, as the list keeps the first. Built from the list
    /// alone, so a name whose address has left it is gone.
    public init(_ entries: [(account: AlgorandAddress?, name: String)]) {
        var seen = Set<AlgorandAddress>()
        for entry in entries {
            guard let account = entry.account, seen.insert(account).inserted else { continue }
            stored[account.stringValue] = Self.name(from: entry.name)
        }
    }

    /// What a name field's text amounts to: trimmed, cut to `maxLength`
    /// characters, and nil when nothing is left, which means no name.
    public static func name(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    public func name(for address: AlgorandAddress) -> String? {
        stored[address.stringValue]
    }

    /// The label an account goes by: its name when it has one, otherwise
    /// `fallback`, which is meant to be its short address.
    public func label(for address: AlgorandAddress, otherwise fallback: String) -> String {
        name(for: address) ?? fallback
    }
}
