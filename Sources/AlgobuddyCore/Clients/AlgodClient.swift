import Foundation

public protocol HTTPFetching: Sendable {
    func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    let session: URLSession

    public init(session: URLSession = URLSessionFetcher.privateSession) { self.session = session }

    public func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AlgodError.notHTTP }
        // A redirect the session refused arrives as the redirect response itself.
        if Self.isRefusedRedirect(http) { throw AlgodError.redirectRefused }
        return (data, http.statusCode)
    }

    /// The session every client uses unless a test supplies its own.
    ///
    /// - No HTTP cache and no cookies: request URLs name the watched addresses,
    ///   and nothing about them is worth keeping on disk.
    /// - A deadline for the whole request, not only for each silence: a server
    ///   that trickles a byte every few seconds would otherwise hold a poll open
    ///   indefinitely, and every later poll with it.
    /// - A redirect only within the host that was asked, and never from https
    ///   down to http, so the configured hosts stay the only ones contacted.
    /// - A plain user agent, which names the app and not the system.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "algobuddy"]
        return URLSession(
            configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// Whether a response is a redirect that the session declined to follow.
    static func isRefusedRedirect(_ response: HTTPURLResponse) -> Bool {
        (300...399).contains(response.statusCode)
            && response.value(forHTTPHeaderField: "Location") != nil
    }
}

/// Which redirects the private session follows.
enum RedirectPolicy {
    /// Only to the host that was asked, and never from https down to http.
    static func allows(from original: URL, to target: URL) -> Bool {
        guard let from = original.host?.lowercased(), let to = target.host?.lowercased(),
            from == to
        else { return false }
        return original.scheme?.lowercased() != "https" || target.scheme?.lowercased() == "https"
    }
}

/// Applies `RedirectPolicy` for the private session, against the host of the
/// request as first made, so a chain of redirects cannot walk away from it.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = task.originalRequest?.url, let target = request.url,
            RedirectPolicy.allows(from: original, to: target)
        else { return nil }
        return request
    }
}

/// Joins an API path onto a base URL **without discarding the base's own path**.
///
/// `URL(string: "/v2/status", relativeTo: "https://host/algod")` resolves to
/// `https://host/v2/status`, because an absolute-path reference replaces the
/// base path entirely, per RFC 3986. Any deployment that mounts algod behind a reverse
/// proxy at a sub-path would silently 404 on every request, and the resulting
/// error blames the user's address rather than the URL.
enum Endpoint {
    static func resolve(_ path: String, against base: URL) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix =
            components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path

        components.path = prefix + String(halves[0])
        // Already percent-encoded by the callers, which build their own queries.
        components.percentEncodedQuery = halves.count > 1 ? String(halves[1]) : nil
        return components.url ?? base
    }
}

public enum AlgodError: Error, Equatable, Sendable {
    case notHTTP
    /// The endpoint needs a token that was not configured.
    case unauthorized(path: String)
    case notFound(path: String)
    case http(status: Int, path: String)
    case decoding(path: String, description: String)
    /// The endpoint redirected to another host, or from https down to http,
    /// which the private session does not follow.
    case redirectRefused
}

extension AlgodError {
    /// The error a status other than 200 stands for, nil for 200. Shared by
    /// algod and the indexer, so the message for each stage can say what a 401
    /// or a 404 means there.
    init?(status: Int, path: String) {
        switch status {
        case 200: return nil
        case 401: self = .unauthorized(path: path)
        case 404: self = .notFound(path: path)
        default: self = .http(status: status, path: path)
        }
    }
}

/// Client for the three algod endpoints algobuddy reads.
///
/// The token is optional and, against a public API provider, unnecessary, since
/// those serve these endpoints unauthenticated. It exists so the same client can point
/// at an algod that does require one. A 401 surfaces as `.unauthorized` rather
/// than empty data, so the cause is visible instead of looking like an outage.
public struct AlgodClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let fetcher: HTTPFetching

    public init(baseURL: URL, token: String? = nil, fetcher: HTTPFetching = URLSessionFetcher()) {
        self.baseURL = baseURL
        self.token = token
        self.fetcher = fetcher
    }

    public func account(_ address: String) async throws -> AccountState {
        try await decode(AccountState.self, from: "/v2/accounts/\(address)?exclude=all")
    }

    public func blockHeader(_ round: UInt64) async throws -> BlockHeader {
        try await decode(
            BlockHeaderResponse.self,
            from: "/v2/blocks/\(round)?header-only=true"
        ).block
    }

    public func supply() async throws -> LedgerSupply {
        try await decode(LedgerSupply.self, from: "/v2/ledger/supply")
    }

    // MARK: - Internals

    private func url(_ path: String) -> URL {
        Endpoint.resolve(path, against: baseURL)
    }

    private func headers() -> [String: String] {
        guard let token else { return [:] }
        return ["X-Algo-API-Token": token]
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from path: String,
        timeout: TimeInterval = 15
    ) async throws -> T {
        let (data, code) = try await fetcher.get(url(path), headers: headers(), timeout: timeout)
        if let error = AlgodError(status: code, path: path) { throw error }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AlgodError.decoding(path: path, description: String(describing: error))
        }
    }
}

/// Client for an Algorand indexer, used only to backfill proposal history.
///
/// Everything algobuddy shows live comes from algod; this exists so that a
/// freshly installed app can display "earned this week" instead of starting
/// from zero.
public struct IndexerClient: Sendable {
    public let baseURL: URL
    private let fetcher: HTTPFetching

    public init(baseURL: URL, fetcher: HTTPFetching = URLSessionFetcher()) {
        self.baseURL = baseURL
        self.fetcher = fetcher
    }

    public struct BlockHeadersPage: Decodable, Sendable {
        public let blocks: [ProposedBlock]
        public let nextToken: String?

        enum CodingKeys: String, CodingKey {
            case blocks
            case nextToken = "next-token"
        }
    }

    public struct ProposedBlock: Decodable, Sendable, Equatable {
        public let round: UInt64
        public let proposer: String?
        public let proposerPayout: MicroAlgos?
        public let timestamp: Int64?

        enum CodingKeys: String, CodingKey {
            case round, proposer, timestamp
            case proposerPayout = "proposer-payout"
        }
    }

    /// - Parameter minRound: **Effectively required.** Results come back
    ///   oldest-first, so without a lower bound page one is ancient history and
    ///   recent proposals sit many pages deep.
    public func blockHeaders(
        proposer: String,
        minRound: UInt64? = nil,
        limit: Int = 100,
        next: String? = nil
    ) async throws -> BlockHeadersPage {
        var path = "/v2/block-headers?proposers=\(proposer)&limit=\(limit)"
        if let minRound { path += "&min-round=\(minRound)" }
        if let next {
            // The token is opaque server data, so it must be percent-encoded to
            // honour `Endpoint.resolve`'s already-encoded precondition: a
            // base64-flavoured token containing "+" would otherwise decode
            // server-side as a space and break every page after the first.
            let encoded = next.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? next
            path += "&next=\(encoded)"
        }
        let (data, code) = try await fetcher.get(
            Endpoint.resolve(path, against: baseURL), headers: [:], timeout: 20)
        if let error = AlgodError(status: code, path: path) { throw error }
        do {
            return try JSONDecoder().decode(BlockHeadersPage.self, from: data)
        } catch {
            throw AlgodError.decoding(path: path, description: String(describing: error))
        }
    }
}
