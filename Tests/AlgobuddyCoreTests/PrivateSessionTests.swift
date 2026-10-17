import Foundation
import Testing

@testable import AlgobuddyCore

/// The session every client uses is the one place where the app's trust
/// claims meet the network: what it keeps on disk, how long a request may
/// take, and which hosts a request may reach.
@Suite("Private session")
struct PrivateSessionTests {
    let asked = URL(string: "https://mainnet-api.algonode.cloud/v2/accounts/X")!

    @Test("keeps no cache and no cookies, and bounds every request")
    func configuration() {
        let configuration = URLSessionFetcher.privateSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForResource == 60)
        // Its one header of its own, so no request it sends carries a
        // credential.
        #expect(
            configuration.httpAdditionalHeaders as? [String: String] == ["User-Agent": "algobuddy"])
        #expect(URLSessionFetcher.privateSession.delegate is RedirectGuard)
    }

    /// Every client builds its fetcher with the default, so this is what makes
    /// them all use the private session.
    @Test("a fetcher uses the private session unless given another")
    func defaultSession() {
        #expect(URLSessionFetcher().session === URLSessionFetcher.privateSession)
    }

    /// A stand-in protocol answers with a redirect, so nothing is sent.
    @Test("the fetcher turns a refused redirect into its own error")
    func fetcherReportsRefusedRedirect() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let fetcher = URLSessionFetcher(session: URLSession(configuration: configuration))
        await #expect(throws: AlgodError.redirectRefused) {
            _ = try await fetcher.get(asked, headers: [:], timeout: 5)
        }
    }

    @Test("follows a redirect only within the host it asked")
    func redirectPolicy() {
        func allows(_ from: String, _ to: String) -> Bool {
            RedirectPolicy.allows(from: URL(string: from)!, to: URL(string: to)!)
        }
        #expect(allows(asked.absoluteString, "https://mainnet-api.algonode.cloud/v2/y"))
        #expect(allows(asked.absoluteString, "https://MAINNET-API.algonode.cloud/v2/y"))
        #expect(allows("http://node.local:8080/v2/x", "https://node.local/v2/x"))
        #expect(!allows(asked.absoluteString, "https://elsewhere.example/v2/y"))
        #expect(!allows(asked.absoluteString, "http://mainnet-api.algonode.cloud/v2/y"))
    }

    /// The task is created but never resumed, so nothing is sent.
    @Test("the session's delegate applies the policy")
    func redirectGuard() async {
        let session = URLSessionFetcher.privateSession
        let task = session.dataTask(with: asked)
        defer { task.cancel() }
        let response = HTTPURLResponse(
            url: asked, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let same = URLRequest(url: URL(string: "https://mainnet-api.algonode.cloud/v2/y")!)
        let other = URLRequest(url: URL(string: "https://elsewhere.example/v2/y")!)
        let redirectGuard = RedirectGuard()

        let followed = await redirectGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: same)
        let refused = await redirectGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: other)
        #expect(followed == same)
        #expect(refused == nil)
    }

    @Test("a refused redirect is told apart from any other status")
    func refusedRedirect() {
        func response(_ status: Int, location: String? = nil) -> HTTPURLResponse {
            HTTPURLResponse(
                url: asked, statusCode: status, httpVersion: nil,
                headerFields: location.map { ["Location": $0] })!
        }
        #expect(
            URLSessionFetcher.isRefusedRedirect(
                response(302, location: "https://elsewhere.example/")))
        #expect(!URLSessionFetcher.isRefusedRedirect(response(304)))
        #expect(!URLSessionFetcher.isRefusedRedirect(response(404)))
        #expect(!URLSessionFetcher.isRefusedRedirect(response(200, location: "https://x/")))
    }
}

/// Answers every request with a redirect to another host, without touching the
/// network. A protocol that does not report the redirect to the session hands
/// it over as the final response, which is how a refused one arrives.
final class RedirectingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://elsewhere.example/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
