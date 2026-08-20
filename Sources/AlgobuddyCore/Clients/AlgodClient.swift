import Foundation

public protocol HTTPFetching: Sendable {
    func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AlgodError.notHTTP }
        return (data, http.statusCode)
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
        switch code {
        case 200: break
        case 401: throw AlgodError.unauthorized(path: path)
        case 404: throw AlgodError.notFound(path: path)
        default: throw AlgodError.http(status: code, path: path)
        }
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
        guard code == 200 else { throw AlgodError.http(status: code, path: path) }
        do {
            return try JSONDecoder().decode(BlockHeadersPage.self, from: data)
        } catch {
            throw AlgodError.decoding(path: path, description: String(describing: error))
        }
    }
}
