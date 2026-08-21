import Foundation

/// A version that can be ordered against another.
///
/// The running version is stamped from `git describe`, so it arrives as a bare
/// triplet on a release build and as a triplet followed by a distance, a commit
/// hash or a `-dirty` marker on a development build. Only the leading triplet
/// carries ordering, so anything after the first hyphen is dropped, which is
/// what makes a development build on top of the newest release compare equal to
/// it rather than older than it.
///
/// A bare commit hash, which is what `git describe` produces before the first
/// tag exists, has no triplet and therefore no order: it parses to nil rather
/// than to a version that would invent one.
struct ReleaseVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Release tags are `vX.Y.Z` while the stamped version has already had
        // the prefix stripped, so both spellings have to parse.
        if body.hasPrefix("v") { body.removeFirst() }

        let core = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // `Int` accepts underscores, a leading sign and non-ASCII digits, none
        // of which belong in a version, so the characters are checked first.
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The outcome of one update check, everything the UI needs to render.
///
/// `cannotCompare` exists so that an unorderable running version never reports
/// "up to date": that claim would have no evidence behind it, and the link is
/// offered instead so the answer is still one click away.
public enum UpdateStatus: Equatable, Sendable {
    case upToDate(latest: String)
    case updateAvailable(version: String, url: URL)
    case cannotCompare(latest: String, url: URL)
    case failed(message: String)
}

/// Asks GitHub for the latest published release and compares it with the
/// running build.
///
/// Check and notify only. Nothing is downloaded, nothing is executed, and the
/// single anonymous request happens when the user asks for it: there is no
/// timer, no background poll and no state kept between checks. The request
/// carries no token and no account data, so all github.com learns is that some
/// address asked which release is newest.
///
/// Failures are returned rather than thrown, because every one of them has the
/// same consequence for the caller: a quiet line of text next to the button.
public struct UpdateChecker: Sendable {
    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/mrcointreau/algobuddy/releases/latest")

    private let endpoint: URL?
    private let fetcher: HTTPFetching

    public init(
        endpoint: URL? = UpdateChecker.latestReleaseURL, fetcher: HTTPFetching = URLSessionFetcher()
    ) {
        self.endpoint = endpoint
        self.fetcher = fetcher
    }

    /// - Parameter runningVersion: The bundle's stamped version, or nil when
    ///   there is no bundle to read one from.
    public func check(runningVersion: String?) async -> UpdateStatus {
        guard let endpoint else { return .failed(message: "The release address is not valid.") }

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetcher.get(
                endpoint,
                // The versioned media type, which is what GitHub asks callers
                // to send so a future default cannot reshape the response.
                headers: ["Accept": "application/vnd.github+json"],
                timeout: 15)
        } catch {
            return .failed(message: "Could not reach github.com.")
        }

        guard status == 200 else { return .failed(message: Self.message(for: status)) }
        // A tag that carries no triplet is a failed check rather than a guess:
        // it can be neither newer nor older than the running build.
        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
            let latest = ReleaseVersion(release.tagName)
        else {
            return .failed(message: "Could not read the latest release.")
        }

        let name = Self.displayName(of: release.tagName)
        guard let running = runningVersion.flatMap(ReleaseVersion.init) else {
            return .cannotCompare(latest: name, url: release.htmlURL)
        }
        return running < latest
            ? .updateAvailable(version: name, url: release.htmlURL)
            : .upToDate(latest: name)
    }

    // MARK: - Internals

    /// Tags are published as `vX.Y.Z` while the app displays its version
    /// without the prefix, so the two read the same when shown side by side.
    private static func displayName(of tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func message(for status: Int) -> String {
        switch status {
        // Anonymous callers share one hourly quota per address, which a
        // network behind a single address can exhaust without this app's help.
        case 403, 429: "GitHub is rate limiting this network. Try again later."
        case 404: "No release has been published yet."
        default: "GitHub returned \(status)."
        }
    }

    /// Only the two fields the check needs. Both are required, so a response
    /// missing either one is an unreadable answer rather than a partial one.
    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
