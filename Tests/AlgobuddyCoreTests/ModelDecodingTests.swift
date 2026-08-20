import Foundation
import Testing

@testable import AlgobuddyCore

/// An absolute-path reference replaces the base path entirely, per RFC 3986, so
/// joining URLs naively drops any prefix and an algod reached at a sub-path 404s
/// on every call.
@Suite("Endpoint resolution")
struct EndpointTests {
    @Test(
        "preserves a base URL's path prefix",
        arguments: [
            ("https://host", "/v2/status", "https://host/v2/status"),
            ("https://host/", "/v2/status", "https://host/v2/status"),
            ("https://host/algod", "/v2/status", "https://host/algod/v2/status"),
            ("https://host/algod/", "/v2/status", "https://host/algod/v2/status"),
            ("https://host:8080/a/b", "/health", "https://host:8080/a/b/health"),
        ])
    func prefixes(base: String, path: String, expected: String) throws {
        let url = Endpoint.resolve(path, against: try #require(URL(string: base)))
        #expect(url.absoluteString == expected)
    }

    /// Testing `Endpoint.resolve` alone is not enough: it would keep passing if
    /// a caller went back to building URLs by hand. These exercise the clients'
    /// real request paths.
    @Test("AlgodClient requests land under the base path")
    func clientHonoursPrefix() async throws {
        let stub = StubFetcher()
        let client = AlgodClient(
            baseURL: try #require(URL(string: "https://host/algod")),
            token: "t", fetcher: stub)

        _ = try? await client.supply()
        _ = try? await client.account("ABC")

        #expect(
            stub.requests == [
                "https://host/algod/v2/ledger/supply",
                "https://host/algod/v2/accounts/ABC?exclude=all",
            ])
    }

    @Test("IndexerClient requests land under the base path")
    func indexerHonoursPrefix() async throws {
        let stub = StubFetcher()
        let client = IndexerClient(
            baseURL: try #require(URL(string: "https://host/idx")), fetcher: stub)

        _ = try? await client.blockHeaders(proposer: "ABC", minRound: 10, limit: 100)

        let request = try #require(stub.requests.first)
        #expect(request.hasPrefix("https://host/idx/v2/block-headers?"))
        #expect(request.contains("min-round=10"))
    }

    @Test("keeps query strings intact")
    func queries() throws {
        let base = try #require(URL(string: "https://host/algod"))
        #expect(
            Endpoint.resolve("/v2/accounts/ABC?exclude=all", against: base).absoluteString
                == "https://host/algod/v2/accounts/ABC?exclude=all")
        #expect(
            Endpoint.resolve("/v2/blocks/42?header-only=true", against: base).absoluteString
                == "https://host/algod/v2/blocks/42?header-only=true")
        // Multiple parameters must survive the single split on "?".
        #expect(
            Endpoint.resolve("/v2/block-headers?proposers=A&limit=100", against: base)
                .absoluteString
                == "https://host/algod/v2/block-headers?proposers=A&limit=100")
    }
}

/// Decoding is checked against captured wire responses rather than hand-written
/// JSON, because the field names in question are not in any generated schema:
/// block headers use the msgpack short keys, and `/v2/ledger/supply` mixes
/// snake_case with kebab-case.
@Suite("Model decoding")
struct ModelDecodingTests {

    // Block contents are immutable, so those values are safe to hardcode. The
    // live account fixture drifts, so that test asserts structure instead.

    /// The header exists solely to carry the challenge seed, and the fixtures
    /// are real mainnet responses with their msgpack short keys, so this pins
    /// both the key name and the base64 decode against live data.
    @Test("block headers decode their seed from captured mainnet responses")
    func blockHeaderSeed() throws {
        for fixture in ["mainnet-block-64030256.json", "mainnet-block-64030253-nopayout.json"] {
            let header = try Fixture.decode(BlockHeaderResponse.self, fixture).block
            #expect(header.seed?.count == 32)
        }
    }

    @Test("account exposes participation and incentive fields")
    func account() throws {
        let account = try Fixture.decode(AccountState.self, "mainnet-account.json")
        #expect(account.status == .online)
        #expect(account.amount.raw > 0)
        #expect(account.incentiveEligible == true)

        let participation = try #require(account.participation)
        #expect(participation.voteLastValid > participation.voteFirstValid)

        // lastSeen is the later of the two activity markers.
        let expected = [account.lastProposed, account.lastHeartbeat].compactMap { $0 }.max()
        #expect(account.lastSeen == expected)
    }

    @Test("ledger supply handles its mixed key casing")
    func supply() throws {
        let supply = try Fixture.decode(LedgerSupply.self, "mainnet-supply.json")
        #expect(supply.currentRound > 0)  // current_round
        #expect(supply.onlineMoney.raw > 0)  // online-money
        #expect(supply.totalMoney > supply.onlineMoney)
        #expect(supply.effectiveOnlineStake.raw > 0)
    }

}
