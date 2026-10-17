import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Chain poller")
struct ChainPollerTests {
    static let addressString = "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ"
    let address = try! AlgorandAddress(addressString)

    /// Shares its leading byte with the address, so the challenge bit-match
    /// fires.
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
        // The block that opens the round's challenge window, which is the one
        // the seed request asks for.
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: round / 1_000 * 1_000, seed: seed))
    }

    /// Polls, waits for the rewards fetch that poll started, and polls again 30
    /// seconds on. The update `pollOnce()` returns cannot carry the answer to
    /// its own rewards fetch, which arrives after it, so the next cycle's
    /// update is the first to show it.
    func pollAfterRewards(_ poller: ChainPoller, clock: TestClock) async -> ChainPoller.Update {
        _ = await poller.pollOnce()
        await poller.rewardsSettled()
        clock.advance(30)
        return await poller.pollOnce()
    }

    /// What the poller publishes while `body` runs, collected until the poller
    /// stops, so an update that never comes fails the test instead of hanging
    /// it.
    func published(
        by poller: ChainPoller, during body: () async -> Void
    ) async -> [ChainPoller.Update] {
        let collector = Task {
            var collected = [ChainPoller.Update]()
            for await update in poller.updates { collected.append(update) }
            return collected
        }
        await body()
        await poller.stop()
        return await collector.value
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
        #expect(update.only?.account?.status == .online)
        #expect(update.only?.absence != nil)
        #expect(update.only?.challenge != nil)
        #expect(update.only?.keyExpiry?.lastValid == 66_085_593)
        // Absence uses the live online stake as its denominator.
        #expect(update.only?.absence?.allowableLag == 252_022)
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

    /// Round 64,030,160 leaves 40 of the 200 grace rounds, inside the band
    /// where the node has missed its usual answering window.
    @Test("a challenge near its deadline surfaces as a critical alert")
    func challengeFires() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        // Last seen before the challenge round of 64,030,000.
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.only?.challenge?.isFailing == true)
        let alert = update.alerts.first { $0.id == .challengeFailing }
        #expect(alert?.severity == .critical)
        #expect(update.notifications.contains { $0.id == .challengeFailing })
    }

    // MARK: - Request economy

    /// Supply moves slowly and the seed only changes when the window rolls;
    /// re-fetching both every 30 s would triple the load on a public endpoint
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
        #expect(stub.requestCount(containing: "/v2/blocks/64030000") == 1)
        // The round clock's anchor, asked for once at the first poll.
        #expect(stub.requestCount(containing: "/v2/blocks/64029200") == 1)
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
        let rolled = await poller.pollOnce()

        #expect(stub.requestCount(containing: "/v2/blocks/64030000") == 1)
        #expect(stub.requestCount(containing: "/v2/blocks/64031000") == 1)
        #expect(rolled.failure == nil)
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
        #expect(bad.only?.account == nil)
        #expect(bad.only?.challenge == nil)
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

        // Five failures in 40 s, well past three attempts but short of the 120
        // s the source alert also waits for.
        for _ in 0..<5 {
            #expect(await poller.pollOnce().alerts.isEmpty)
            clock.advance(10)
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
        // The source is the watch's, not one account's, so this alert holds
        // under no address.
        #expect(alert?.address == nil)
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

        // A fresh outage must serve the full threshold again, not inherit the
        // old one.
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
        func build(history: [AlertKey: Date]) -> ChainPoller {
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
        // The outage is about the watch rather than about one account, so it
        // holds under no address.
        #expect(history[AlertKey(address: nil, id: .chainSourceUnreachable)] != nil)

        // Relaunch: same outage, cooldown carried across.
        clock.advance(60)
        let second = build(history: history)
        _ = await second.pollOnce()
        clock.advance(65)
        _ = await second.pollOnce()
        clock.advance(65)
        let afterRestart = await second.pollOnce()

        #expect(afterRestart.alerts.contains { $0.id == .chainSourceUnreachable })
        #expect(afterRestart.notifications.isEmpty)  // Still alerting, but silent.
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

    /// Only the absence assessment needs the supply, so a failed supply fetch
    /// leaves the account and its challenge state standing, and with no
    /// denominator fetched yet the assessment is left out rather than guessed.
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

        #expect(update.only?.account != nil)  // The cycle still succeeded.
        #expect(update.failure?.stage == .supply)
        #expect(update.only?.absence == nil)  // No denominator yet, so no guess.
        #expect(update.only?.challenge != nil)
    }

    /// A supply fetched once and then failing to refresh keeps feeding the
    /// absence assessment, and with it the absence alerts.
    @Test("a failed supply refresh keeps the cached denominator")
    func failedSupplyRefreshKeepsCache() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)
        let fresh = try #require(await poller.pollOnce().only?.absence)

        stub.route("/v2/ledger/supply", status: 500, json: "{}")
        clock.advance(301)
        let update = await poller.pollOnce()

        // Two supply requests show the refresh was attempted, so the assessment
        // below came from the cache rather than from a skipped fetch.
        #expect(stub.requestCount(containing: "/v2/ledger/supply") == 2)
        #expect(update.failure?.stage == .supply)
        #expect(update.only?.absence == fresh)
    }

    /// algod answers for every well-formed address, one never funded included,
    /// so a 404 for an account means a URL that misses its API. The panel shows
    /// this string verbatim, so it has to point at what can be fixed rather
    /// than at the address or a bare status code the reader cannot act on.
    @Test("an account 404 points at the URL rather than the address")
    func accountNotFoundPointsAtTheURL() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route("/v2/accounts/", status: 404, json: "{}")
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        let message = try #require(update.failure?.message)
        #expect(message.contains("points at algod"))
        #expect(!message.contains("address"))
    }

    /// A backend behind a load balancer can trail the one that answered the
    /// accounts, so the challenge block can be missing for a cycle. Neither the
    /// address nor the URL is at fault, and every page shows this line.
    @Test("a missing challenge block reads as a lagging source")
    func challengeBlockNotFound() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/blocks/", status: 404, json: "{}")
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        #expect(update.failure?.stage == .challengeSeed)
        let message = try #require(update.failure?.message)
        #expect(message.contains("challenge block"))
        #expect(!message.contains("address"))
    }

    @Test("a rewards failure names the indexer")
    func rewardsFailureNamesTheIndexer() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"unexpected\":true}")
        let update = await pollAfterRewards(
            makePoller(stub: stub, clock: clock, withIndexer: true), clock: clock)
        let failure = try #require(update.only?.failure)
        #expect(failure.stage == .rewards)
        #expect(failure.message.hasPrefix("The indexer"))
        #expect(!failure.message.contains("algod"))
    }

    /// The private session refuses a redirect to another host. The panel must
    /// say so, rather than report an outage or blame the address.
    @Test("a refused redirect is reported as such")
    func refusedRedirectIsReported() async throws {
        struct Redirecting: HTTPFetching {
            func get(
                _ url: URL, headers: [String: String], timeout: TimeInterval
            ) async throws -> (Data, Int) {
                throw AlgodError.redirectRefused
            }
        }
        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(
                baseURL: URL(string: "https://chain.example")!, fetcher: Redirecting()),
            dates: TestClock())

        let update = await poller.pollOnce()

        #expect(update.failure?.message.contains("only contacts the configured hosts") == true)
    }

    /// The panel shows these strings verbatim, so each names its source and,
    /// where the failure has a known meaning, says it rather than a status.
    @Test("an algod failure reads as what it means")
    func algodFailureMessages() async throws {
        struct NotHTTP: HTTPFetching {
            func get(
                _ url: URL, headers: [String: String], timeout: TimeInterval
            ) async throws -> (Data, Int) {
                throw AlgodError.notHTTP
            }
        }
        func message(_ fetcher: any HTTPFetching) async -> String? {
            let poller = ChainPoller(
                config: ChainPollerConfig(address: address),
                algod: AlgodClient(
                    baseURL: URL(string: "https://chain.example")!, fetcher: fetcher),
                dates: TestClock())
            let update = await poller.pollOnce()
            return update.failure?.message
        }
        func answering(_ status: Int, body: String = "{}") -> StubFetcher {
            let stub = StubFetcher()
            stub.route("/v2/accounts/", status: status, json: body)
            return stub
        }
        let offline = StubFetcher()
        offline.setFailing(true)

        let tokenRequired =
            "The chain data source requires a token. Public providers serve it without one."
        let unexpected =
            "The chain data source returned an unexpected response. Check the URL points at algod."
        let serverError = "The chain data source returned an error (503)."
        let notHTTP = "The chain data source did not return an HTTP response."
        #expect(await message(answering(401)) == tokenRequired)
        #expect(await message(answering(200, body: "<html></html>")) == unexpected)
        #expect(await message(answering(503)) == serverError)
        #expect(await message(NotHTTP()) == notHTTP)
        #expect(await message(offline) == "The chain data source could not be reached.")
    }

    /// The indexer's statuses map as algod's do, so its 401 and 404 say what
    /// they mean there, and name the indexer.
    @Test("an indexer failure reads as what it means")
    func indexerFailureMessages() async throws {
        func message(status: Int) async -> String? {
            let stub = StubFetcher()
            let clock = TestClock()
            standardRoutes(stub, seed: nonMatchingSeed)
            stub.route("/v2/block-headers", status: status, json: "{}")
            let update = await pollAfterRewards(
                makePoller(stub: stub, clock: clock, withIndexer: true), clock: clock)
            return update.only?.failure?.message
        }
        let tokenRequired = "The indexer requires a token. Public providers serve it without one."
        let noEndpoint = "The indexer has no such endpoint. Check the indexer URL."
        #expect(await message(status: 401) == tokenRequired)
        #expect(await message(status: 404) == noEndpoint)
    }

    /// A seed is only meaningful for the window it was fetched for. Evaluating
    /// a stale one manufactures a critical "challenged and not answered" for a
    /// window that closed long ago.
    @Test("a stale seed is not evaluated against a new challenge window")
    func staleSeedIsIgnored() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        // Window 64,034,000, inside the 2x-grace enforcement bound. The address
        // matches the seed, and `lastSeen` predates the window.
        standardRoutes(stub, round: 64_034_300, seed: matchingSeed, lastSeen: 64_033_000)
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_034_000, seed: matchingSeed))
        let poller = makePoller(stub: stub, clock: clock)

        let first = await poller.pollOnce()
        #expect(first.only?.challenge?.isFailing == true)  // Genuinely failing, in this window.

        // Cross into window 64,035,000, but the header fetch fails.
        standardRoutes(stub, round: 64_035_400, seed: matchingSeed, lastSeen: 64_033_000)
        stub.route("/v2/blocks/", status: 500, json: "{}")
        clock.advance(30)
        let second = await poller.pollOnce()

        #expect(second.failure?.stage == .challengeSeed)
        // No challenge state at all, rather than one derived from the old
        // window.
        #expect(second.only?.challenge == nil)
        #expect(!second.alerts.contains { $0.id == .challengeFailing })
    }

    // MARK: - Lifecycle

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

    /// A manual refresh must publish. `pollOnce()` returns its `Update` to the
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

    /// The loop and a manual refresh share one in-flight guard. A refresh that
    /// started a second cycle beside a slow one would duplicate every request,
    /// count a failure twice, and could publish an older update after a newer
    /// one.
    @Test("a refresh during an in-flight cycle starts no second poll")
    func refreshDuringCycleIsSkipped() async throws {
        let stub = StubFetcher()
        standardRoutes(stub, seed: nonMatchingSeed)
        let gate = FirstRequestGate(stub)
        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(baseURL: URL(string: "https://chain.example")!, fetcher: gate),
            dates: TestClock())

        await poller.start()
        // The refresh below must land while the loop's first cycle is in
        // flight, so wait until that cycle is held on its account request.
        var held = gate.firstHeld.makeAsyncIterator()
        _ = await held.next()

        await poller.refresh()
        let accountRequests = gate.matchingRequestCount

        gate.open()
        await poller.stop()
        #expect(accountRequests == 1)
    }

    // MARK: - Challenge seed

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
        let noSeed =
            "The chain data source returned a block header without a seed, so challenge monitoring is paused."
        #expect(first.failure?.message == noSeed)
        #expect(first.only?.challenge == nil)

        clock.advance(30)
        _ = await poller.pollOnce()
        #expect(stub.requestCount(containing: "/v2/blocks/64030000") == 2)
    }

    /// Another block's seed would select other accounts than the challenge
    /// does. Here it selects this one, which was last seen before the
    /// challenge round, so taking it would raise a false challenge.
    @Test("a header for another round is not taken as the challenge block")
    func headerForAnotherRoundIsRefused() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_029_000, seed: matchingSeed))
        let poller = makePoller(stub: stub, clock: clock)

        let first = await poller.pollOnce()
        #expect(first.failure?.stage == .challengeSeed)
        let otherBlock =
            "The chain data source returned a block other than the challenge block, so challenge monitoring is paused."
        #expect(first.failure?.message == otherBlock)
        #expect(first.only?.challenge == nil)
        #expect(!first.alerts.contains { $0.id == .challengeFailing })

        clock.advance(30)
        _ = await poller.pollOnce()
        #expect(stub.requestCount(containing: "/v2/blocks/64030000") == 2)
    }

    /// A header that leaves out its round cannot be checked against the round
    /// asked for, so it is taken as that round's, and its seed challenges.
    @Test("a header without its round is taken as the challenge block")
    func headerWithoutRoundIsTaken() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        stub.route("/v2/blocks/", json: JSONBuilder.blockHeader(round: nil, seed: matchingSeed))

        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.failure == nil)
        #expect(update.only?.challenge?.isFailing == true)
    }

    // MARK: - Notifications

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

        let failing = await pollAfterRewards(poller, clock: clock)
        #expect(failing.only?.rewards == nil)
        #expect(failing.failure?.stage == .rewards)
        // That poll also retried the failed query. Settling it here keeps it
        // on the 503, so the next query is the first to succeed.
        await poller.rewardsSettled()

        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_030_000, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        clock.advance(30)
        let recovered = await pollAfterRewards(poller, clock: clock)
        #expect(recovered.only?.rewards != nil)
        #expect(recovered.only?.rewards?.proposals24h == 1)
        #expect(recovered.failure == nil)
    }

    /// Blocks are immutable, so the second rewards fetch resumes past what is
    /// already cached instead of re-downloading the whole 8-day window at every
    /// fetch.
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
        await poller.rewardsSettled()
        clock.advance(301)
        _ = await poller.pollOnce()
        await poller.rewardsSettled()

        let calls = stub.requests.filter { $0.contains("/v2/block-headers") }
        #expect(calls.count == 2)
        #expect(calls[1].contains("min-round=64029001"))
    }

    /// The indexer is user-configured, so its rounds are not trusted. A block
    /// past the chain tip must neither crash the poller when the next fetch
    /// resumes past it nor become the resume point that hides every real
    /// proposal after it.
    @Test("indexer rounds past the chain tip are ignored")
    func futureIndexerRoundsAreIgnored() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [
                    (round: 64_029_000, timestamp: 1_785_996_400, payout: 8_000_000),
                    (round: 65_030_100, timestamp: 1_785_996_400, payout: 8_000_000),
                    (round: .max, timestamp: 1_785_996_400, payout: 8_000_000),
                ], proposer: Self.addressString))
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        _ = await poller.pollOnce()
        await poller.rewardsSettled()
        clock.advance(301)
        let update = await pollAfterRewards(poller, clock: clock)

        let calls = stub.requests.filter { $0.contains("/v2/block-headers") }
        #expect(calls.count == 2)
        #expect(calls[1].contains("min-round=64029001"))
        #expect(update.only?.rewards?.proposals24h == 1)
    }

    /// An indexer can run a round or two ahead of the algod backend that
    /// answered. A block past algod's round is dropped from that fetch and
    /// counted at the next one, which resumes before it, so a real proposal is
    /// never lost.
    @Test("a block from an indexer ahead of algod is counted once algod catches up")
    func earlyIndexerBlockIsCountedLater() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_100, seed: nonMatchingSeed)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_030_101, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        let early = await pollAfterRewards(poller, clock: clock)
        #expect(early.only?.rewards?.proposals24h == 0)

        standardRoutes(stub, round: 64_030_200, seed: nonMatchingSeed)
        clock.advance(301)
        let caughtUp = await pollAfterRewards(poller, clock: clock)
        #expect(caughtUp.only?.rewards?.proposals24h == 1)
    }

    /// Both endpoints are user-configured. Even when algod itself reports the
    /// largest round there is, and the indexer a block at it, the resume step
    /// must saturate rather than trap.
    @Test("the rewards resume step saturates at the largest round")
    func resumeStepSaturates() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: .max, seed: nonMatchingSeed, lastSeen: .max - 50)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: .max, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        _ = await poller.pollOnce()
        await poller.rewardsSettled()
        clock.advance(301)
        _ = await poller.pollOnce()
        await poller.rewardsSettled()

        let calls = stub.requests.filter { $0.contains("/v2/block-headers") }
        #expect(calls.count == 2)
        #expect(calls.last?.contains("min-round=\(UInt64.max)") == true)
    }

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

        let update = await pollAfterRewards(
            makePoller(stub: stub, clock: clock, withIndexer: true), clock: clock)
        let rewards = try #require(update.only?.rewards)

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
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        _ = await poller.pollOnce()
        await poller.rewardsSettled()

        let request = try #require(stub.requests.first { $0.contains("/v2/block-headers") })
        // Eight days back at the nominal round time, which the first poll has.
        let windowStart = 64_030_100 - UInt64(8 * 86_400 / RoundClock.nominal)
        #expect(request.contains("min-round=\(windowStart)"))
        #expect(request.contains("proposers=\(Self.addressString)"))
    }

    /// Exhausting the page budget must be reported. Results arrive
    /// oldest-first, so a truncated fetch drops the newest proposals and the
    /// totals a busy proposer sees would silently under-report.
    @Test("exhausting the page budget is reported, not hidden")
    func truncationIsSurfaced() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        // Every page hands back another token, so the budget is always
        // exhausted.
        stub.route(
            "/v2/block-headers",
            json: """
                {"blocks":[{"round":64029000,"timestamp":\(nowSeconds - 3600),\
                "proposer":"\(Self.addressString)","proposer-payout":8000000}],"next-token":"more"}
                """)

        let update = await pollAfterRewards(
            makePoller(stub: stub, clock: clock, withIndexer: true), clock: clock)

        #expect(update.only?.rewards?.isTruncated == true)
        #expect(stub.requestCount(containing: "/v2/block-headers") == 10)  // The page budget.
    }

    @Test("a complete fetch is not marked truncated")
    func completeFetchIsNotTruncated() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")
        let update = await pollAfterRewards(
            makePoller(stub: stub, clock: clock, withIndexer: true), clock: clock)
        #expect(update.only?.rewards?.isTruncated == false)
    }

    /// The indexer is optional and often the slower host. A rewards query that
    /// hangs must hold back neither the account figures nor their alerts, and
    /// must not be asked again while it is still out.
    @Test("a hanging rewards query holds back no cycle")
    func hangingRewardsQueryHoldsBackNoCycle() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_030_000, timestamp: 1_785_996_400, payout: 8_000_000)],
                proposer: Self.addressString))
        let gate = FirstRequestGate(stub, holding: "/v2/block-headers")
        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(baseURL: URL(string: "https://chain.example")!, fetcher: stub),
            indexer: IndexerClient(baseURL: URL(string: "https://idx.example")!, fetcher: gate),
            dates: clock)
        let rescue = watchdog { gate.open() }
        defer { rescue.cancel() }

        let first = await poller.pollOnce()
        var held = gate.firstHeld.makeAsyncIterator()
        _ = await held.next()
        #expect(first.only?.account != nil)
        #expect(first.only?.rewards == nil)

        clock.advance(301)
        let second = await poller.pollOnce()
        #expect(second.only?.account != nil)

        gate.open()
        await poller.rewardsSettled()
        // The second poll found the query still out and asked nothing more.
        #expect(gate.matchingRequestCount == 1)

        clock.advance(30)
        let answered = await poller.pollOnce()
        #expect(answered.only?.rewards?.proposals24h == 1)
    }

    /// Settings replaces the poller when the hosts change, and the old one may
    /// still have a rewards query out. Stopping it cancels that query, so it
    /// goes no further against a host the user has moved away from.
    @Test("stop cancels a rewards query that is still out")
    func stopCancelsRewardsQuery() async throws {
        let stub = StubFetcher()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")
        let gate = FirstRequestGate(stub, holding: "/v2/block-headers")
        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(baseURL: URL(string: "https://chain.example")!, fetcher: stub),
            indexer: IndexerClient(baseURL: URL(string: "https://idx.example")!, fetcher: gate),
            dates: TestClock())
        let rescue = watchdog { gate.open() }
        defer { rescue.cancel() }

        _ = await poller.pollOnce()
        var held = gate.firstHeld.makeAsyncIterator()
        _ = await held.next()
        await poller.stop()
        gate.open()
        await poller.rewardsSettled()

        #expect(gate.heldRequestWasCancelled)
    }

    /// A cycle still in flight when its poller stops runs on to its end. It
    /// must not leave behind a rewards query that outlives the poller.
    @Test("a cycle that ends after stop starts no rewards query")
    func cycleEndingAfterStopStartsNoRewardsQuery() async throws {
        let stub = StubFetcher()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")
        let gate = FirstRequestGate(stub, holding: "/v2/ledger/supply")
        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(baseURL: URL(string: "https://chain.example")!, fetcher: gate),
            indexer: IndexerClient(baseURL: URL(string: "https://idx.example")!, fetcher: stub),
            dates: TestClock())
        let rescue = watchdog { gate.open() }
        defer { rescue.cancel() }

        let cycle = Task { await poller.pollOnce() }
        var held = gate.firstHeld.makeAsyncIterator()
        _ = await held.next()
        await poller.stop()
        gate.open()
        _ = await cycle.value
        await poller.rewardsSettled()

        #expect(stub.requestCount(containing: "/v2/block-headers") == 0)
    }

    @Test("rewards are omitted entirely when no indexer is configured")
    func noIndexer() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        #expect(update.only?.rewards == nil)
        #expect(stub.requestCount(containing: "block-headers") == 0)
    }

    // MARK: - Rewards answers

    /// The account figures come with the first cycle, and the proposals the
    /// moment their query answers, not with the next cycle up to an interval
    /// later. The cycle's own update is published again for them, so nothing
    /// else in it moves and nothing is fetched again.
    @Test("a rewards answer is shown as soon as it arrives")
    func rewardsAnswerShownAtOnce() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_030_000, timestamp: nowSeconds - 3_600, payout: 8_000_000)],
                proposer: Self.addressString))
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        let updates = await published(by: poller) {
            await poller.refresh()
            await poller.rewardsSettled()
        }

        try #require(updates.count == 2)
        let (cycle, answered) = (updates[0], updates[1])
        #expect(cycle.only?.rewards == nil)
        #expect(answered.only?.rewards?.proposals24h == 1)
        #expect(answered.observedAt == cycle.observedAt)
        #expect(answered.currentRound == cycle.currentRound)
        #expect(answered.roundTime == cycle.roundTime)
        #expect(stub.requestCount(containing: "/v2/accounts/") == 1)
    }

    /// No alert rule reads rewards, so their answer changes no alert, and what
    /// the cycle notified is not notified a second time.
    @Test("a rewards answer notifies nothing and leaves the alerts as they were")
    func rewardsAnswerNotifiesNothing() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, round: 64_030_160, seed: matchingSeed, lastSeen: 64_029_500)
        stub.route("/v2/block-headers", json: "{\"blocks\":[]}")
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        let updates = await published(by: poller) {
            await poller.refresh()
            await poller.rewardsSettled()
        }

        try #require(updates.count == 2)
        let (cycle, answered) = (updates[0], updates[1])
        #expect(cycle.notifications.contains { $0.id == .challengeFailing })
        #expect(answered.notifications.isEmpty)
        #expect(answered.alerts == cycle.alerts)
        #expect(answered.alertHistory == cycle.alertHistory)
        #expect(answered.only?.rewards?.proposals7d == 0)
    }

    @Test("a failed rewards query is shown as soon as it fails")
    func rewardsFailureShownAtOnce() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)
        stub.route("/v2/block-headers", status: 503, json: "{}")
        let poller = makePoller(stub: stub, clock: clock, withIndexer: true)

        let updates = await published(by: poller) {
            await poller.refresh()
            await poller.rewardsSettled()
        }

        try #require(updates.count == 2)
        let (cycle, answered) = (updates[0], updates[1])
        #expect(cycle.failure == nil)
        #expect(answered.only?.rewards == nil)
        #expect(answered.only?.failure?.stage == .rewards)
        #expect(answered.failure?.stage == .rewards)
    }

    /// An account whose fetch fails is shown as it last was, and the rewards
    /// shown since its cycle are part of that.
    @Test("a failed fetch after a rewards answer carries that answer")
    func staleEntryCarriesRewardsAnswer() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        accountRoute(stub, second)
        sharedRoutes(stub)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        stub.route(
            "/v2/block-headers",
            json: JSONBuilder.blockHeaders(
                [(round: 64_029_000, timestamp: nowSeconds - 3_600, payout: 8_000_000)],
                proposer: Self.addressString))
        let poller = makePoller(
            stub: stub, clock: clock, addresses: [address, second], withIndexer: true)

        let updates = await published(by: poller) {
            await poller.refresh()
            await poller.rewardsSettled()
            stub.route("/v2/accounts/\(Self.addressString)", status: 503, json: "{}")
            clock.advance(30)
            await poller.refresh()
        }

        let held = try #require(updates.last?.entry(for: address))
        #expect(held.isStale)
        #expect(held.rewards?.proposals24h == 1)
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
            round += 10  // 10 rounds in 30 s: 3.0 s per round.
        }

        let update = try #require(last)
        #expect(abs(update.roundTime - 3.0) < 0.2)
    }

    /// A block 900 rounds back carries the time it was made, so the first poll
    /// already has the rate over a long span instead of the nominal figure.
    @Test("the first poll times the round clock from an earlier block")
    func anchoredRoundTime() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        // Before the general block route, so it answers for its own round.
        let anchorTime = Int64(clock.now.timeIntervalSince1970 - 900 * 2.76)
        stub.route(
            "/v2/blocks/64029200",
            json: JSONBuilder.blockHeader(round: 64_029_200, seed: nil, timestamp: anchorTime))
        standardRoutes(stub, seed: nonMatchingSeed)
        let poller = makePoller(stub: stub, clock: clock)

        let first = await poller.pollOnce()
        #expect(abs(first.roundTime - 2.76) < 0.01)
        #expect(first.failure == nil)

        clock.advance(30)
        _ = await poller.pollOnce()
        #expect(stub.requestCount(containing: "/v2/blocks/64029200") == 1)
    }

    /// An answer for another round says nothing about the round asked for,
    /// however plausible the rate it would give.
    @Test("a block header for another round does not time the clock")
    func anchorForAnotherRound() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let anchorTime = Int64(clock.now.timeIntervalSince1970 - 900 * 2.76)
        stub.route(
            "/v2/blocks/64029200",
            json: JSONBuilder.blockHeader(round: 64_029_000, seed: nil, timestamp: anchorTime))
        standardRoutes(stub, seed: nonMatchingSeed)
        let update = await makePoller(stub: stub, clock: clock).pollOnce()
        #expect(update.roundTime == RoundClock.nominal)
        #expect(stub.requestCount(containing: "/v2/blocks/64029200") == 1)
    }

    /// Three rounds in eight seconds is no measurement, and taking it as one
    /// would move every countdown by several percent. The next poll measures
    /// from the poll before the refresh instead.
    @Test("a refresh seconds after a poll leaves the round time alone")
    func refreshKeepsRoundTime() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let poller = makePoller(stub: stub, clock: clock)

        standardRoutes(stub, round: 64_030_100, seed: nonMatchingSeed)
        _ = await poller.pollOnce()
        clock.advance(8)
        standardRoutes(stub, round: 64_030_103, seed: nonMatchingSeed)
        let refreshed = await poller.pollOnce()
        #expect(refreshed.roundTime == RoundClock.nominal)

        clock.advance(22)
        standardRoutes(stub, round: 64_030_111, seed: nonMatchingSeed)
        let next = await poller.pollOnce()
        let blended = RoundClock.nominal + 0.2 * (30.0 / 11 - RoundClock.nominal)
        #expect(abs(next.roundTime - blended) < 1e-9)
    }

    /// The round-time estimate moves slightly from poll to poll, so a key
    /// countdown near a threshold can read either side of it. Crossing three
    /// days left must announce critical once, not on every rise.
    @Test("keys crossing three days left notify critical once")
    func keyExpiryCrossingNotifiesOnce() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let poller = makePoller(stub: stub, clock: clock)
        let first: UInt64 = 64_030_100
        // Rounds of exactly 2.8 s, polled every 30 s, with keys that run out
        // 3 days and 4 hours after the first poll.
        let lastValid = first + UInt64((3 * 86_400 + 4 * 3_600) / 2.8)
        stub.route("/v2/ledger/supply", json: JSONBuilder.supply(round: first))

        var notified = [AlertSeverity]()
        var failures = [PollFailure]()
        for poll in 0..<(6 * 120) {
            let round = first + UInt64(Double(poll) * 30 / 2.8)
            stub.route(
                "/v2/accounts/",
                json: JSONBuilder.account(
                    address: Self.addressString, round: round, lastProposed: round - 50,
                    voteFirstValid: first, voteLastValid: lastValid))
            stub.route(
                "/v2/blocks/",
                json: JSONBuilder.blockHeader(round: round / 1_000 * 1_000, seed: nonMatchingSeed))
            let update = await poller.pollOnce()
            notified += update.notifications.filter { $0.id == .keyExpiry }.map(\.severity)
            failures += update.failure.map { [$0] } ?? []
            clock.advance(30)
        }

        #expect(notified == [.warning, .critical])
        #expect(failures.isEmpty)
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

    // MARK: - Several accounts

    /// A further valid address, derived rather than written out, so a second
    /// account costs no more 58-character literals and the checksum still
    /// holds.
    static func filledAddress(_ byte: UInt8) -> AlgorandAddress {
        let key = [UInt8](repeating: byte, count: AlgorandAddress.publicKeyLength)
        return try! AlgorandAddress(
            Base32.encode(key + SHA512_256.hash(key).suffix(AlgorandAddress.checksumLength)))
    }

    func makePoller(
        stub: StubFetcher,
        clock: TestClock,
        addresses: [AlgorandAddress],
        withIndexer: Bool = false
    ) -> ChainPoller {
        var config = ChainPollerConfig(addresses: addresses)
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
            dates: clock)
    }

    /// One account's route, matched on its own address so each watched account
    /// can answer differently.
    func accountRoute(
        _ stub: StubFetcher,
        _ address: AlgorandAddress,
        round: UInt64 = 64_030_100,
        status: String = "Online",
        lastSeen: UInt64 = 64_030_050
    ) {
        stub.route(
            "/v2/accounts/\(address.stringValue)",
            json: JSONBuilder.account(
                address: address.stringValue, round: round, status: status,
                lastProposed: lastSeen, lastHeartbeat: lastSeen - 1_000,
                voteFirstValid: 63_308_451, voteLastValid: 66_085_593))
    }

    /// The supply denominator and the challenge seed, which every watched
    /// account shares.
    func sharedRoutes(_ stub: StubFetcher, round: UInt64 = 64_030_100) {
        stub.route("/v2/ledger/supply", json: JSONBuilder.supply(round: round))
        stub.route(
            "/v2/blocks/",
            json: JSONBuilder.blockHeader(round: round / 1_000 * 1_000, seed: nonMatchingSeed))
    }

    @Test("a cycle produces one entry per watched address")
    func entryPerAddress() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        accountRoute(stub, second)
        sharedRoutes(stub)

        let update = await makePoller(stub: stub, clock: clock, addresses: [address, second])
            .pollOnce()

        #expect(update.entries.map(\.address) == [address, second])
        #expect(update.entries.allSatisfy { $0.account != nil })
        #expect(update.entries.allSatisfy { $0.absence != nil })
        #expect(update.entries.allSatisfy { $0.keyExpiry != nil })
        #expect(update.failure == nil)
        // The denominator and the seed are shared, so a second account costs
        // one more request rather than three.
        #expect(stub.requestCount(containing: "/v2/accounts/") == 2)
        #expect(stub.requestCount(containing: "/v2/ledger/supply") == 1)
        #expect(stub.requestCount(containing: "/v2/blocks/64030000") == 1)
        #expect(stub.requestCount(containing: "/v2/blocks/64029200") == 1)
    }

    /// The Attention card lists the alerts as they come, and notifications go
    /// out in the same order: the most severe first, and equally severe ones
    /// in the order the accounts are watched in.
    @Test("alerts come most severe first, then in watch order")
    func alertsBySeverityThenWatchOrder() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        let third = Self.filledAddress(0x12)
        // Last seen six tenths of the allowable lag ago, so the headroom is low
        // and the limit not yet near.
        accountRoute(stub, address, lastSeen: 64_030_100 - 151_213)
        accountRoute(stub, second, status: "Offline")
        accountRoute(stub, third, status: "Offline")
        sharedRoutes(stub)

        let update = await makePoller(
            stub: stub, clock: clock, addresses: [address, second, third]
        ).pollOnce()

        let expected: [AlgorandAddress?] = [second, third, address]
        #expect(update.alerts.map(\.address) == expected)
        #expect(update.alerts.map(\.id) == [.accountOffline, .accountOffline, .absenceHeadroom])
        #expect(update.notifications.map(\.address) == expected)
    }

    /// Each account is evaluated at its own round, and a lagging backend can
    /// answer for one from the window before the seed's. That account has not
    /// reached the seed's challenge round, so the seed cannot challenge it.
    @Test("an account behind the seed's window is not evaluated against it")
    func accountBehindTheSeedWindow() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let behind = Self.filledAddress(0x31)
        accountRoute(stub, address, round: 64_035_100, lastSeen: 64_035_050)
        accountRoute(stub, behind, round: 64_034_900, lastSeen: 64_034_100)
        sharedRoutes(stub, round: 64_035_100)
        // The seed of window 64,035,000 selects the lagging account.
        let seed = Data([behind.publicKey[0]] + [UInt8](repeating: 0, count: 31))
        stub.route("/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_035_000, seed: seed))

        let update = await makePoller(stub: stub, clock: clock, addresses: [address, behind])
            .pollOnce()

        #expect(update.entry(for: address)?.challenge != nil)
        #expect(update.entry(for: behind)?.account != nil)
        #expect(update.entry(for: behind)?.challenge == nil)
    }

    /// One address that cannot be fetched must not stop the others being
    /// watched, nor slow the whole cycle down to a backoff.
    @Test("one unreachable address degrades only its own entry")
    func oneAddressDegrades() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)  // The second address has no route, so it gets a 404.
        sharedRoutes(stub)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        let update = await poller.pollOnce()

        #expect(update.entry(for: address)?.account != nil)
        #expect(update.entry(for: address)?.failure == nil)
        #expect(update.entry(for: second)?.account == nil)
        #expect(update.entry(for: second)?.failure?.stage == .account)
        // The cycle still carries data, and its round still stands.
        #expect(update.hasData)
        #expect(update.currentRound == 64_030_100)
        #expect(await poller.nextDelay == 30)
    }

    @Test("a cycle fails only when no account could be fetched")
    func everyAddressFails() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        stub.setFailing(true)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        let update = await poller.pollOnce()

        #expect(!update.hasData)
        #expect(update.entries.count == 2)
        #expect(update.entries.allSatisfy { $0.failure?.stage == .account })
        #expect(update.failure?.stage == .account)
        #expect(await poller.nextDelay == 5)  // Now the shared backoff engages.
    }

    /// One dropped request for one account must not make it look healthy. Its
    /// last good figures and alerts stand in, marked stale, until it answers.
    @Test("a failed account keeps its last entry and alerts, marked stale")
    func failedAccountStaysVisible() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        accountRoute(stub, second, status: "Offline")
        sharedRoutes(stub)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])
        let firstFetch = clock.now
        _ = await poller.pollOnce()

        stub.route("/v2/accounts/\(second.stringValue)", status: 503, json: "{}")
        clock.advance(30)
        let update = await poller.pollOnce()

        let held = try #require(update.entry(for: second))
        #expect(held.isStale)
        #expect(held.account?.status == .offline)
        #expect(held.fetchedAt == firstFetch)
        #expect(held.failure?.stage == .account)
        #expect(update.alerts.contains { $0.id == .accountOffline && $0.address == second })
        #expect(update.entry(for: address)?.isStale == false)
        #expect(update.hasData)
        #expect(update.portfolio.accountCount == 2)
    }

    /// A reminder restates a condition as current, so it waits for figures that
    /// are. While an account's fetch fails, its held alerts stay quiet, and the
    /// first fresh evaluation after it answers again carries the reminder.
    @Test("stale alerts send no reminder until the account answers again")
    func staleAlertsDoNotRemind() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        // Keys that expire in under two days: critical, and reminded every six
        // hours while that holds.
        let expiring = JSONBuilder.account(
            address: second.stringValue, round: 64_030_100, lastProposed: 64_030_050,
            voteFirstValid: 63_308_451, voteLastValid: 64_090_000)
        stub.route("/v2/accounts/\(second.stringValue)", json: expiring)
        sharedRoutes(stub)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        func keyNotifications(_ update: ChainPoller.Update) -> Int {
            update.notifications.filter { $0.id == .keyExpiry && $0.address == second }.count
        }
        #expect(keyNotifications(await poller.pollOnce()) == 1)

        stub.route("/v2/accounts/\(second.stringValue)", status: 503, json: "{}")
        for _ in 0..<8 {
            clock.advance(3_600)
            #expect(keyNotifications(await poller.pollOnce()) == 0)
        }

        stub.route("/v2/accounts/\(second.stringValue)", json: expiring)
        clock.advance(30)
        #expect(keyNotifications(await poller.pollOnce()) == 1)
    }

    /// A blip must stay quiet, and an account that keeps failing while the
    /// others answer must not go unwatched under a healthy icon.
    @Test("an account that keeps failing raises its own alert")
    func failingAccountAlerts() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        stub.route("/v2/accounts/\(second.stringValue)", status: 503, json: "{}")
        sharedRoutes(stub)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        func unavailable(_ update: ChainPoller.Update) -> HealthAlert? {
            update.alerts.first { $0.id == .accountDataUnavailable }
        }
        // Three failures inside two minutes stay quiet.
        #expect(unavailable(await poller.pollOnce()) == nil)
        clock.advance(30)
        #expect(unavailable(await poller.pollOnce()) == nil)
        clock.advance(30)
        #expect(unavailable(await poller.pollOnce()) == nil)

        clock.advance(65)
        let raised = await poller.pollOnce()
        let alert = try #require(unavailable(raised))
        #expect(alert.address == second)
        #expect(alert.severity == .warning)
        #expect(raised.notifications.contains { $0.id == .accountDataUnavailable })
        #expect(await poller.nextDelay == 30)

        accountRoute(stub, second)
        clock.advance(30)
        #expect(unavailable(await poller.pollOnce()) == nil)

        // A new failure starts its own count rather than inheriting the old
        // one.
        stub.route("/v2/accounts/\(second.stringValue)", status: 503, json: "{}")
        clock.advance(30)
        #expect(unavailable(await poller.pollOnce()) == nil)
    }

    /// A stale entry stands in for a failed fetch. A cycle made only of those
    /// learned nothing, and its consumers must keep the last real data.
    @Test("a stale entry does not count as fetched data")
    func staleEntryIsNotData() {
        let held = AccountUpdate(
            address: address,
            account: try? JSONDecoder().decode(
                AccountState.self, from: Data(JSONBuilder.account(round: 64_030_100).utf8)),
            fetchedAt: TestClock().now, isStale: true)
        let update = ChainPoller.Update(
            observedAt: TestClock().now, currentRound: nil, entries: [held], roundTime: 2.8,
            alerts: [], notifications: [], failure: nil, alertHistory: [:],
            alertSeverities: [:])
        #expect(held.account != nil)
        #expect(!update.hasData)
    }

    /// An unreachable source fails every account at once. One alert says so;
    /// repeating it per account would add nothing. An account still failing
    /// once the source answers again has served its time and alerts at once.
    @Test("a full outage raises the source alert, not one per account")
    func fullOutageRaisesOneAlert() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        stub.setFailing(true)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        _ = await poller.pollOnce()
        clock.advance(65)
        _ = await poller.pollOnce()
        clock.advance(65)
        #expect(await poller.pollOnce().alerts.map(\.id) == [.chainSourceUnreachable])

        stub.setFailing(false)
        accountRoute(stub, address)
        stub.route("/v2/accounts/\(second.stringValue)", status: 503, json: "{}")
        sharedRoutes(stub)
        clock.advance(30)
        #expect(await poller.pollOnce().alerts.map(\.id) == [.accountDataUnavailable])
    }

    /// A surface that states one address's trouble for the whole portfolio
    /// would blame every account for one of them, so the failure has to say
    /// which kind it is.
    @Test("one account's failure is not shared, a supply failure is")
    func failureScope() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)  // The second address has no route, so it gets a 404.
        sharedRoutes(stub)

        let oneAccount = await makePoller(stub: stub, clock: clock, addresses: [address, second])
            .pollOnce()
        #expect(oneAccount.entry(for: second)?.failure?.stage.isShared == false)

        // The denominator every account's absence assessment needs, gone.
        stub.route("/v2/ledger/supply", status: 500, json: "{}")
        accountRoute(stub, second)
        let shared = await makePoller(stub: stub, clock: clock, addresses: [address, second])
            .pollOnce()
        #expect(shared.failure?.stage == .supply)
        #expect(shared.failure?.stage.isShared == true)
    }

    /// Cooldowns are held per account as well as per rule. Keyed on the rule
    /// alone, the first account to notify would silence every other account's
    /// first alert of the same kind for the whole cooldown.
    @Test("one account's cooldown cannot silence another's first alert")
    func cooldownsAreIndependentPerAccount() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address, status: "Offline")
        accountRoute(stub, second)
        sharedRoutes(stub)
        let poller = makePoller(stub: stub, clock: clock, addresses: [address, second])

        let first = await poller.pollOnce()
        #expect(first.notifications.map(\.address) == [address])

        // The second account goes offline half a minute later, far inside the
        // 15-minute cooldown the first account's notification started.
        accountRoute(stub, second, status: "Offline")
        clock.advance(30)
        let update = await poller.pollOnce()

        #expect(update.notifications.map(\.address) == [second])
        #expect(update.alerts.count == 2)  // Both conditions still hold.
        #expect(update.alerts.allSatisfy { $0.id == .accountOffline })
    }

    /// Blocks are immutable, so each account resumes past the newest round
    /// already cached for it, which is a different round for every account.
    @Test("each account's rewards query resumes from its own cached round")
    func rewardsResumePerAddress() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        let second = Self.filledAddress(0x11)
        accountRoute(stub, address)
        accountRoute(stub, second)
        sharedRoutes(stub)
        let nowSeconds = Int64(clock.now.timeIntervalSince1970)
        stub.route(
            "proposers=\(Self.addressString)",
            json: JSONBuilder.blockHeaders(
                [(round: 64_029_000, timestamp: nowSeconds - 3_600, payout: 8_000_000)],
                proposer: Self.addressString))
        stub.route(
            "proposers=\(second.stringValue)",
            json: JSONBuilder.blockHeaders(
                [(round: 64_028_000, timestamp: nowSeconds - 3_600, payout: 5_000_000)],
                proposer: second.stringValue))
        let poller = makePoller(
            stub: stub, clock: clock, addresses: [address, second], withIndexer: true)

        let first = await pollAfterRewards(poller, clock: clock)
        #expect(first.entry(for: address)?.rewards?.earned24h == MicroAlgos(8_000_000))
        #expect(first.entry(for: second)?.rewards?.earned24h == MicroAlgos(5_000_000))
        #expect(first.portfolio.earned24h == MicroAlgos(13_000_000))

        clock.advance(301)
        _ = await poller.pollOnce()
        await poller.rewardsSettled()

        let calls = stub.requests.filter { $0.contains("/v2/block-headers") }
        #expect(calls.count == 4)
        #expect(
            calls.contains {
                $0.contains("proposers=\(Self.addressString)") && $0.contains("min-round=64029001")
            })
        #expect(
            calls.contains {
                $0.contains("proposers=\(second.stringValue)")
                    && $0.contains("min-round=64028001")
            })
    }

    /// The one-account case is the common one, so it must cost no more than
    /// its one account: one entry, one account request, a portfolio of one.
    @Test("a single address produces exactly one entry")
    func singleAddressIsOneEntry() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        standardRoutes(stub, seed: nonMatchingSeed)

        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.entries.count == 1)
        #expect(update.only?.address == address)
        #expect(update.hasData)
        #expect(update.portfolio.accountCount == 1)
        #expect(update.portfolio.onlineAccounts == 1)
        #expect(stub.requestCount(containing: "/v2/accounts/") == 1)
    }

    // MARK: - Real captured data

    @Test("runs end to end against captured mainnet responses")
    func realFixtures() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route("/v2/accounts/", body: try Fixture.data("mainnet-account.json"))
        stub.route("/v2/ledger/supply", body: try Fixture.data("mainnet-supply.json"))
        // No block was captured at the challenge round, 64,030,000, and a
        // header for another round is refused, so this one is built. The
        // captured headers are decoded on their own in the model tests.
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 64_030_000, seed: nonMatchingSeed))

        let update = await makePoller(stub: stub, clock: clock).pollOnce()

        #expect(update.failure == nil)
        #expect(update.only?.account?.status == .online)
        #expect(update.only?.account?.incentiveEligible == true)
        #expect(update.only?.absence?.isAbsent == false)
        #expect(update.only?.keyExpiry?.hasExpired == false)
        // The captured round sits 781 past its challenge round, beyond the
        // 2x-grace enforcement bound, so protocol-correct evaluation is nil.
        #expect(update.only?.challenge == nil)
        // A healthy, eligible, well-funded account should be quiet.
        #expect(update.alerts.isEmpty)
    }

    /// The protocol marks a few accounts, such as the fee sink, as not
    /// participating. Watching one shows its record, with no failure and
    /// nothing to alert about.
    @Test("a not-participating account is watched without a failure")
    func notParticipatingAccountIsWatched() async throws {
        let stub = StubFetcher()
        let clock = TestClock()
        stub.route("/v2/accounts/", body: try Fixture.data("mainnet-account-feesink.json"))
        stub.route("/v2/ledger/supply", body: try Fixture.data("mainnet-supply.json"))
        // The block that opens the captured round's challenge window.
        stub.route(
            "/v2/blocks/", json: JSONBuilder.blockHeader(round: 66_067_000, seed: nonMatchingSeed))
        let feeSink = try AlgorandAddress(
            "Y76M3MSY6DKBRHBL7C3NNDXGS5IIMQVQVUAB6MP4XEMMGVF2QWNPL226CA")

        let update = await makePoller(stub: stub, clock: clock, addresses: [feeSink]).pollOnce()

        #expect(update.failure == nil)
        #expect(update.only?.account?.status == .notParticipating)
        #expect(update.alerts.isEmpty)
    }
}
