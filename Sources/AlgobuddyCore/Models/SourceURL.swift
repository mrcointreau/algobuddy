import Foundation

/// What a chain data source URL must be before anything is fetched from it.
///
/// Kept beside `WatchList` for the same reason: the rule is exercised without a
/// settings window behind it, and every field that takes a source URL applies
/// it identically.
public enum SourceURL {

    /// The URL the text names, or nil when no request could reach it: the
    /// scheme must be http or https, and there must be a host.
    ///
    /// `URL(string:)` alone accepts far more. "localhost:8080" parses with
    /// "localhost" as its scheme and no host, "https://" parses with no host,
    /// and every request to either fails as an unsupported URL.
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
