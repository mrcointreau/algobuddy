import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Chain poller")
struct ChainPollerTests {
    static let addressString = "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ"
    let address = try! AlgorandAddress(addressString)

    /// Shares its leading byte with the address, so the challenge bit-match fires.
    var matchingSeed: Data { Data([address.publicKey[0]] + [UInt8](repeating: 0, count: 31)) }
    var nonMatchingSeed: Data {
        Data([address.publicKey[0] ^ 0x80] + [UInt8](repeating: 0, count: 31))
    }

    func makePoller(
        stub: StubFetcher,
        clock: TestClock,
        withIndexer: Bool = false,
        notificationsWanted: Bool = true
    ) -> ChainPoller {
        var config = ChainPollerConfig(address: address)
        config.accountInterval = 30
        config.supplyInterval = 300
        config.rewardsInterval = 300
        return ChainPoller(
            config: config,
            algod: AlgodClient(
                baseURL: URL(string: "https://chain.example")!, token: nil, fetcher: stub),
            indexer: withIndexer
                ? IndexerClient(baseURL: URL(string: "https://idx.example")!, fetcher: stub)
                : nil,
            dates: clock,
            notificationsWanted: notificationsWanted)
    }

    func standardRoutes(
        _ stub: StubFetcher, round: UInt64 = 64_030_100, seed: Data, lastSeen: UInt64 = 64_030_050
    ) {
        stub.route(
            "/v2/accounts/",
            json: JSONBuilder.account(
                address: Self.addressString, round: round,
                lastProposed: lastSeen, lastHeartbeat: lastSeen - 1_000,
                voteFirstValid: 63_308_451, voteLastValid: 66_085_593))
        stub.route("/v2/ledger/supply", json: JSONBuilder.supply(round: round))
        stub.route("/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_030_000, seed: seed))
    }

    // MARK: - Happy path

    @Test("a full cycle derives every participation signal")
    func fullCycle() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        let update = await poller.pollOnce()

        #expect(update.failure == nil)
        #expect(update.currentRound == 64_030_100)
        #expect(update.account?.status == .online)
        #expect(update.absence != nil)
        #expect(update.challenge != nil)
        #expect(update.keyExpiry?.lastValid == 66_085_593)
        // Absence uses the live online stake as its denominator.
        #expect(update.absence?.allowableLag == 252_022)
    }

