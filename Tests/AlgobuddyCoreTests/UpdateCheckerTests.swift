import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    static let endpoint = URL(
        string: "https://api.github.com/repos/mrcointreau/algobuddy/releases/latest")!
    static let releaseURL = URL(
        string: "https://github.com/mrcointreau/algobuddy/releases/tag/v1.0.2")!

    /// The two fields the checker reads, in the shape GitHub returns them.
    static func release(tag: String, url: String = releaseURL.absoluteString) -> String {
        """
        {"tag_name":"\(tag)","html_url":"\(url)","name":"\(tag)","draft":false}
        """
    }

    static func checker(_ fetcher: StubFetcher) -> UpdateChecker {
        UpdateChecker(endpoint: endpoint, fetcher: fetcher)
    }

    // MARK: - ReleaseVersion

    @Test("parses a release triplet with or without the tag prefix")
    func parsesTriplet() {
        #expect(ReleaseVersion("1.0.1") == ReleaseVersion("v1.0.1"))
        #expect(ReleaseVersion("10.20.30")?.minor == 20)
    }

    @Test("keeps only the leading triplet of a development version")
    func parsesDevelopmentVersion() {
        #expect(ReleaseVersion("1.0.1-3-gabc1234") == ReleaseVersion("1.0.1"))
        #expect(ReleaseVersion("1.0.1-dirty") == ReleaseVersion("1.0.1"))
        #expect(ReleaseVersion("1.0.1-3-gabc1234-dirty") == ReleaseVersion("1.0.1"))
    }

    @Test("rejects anything that is not a triplet")
    func rejectsNonTriplets() {
        #expect(ReleaseVersion("abc1234") == nil)
        #expect(ReleaseVersion("abc1234-dirty") == nil)
        #expect(ReleaseVersion("1.0") == nil)
        #expect(ReleaseVersion("1.0.1.2") == nil)
        #expect(ReleaseVersion("1.0.x") == nil)
        #expect(ReleaseVersion("") == nil)
        #expect(ReleaseVersion("v") == nil)
        #expect(ReleaseVersion("-dirty") == nil)
        // Underscores and signs parse as integers but are not versions.
        #expect(ReleaseVersion("1.0.1_0") == nil)
        #expect(ReleaseVersion("1.0.+1") == nil)
    }

    @Test("orders numerically rather than lexicographically")
    func ordersNumerically() {
        #expect(ReleaseVersion("1.9.0")! < ReleaseVersion("1.10.0")!)
        #expect(ReleaseVersion("1.0.9")! < ReleaseVersion("1.0.10")!)
        #expect(ReleaseVersion("2.0.0")! > ReleaseVersion("1.99.99")!)
    }

    // MARK: - The request

    @Test("asks GitHub for the latest release, once per check")
    func requestsLatestRelease() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.1"))

        _ = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(fetcher.requests == [Self.endpoint.absoluteString])
    }

    // MARK: - Release builds

    @Test("an older release build is offered the newer version and its link")
    func olderReleaseBuild() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .updateAvailable(version: "1.0.2", url: Self.releaseURL))
    }

    @Test("the current release build is up to date")
    func currentReleaseBuild() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.2")

        #expect(status == .upToDate(latest: "1.0.2"))
    }

    /// Someone building an unreleased `main` is ahead, not behind.
    @Test("a build newer than the latest release is up to date")
    func newerThanRelease() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "1.1.0")

        #expect(status == .upToDate(latest: "1.0.2"))
    }

    // MARK: - Development builds

    @Test("a development build on top of the latest release is up to date")
    func developmentBuildOnLatest() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        for version in ["1.0.2-3-gabc1234", "1.0.2-dirty", "1.0.2-3-gabc1234-dirty"] {
            let status = await Self.checker(fetcher).check(runningVersion: version)
            #expect(status == .upToDate(latest: "1.0.2"))
        }
    }

    @Test("a development build behind the latest release is offered the update")
    func developmentBuildBehind() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1-7-gdeadbee")

        #expect(status == .updateAvailable(version: "1.0.2", url: Self.releaseURL))
    }

    // MARK: - Nothing to compare against

    @Test("a bare commit hash cannot be compared, and never claims up to date")
    func bareCommitHash() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "abc1234")

        #expect(status == .cannotCompare(latest: "1.0.2", url: Self.releaseURL))
    }

    @Test("no bundle version cannot be compared, and still offers the link")
    func noRunningVersion() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: nil)

        #expect(status == .cannotCompare(latest: "1.0.2", url: Self.releaseURL))
    }

    // MARK: - Failures

    @Test("a malformed tag is a failed check, not a comparison")
    func malformedTag() async {
        for tag in ["latest", "v1.0", "release-2026-08"] {
            let fetcher = StubFetcher()
            fetcher.route("releases/latest", json: Self.release(tag: tag))

            let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

            #expect(status == .failed(message: "Could not read the latest release."))
        }
    }

    @Test("a response missing a field is a failed check")
    func missingField() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: #"{"tag_name":"v1.0.2"}"#)

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "Could not read the latest release."))
    }

    @Test("an undecodable body is a failed check")
    func undecodableBody() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", body: Data("<html>not json</html>".utf8))

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "Could not read the latest release."))
    }

    @Test("a non-200 response names the status")
    func serverError() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", status: 500, json: Self.release(tag: "v1.0.2"))

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "GitHub returned 500."))
    }

    @Test("rate limiting says so rather than reporting a bare status")
    func rateLimited() async {
        for code in [403, 429] {
            let fetcher = StubFetcher()
            fetcher.route("releases/latest", status: code, json: #"{"message":"rate limit"}"#)

            let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

            #expect(
                status == .failed(message: "GitHub is rate limiting this network. Try again later.")
            )
        }
    }

    @Test("a repository with no release yet says so")
    func noReleaseYet() async {
        let fetcher = StubFetcher()
        // Nothing routed, so the stub answers 404, exactly as GitHub does for a
        // repository that has never published a release.
        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "No release has been published yet."))
    }

    @Test("an unreachable host is a quiet failure, not a crash")
    func unreachable() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))
        fetcher.setFailing(true)

        let status = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "Could not reach github.com."))
    }

    @Test("an endpoint that does not parse fails without reaching the network")
    func unparseableEndpoint() async {
        let fetcher = StubFetcher()

        let status = await UpdateChecker(endpoint: nil, fetcher: fetcher)
            .check(runningVersion: "1.0.1")

        #expect(status == .failed(message: "The release address is not valid."))
        #expect(fetcher.requests.isEmpty)
    }

    @Test("a check never downloads anything beyond the release metadata")
    func fetchesNothingElse() async {
        let fetcher = StubFetcher()
        fetcher.route("releases/latest", json: Self.release(tag: "v1.0.2"))

        _ = await Self.checker(fetcher).check(runningVersion: "1.0.1")

        #expect(fetcher.requests.count == 1)
        #expect(fetcher.requestCount(containing: "api.github.com") == 1)
    }
}
