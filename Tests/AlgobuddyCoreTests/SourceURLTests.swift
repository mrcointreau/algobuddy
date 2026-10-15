import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Source URL")
struct SourceURLTests {
    @Test("an http or https URL that names a host is accepted as typed")
    func acceptsHostURLs() {
        for text in [
            "https://mainnet-api.algonode.cloud",
            "http://localhost:8080",
            "http://127.0.0.1:4001",
            "http://[::1]:8080",
            "https://node.example/algod",
            "HTTPS://Node.Example",
        ] {
            #expect(SourceURL.parse(text)?.absoluteString == text)
        }
    }

    @Test("surrounding whitespace is ignored")
    func trimsWhitespace() {
        let parsed = SourceURL.parse("  https://node.example \n")
        #expect(parsed?.absoluteString == "https://node.example")
    }

    /// The likeliest entry from someone following the advice to use their own
    /// node: `URL(string:)` reads "localhost" there as the scheme, with no host.
    @Test("a URL without a host is refused")
    func refusesHostless() {
        for text in [
            "localhost:8080", "node.example:4001", "https://", "http://", "127.0.0.1:8080",
            "mainnet-api.algonode.cloud",
        ] {
            #expect(SourceURL.parse(text) == nil, "\(text)")
        }
    }

    @Test("a scheme other than http or https is refused")
    func refusesOtherSchemes() {
        for text in ["ftp://node.example", "file:///tmp/algod", "ws://node.example"] {
            #expect(SourceURL.parse(text) == nil, "\(text)")
        }
    }

    @Test("text that is not a URL is refused")
    func refusesNonURLs() {
        for text in ["", "   ", "not a url", "https://node .example"] {
            #expect(SourceURL.parse(text) == nil, "\(text)")
        }
    }
}