    @Test("a healthy account raises no alerts")
    func quiet() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        #expect(update.alerts.isEmpty)
        #expect(update.notifications.isEmpty)
    }

    /// Round 64,030,160 leaves 40 of the 200 grace rounds, inside the band where
    /// the node has missed its usual answering window.
    @Test("a challenge near its deadline surfaces as a critical alert")
    func challengeFires() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        // Last seen before the challenge round of 64,030,000.
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.challenge?.isFailing == true)
        let alert = update.alerts.first { $0.id == .challengeFailing }
        #expect(alert?.severity == .critical)
        #expect(update.notifications.contains { $0.id == .challengeFailing })
    }

    // MARK: - Request economy

    /// Supply moves slowly and the seed only changes when the window rolls;
    /// re-fetching either every 30 s would triple the load on a public endpoint
    /// for no new information.
    @Test("supply and challenge seed are cached between polls")
    func caching() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        for _ in 0..<4 {
            _ = await poller.pollOnce()
            clock.advance(30)
        }

        #expect(stub.requestCount(containing: "/v2/accounts/") == 4)
        #expect(stub.requestCount(containing: "/v2/ledger/supply") == 1)
        #expect(stub.requestCount(containing: "/v2/blocks/") == 1)
    }

    @Test("supply is refreshed once its interval lapses")
    func supplyRefresh() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        _ = await poller.pollOnce()
        clock.advance(301)
        _ = await poller.pollOnce()

        #expect(stub.requestCount(containing: "/v2/ledger/supply") == 2)
    }

    @Test("the seed is refetched when the challenge window rolls")
    func seedRolls() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_100, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)
        _ = await poller.pollOnce()

        // Cross into the next 1000-round window.
        standardRoutes(stub, round: 64_031_050, seed: nonMatchingSeed)
        clock.advance(30)
        _ = await poller.pollOnce()

        #expect(stub.requestCount(containing: "/v2/blocks/") == 2)
    }

    // MARK: - Failure handling

    /// Every derived signal is a function of the current round, so re-running
    /// the rules against an hours-old account record yields confident, wrong
    /// countdowns. A failed cycle must evaluate none of them.
    @Test("a failed poll evaluates no participation alerts")
    func failureSuppressesAlerts() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        let poller = makePoller(stub: stub, clock: clock)

        let good = await poller.pollOnce()
        #expect(good.alerts.contains { $0.id == .challengeFailing })

        stub.setFailing(true)
        clock.advance(30)
        let bad = await poller.pollOnce()

        #expect(bad.failure?.stage == .account)
        #expect(bad.account == nil)
        #expect(bad.challenge == nil)
        #expect(!bad.alerts.contains { $0.id == .challengeFailing })
    }

    /// A failure count alone is not enough. With the default backoff the third
    /// failure lands ~15 s in, so counting failures would notify on any wifi
    /// transition. Sustained failure is the actual signal.
    @Test("brief outages stay quiet even after several failures")
    func briefOutageIsQuiet() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.setFailing(true)
        let poller = makePoller(stub: stub, clock: clock)

        for _ in 0..<5 {
            #expect(await poller.pollOnce().alerts.isEmpty)
            clock.advance(10)  // 50 s of failure, well past 3 attempts
        }
    }

    @Test("a sustained outage does alert, and names the duration")
    func sustainedOutageAlerts() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.setFailing(true)
        let poller = makePoller(stub: stub, clock: clock)

        // Both gates must be satisfied: three attempts *and* 120 s elapsed.
        _ = await poller.pollOnce()
        clock.advance(65)
        _ = await poller.pollOnce()
        clock.advance(65)
        let update = await poller.pollOnce()

        let alert = update.alerts.first { $0.id == .chainSourceUnreachable }
        #expect(alert?.severity == .warning)
        #expect(alert?.body.contains("minutes") == true)
    }

    @Test("recovery resets the outage clock")
    func recoveryResets() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        stub.setFailing(true)
        _ = await poller.pollOnce()
        clock.advance(65)
        _ = await poller.pollOnce()
        clock.advance(65)
        #expect(await poller.pollOnce().alerts.contains { $0.id == .chainSourceUnreachable })

        stub.setFailing(false)
        clock.advance(30)
        _ = await poller.pollOnce()

        // A fresh outage must serve the full threshold again, not inherit the old one.
        stub.setFailing(true)
        _ = await poller.pollOnce()
        clock.advance(15)
        _ = await poller.pollOnce()
        clock.advance(15)
        #expect(await poller.pollOnce().alerts.isEmpty)
    }

    /// Restarting the app must not re-announce something already reported.
    @Test("a restored dispatcher suppresses a repeat notification")
    func historySurvivesRestart() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.setFailing(true)

        var config = ChainPollerConfig(address: address)
        config.accountInterval = 30
        func build(history: [AlertID: Date]) -> ChainPoller {
            ChainPoller(
                config: config,
                algod: AlgodClient(baseURL: URL(string: "https://chain.example")!, fetcher: stub),
                dispatcher: AlertDispatcher(lastNotified: history),
                dates: clock)
        }

        let first = build(history: [:])
        _ = await first.pollOnce()
        clock.advance(65)
        _ = await first.pollOnce()
        clock.advance(65)
        let notified = await first.pollOnce()
        #expect(notified.notifications.contains { $0.id == .chainSourceUnreachable })
        let history = notified.alertHistory
        #expect(history[.chainSourceUnreachable] != nil)

        // Relaunch: same outage, cooldown carried across.
        clock.advance(60)
        let second = build(history: history)
        _ = await second.pollOnce()
        clock.advance(65)
        _ = await second.pollOnce()
        clock.advance(65)
        let afterRestart = await second.pollOnce()

        #expect(afterRestart.alerts.contains { $0.id == .chainSourceUnreachable })
        #expect(afterRestart.notifications.isEmpty)  // still alerting, but silent
    }

    @Test("backoff grows with failures and resets on success")
    func backoff() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        _ = await poller.pollOnce()
        #expect(await poller.nextDelay == 30)

        stub.setFailing(true)
        _ = await poller.pollOnce()
        #expect(await poller.nextDelay == 5)
        _ = await poller.pollOnce()
        #expect(await poller.nextDelay == 10)
        _ = await poller.pollOnce()
        #expect(await poller.nextDelay == 20)

        stub.setFailing(false)
        _ = await poller.pollOnce()
        #expect(await poller.nextDelay == 30)
    }

    /// Supply is a slow-moving denominator, so a stale one still beats
    /// abandoning the absence assessment entirely.
    @Test("a supply failure degrades rather than failing the cycle")
    func partialFailure() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route(
            "/v2/accounts/",
            json: JSONBuilder.account(
                address: Self.addressString, round: 64_030_100, lastProposed: 64_030_050))
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_030_000, seed: nonMatchingSeed))
        stub.route("/v2/ledger/supply", status: 500, json: "{}")

        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.account != nil)  // the cycle still succeeded
        #expect(update.failure?.stage == .supply)
        #expect(update.absence == nil)  // no denominator yet, so no guess
        #expect(update.challenge != nil)
    }

    @Test("a mistyped address reports not-found rather than a generic error")
    func notFound() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route("/v2/accounts/", status: 404, json: "{}")
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        // The panel shows this string verbatim, so a 404 has to point at the
        // address rather than report a bare status code the reader cannot act on.
        #expect(update.failure?.message.contains("address") == true)
    }

    /// A seed is only meaningful for the window it was fetched for. Evaluating a
    /// stale one manufactures a critical "challenged and not answered" for a
    /// window that closed long ago.
    @Test("a stale seed is not evaluated against a new challenge window")
    func staleSeedIsIgnored() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        // Window 64,034,000, inside the 2x-grace enforcement bound. Address
        // matches the seed, and lastSeen predates it.
        standardRoutes(stub, round: 64_034_300, seed: matchingSeed, lastSeen: 64_033_000)
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_034_000, seed: matchingSeed))
        let poller = makePoller(stub: stub, clock: clock)

        let first = await poller.pollOnce()
        #expect(first.challenge?.isFailing == true)  // genuinely failing, this window

        // Cross into window 64,035,000, but the header fetch fails.
        standardRoutes(stub, round: 64_035_400, seed: matchingSeed, lastSeen: 64_033_000)
        stub.route("/v2/blocks/", status: 500, json: "{}")
        clock.advance(30)
        let second = await poller.pollOnce()

        #expect(second.failure?.stage == .challengeSeed)
        // No challenge state at all, rather than one derived from the old window.
        #expect(second.challenge == nil)
        #expect(!second.alerts.contains { $0.id == .challengeFailing })
    }

    /// `stop()` finishes the stream permanently, so a later `start()` must not
    /// quietly poll forever while publishing nothing.
    @Test("start after stop is an explicit no-op")
    func startAfterStopDoesNothing() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        await poller.stop()
        await poller.start()
        // Give any errantly-installed poll loop a chance to fire.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(stub.requestCount(containing: "/v2/accounts/") == 0)
    }

    /// A manual refresh must publish. `pollOnce()` returns its Update to the
    /// caller and publishes nothing, so refreshing through it would spend
    /// requests, advance the round clock and record dispatcher cooldowns while
    /// the UI saw none of it.
    @Test("refresh publishes its result to the stream")
    func refreshPublishes() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        let received = Task { () -> ChainPoller.Update? in
            for await update in poller.updates { return update }
            return nil
        }
        await poller.refresh()

        let update = try #require(await received.value)
        #expect(update.currentRound == 64_030_100)
    }

    @Test("refresh after stop publishes nothing")
    func refreshAfterStop() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        await poller.stop()
        await poller.refresh()

        #expect(stub.requestCount(containing: "/v2/accounts/") == 0)
    }

    /// A 200 whose header lacks a seed must not stamp the window as fetched:
    /// that would silently disable challenge monitoring for the next ~1000
    /// rounds. The failure is surfaced and the fetch retried next poll.
    @Test("a header without a seed surfaces a failure and retries next poll")
    func missingSeedRetries() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_030_000, seed: nil))
        let poller = makePoller(stub: stub, clock: clock)

        let first = await poller.pollOnce()
        #expect(first.failure?.stage == .challengeSeed)
        #expect(first.challenge == nil)

        clock.advance(30)
        _ = await poller.pollOnce()
        #expect(stub.requestCount(containing: "/v2/blocks/") == 2)
    }

    /// Before the indexer has answered once there is no rewards data, and zero
    /// blocks presented as data would misreport an account that proposed
    /// yesterday.
    @Test("rewards stay nil until the indexer answers once")
    func rewardsNilUntilFirstIndexerSuccess() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", status: 503, json: "{}")
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        let failing = await poller.pollOnce()
        #expect(failing.rewards == nil)
        #expect(failing.failure?.stage == .rewards)

        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_030_000, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        clock.advance(30)
        let recovered = await poller.pollOnce()
        #expect(recovered.rewards != nil)
        #expect(recovered.rewards?.proposals24h == 1)
    }

    /// Blocks are immutable, so the second rewards fetch resumes past what is
    /// already cached instead of re-downloading the whole 8-day window every
    /// cycle.
    @Test("rewards refetch resumes past the cached blocks")
    func rewardsRefetchIsIncremental() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_029_000, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        _ = await poller.pollOnce()
        clock.advance(301)
        _ = await poller.pollOnce()

        let calls = stub.requests.filter { $0.contains("/v2/block-headers") }
        #expect(calls.count == 2)
        #expect(calls[1].contains("min-round=64029001"))
    }

    /// With notifications off the dispatcher is not consulted at all: a
    /// cooldown stamped for a notification nobody saw would swallow the first
    /// real one after they are turned back on.
    @Test("notifications off consumes no cooldowns")
    func notificationsOffConsumesNoCooldown() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        let poller = makePoller(stub: stub, clock: clock, notificationsWanted: false)

        let muted = await poller.pollOnce()
        #expect(muted.alerts.contains { $0.id == .challengeFailing })
        #expect(muted.notifications.isEmpty)
        #expect(muted.alertHistory.isEmpty)

        poller.setNotificationsWanted(true)
        clock.advance(30)
        let audible = await poller.pollOnce()
        #expect(audible.notifications.contains { $0.id == .challengeFailing })
    }

    // MARK: - Rewards

    @Test("rewards are summarised from the indexer")
    func rewards() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [
                    (round: 64_030_000, timestamp: nowSeconds - 3_600, payout: 8_375_131),
                    (round: 64_020_000, timestamp: nowSeconds - 90_000, payout: 8_365_131),
                    (round: 64_010_000, timestamp: nowSeconds - 180_000, payout: nil),
                ], proposer: Self.addressString))

        let update = await makePoller(stub: stub, clock: clock, withIndexer: true).pollOnce()
        let rewards = try #require(update.rewards)

        #expect(rewards.proposals24h == 1)
        #expect(rewards.proposals7d == 3)
        #expect(rewards.earned24h == MicroAlgos(8_375_131))
        #expect(rewards.unpaidProposals == 1)
    }

    /// Results come back oldest-first, so without a lower bound page one is
    /// ancient history and recent proposals are unreachable.
    @Test("the indexer query is bounded by min-round")
    func minRoundApplied() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")

        _ = await makePoller(stub: stub, clock: clock, withIndexer: true).pollOnce()

        let request = try #require(stub.requests.first { $0.contains("/v2/block-headers") })
        #expect(request.contains("min-round="))
        #expect(request.contains("proposers=\(Self.addressString)"))
    }

    /// Exhausting the page budget must be reported. Results arrive oldest-first,
    /// so a truncated fetch drops the newest proposals and the totals a busy
    /// proposer sees would silently under-report.
    @Test("exhausting the page budget is reported, not hidden")
    func truncationIsSurfaced() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        // Every page hands back another token, so the budget is always exhausted.
        stub.route(
            "/v2/block-headers",
            json: """
                {"blocks":[{"round":64029000,"timestamp":\(nowSeconds - 3600),\
                "proposer":"\(Self.addressString)","proposer-payout":8000000}],"next-token":"more"}
                """)

        let update = await makePoller(stub: stub, clock: clock, withIndexer: true).pollOnce()

        #expect(update.rewards?.isTruncated == true)
        #expect(stub.requestCount(containing: "/v2/block-headers") == 10)  // the page budget
    }

    @Test("a complete fetch is not marked truncated")
    func completeFetchIsNotTruncated() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")
        let update = await makePoller(stub: stub, clock: clock, withIndexer: true).pollOnce()
        #expect(update.rewards?.isTruncated == false)
    }

    @Test("rewards are omitted entirely when no indexer is configured")
    func noIndexer() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        #expect(update.rewards == nil)
        #expect(stub.requestCount(containing: "block-headers") == 0)
    }

    // MARK: - Round timing

    @Test("round time starts nominal and becomes measured")
    func roundTime() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let poller = makePoller(stub: stub, clock: clock)

        var round: UInt64 = 64_030_100
        var last: ChainPoller.Update?
        for _ in 0..<5 {
            standardRoutes(stub, round: round, seed: nonMatchingSeed, lastSeen: round - 50)
            last = await poller.pollOnce()
            clock.advance(30)
            round += 10  // 30 s of wall clock, 10 rounds → 3.0 s per round
        }

        let update = try #require(last)
        #expect(abs(update.roundTime - 3.0) < 0.2)
    }

    // MARK: - Streaming

    @Test("start publishes updates to the stream")
    func streaming() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        await poller.start()
        var received: ChainPoller.Update?
        for await update in poller.updates {
            received = update
            break
        }
        await poller.stop()

        #expect(received?.currentRound == 64_030_100)
    }

    // MARK: - Real captured data

    @Test("runs end to end against captured mainnet responses")
    func realFixtures() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route("/v2/accounts/", body: try Fixture.data("mainnet-account.json"))
        stub.route("/v2/ledger/supply", body: try Fixture.data("mainnet-supply.json"))
        stub.route("/v2/blocks/", body: try Fixture.data("mainnet-block-64030256.json"))

        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.failure == nil)
        #expect(update.account?.status == .online)
        #expect(update.account?.incentiveEligible == true)
        #expect(update.absence?.isAbsent == false)
        #expect(update.keyExpiry?.hasExpired == false)
        // The captured round sits 781 past its challenge round, beyond the
        // 2x-grace enforcement bound, so protocol-correct evaluation is nil.
        #expect(update.challenge == nil)
        // A healthy, eligible, well-funded account should be quiet.
        #expect(update.alerts.isEmpty)
    }
}
