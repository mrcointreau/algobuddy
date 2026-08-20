import Foundation

public struct ChainPollerConfig: Sendable {
    public var address: AlgorandAddress
    public var accountInterval: TimeInterval = 30
    public var supplyInterval: TimeInterval = 300
    public var rewardsInterval: TimeInterval = 300
    /// How far back to ask the indexer for proposals. Wider than the 7-day
    /// summary window so a slow poll cannot clip the edge of it.
    public var rewardsWindowDays: Double = 8
    public var minBackoff: TimeInterval = 5
    public var maxBackoff: TimeInterval = 300
    /// Consecutive failures before the chain source itself is reported unhealthy.
    public var failuresBeforeAlert = 3
    /// How long the failures must have been sustained before that alert fires.
    ///
    /// A failure count alone is far too eager: with the default backoff the
    /// third failure lands 15 seconds in, so a wifi transition or a hiccup at a
    /// public endpoint would notify. Requiring sustained failure means a laptop
    /// that briefly loses its network stays quiet.
    public var unreachableAfter: TimeInterval = 120
    public var params: ConsensusParams = .v40

    public init(address: AlgorandAddress) {
        self.address = address
    }
}

public struct PollFailure: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case account, supply, challengeSeed, rewards
    }
    public let stage: Stage
    public let message: String
}

/// Everything derivable about a participation account from public chain data,
/// with no credentials and no access to the user's node.
///
/// Poll shape per cycle: one account fetch always; supply, challenge seed and
/// rewards only when their own intervals lapse or the challenge window rolls.
/// In the steady state that is a single request every 30 s.
public actor ChainPoller {

    public struct Update: Sendable {
        public let observedAt: Date
        public let currentRound: UInt64?
        public let account: AccountState?
        public let absence: AbsenceAssessment?
        public let challenge: ChallengeState?
        public let keyExpiry: KeyExpiry?
        public let rewards: RewardsSummary?
        public let roundTime: TimeInterval
        public let alerts: [HealthAlert]
        /// The subset of `alerts` that should raise a notification now.
        public let notifications: [HealthAlert]
        public let failure: PollFailure?
        /// Notification times, for the caller to persist so cooldowns survive a
        /// relaunch. See `AlertDispatcher.init(cooldown:lastNotified:lastSeverity:)`.
        public let alertHistory: [AlertID: Date]
        /// Severities at last evaluation, persisted with `alertHistory` so
        /// escalation detection survives a relaunch too.
        public let alertSeverities: [AlertID: AlertSeverity]
    }

    private let config: ChainPollerConfig
    private let algod: AlgodClient
    private let indexer: IndexerClient?
    private let dates: DateProviding
    private let engine: AlertEngine

    private var roundClock = RoundClock()
    private var dispatcher: AlertDispatcher
    private var rewardsTracker = RewardsTracker()

    private var supply: LedgerSupply?
    private var supplyFetchedAt: Date?
    private var challengeSeed: Data?
    private var challengeSeedRound: UInt64?
    private var rewardsFetchedAt: Date?
    private var failingSince: Date?
    private var consecutiveFailures = 0
    private var rewardsTruncated = false
    private var isStopped = false
    private var pollTask: Task<Void, Never>?
    /// Whether dispatched notifications will actually be shown. When they will
    /// not, the dispatcher is not consulted at all: stamping a cooldown for a
    /// notification nobody saw would silence the real one for 15 minutes after
    /// the user turns notifications back on. A lock rather than actor state, so
    /// the app's toggle takes effect for the very next dispatch instead of
    /// after a task-scheduling hop during which a poll could still stamp.
    private final class NotificationsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var wanted: Bool
        init(_ wanted: Bool) { self.wanted = wanted }
        var isWanted: Bool { lock.withLock { wanted } }
        func set(_ value: Bool) { lock.withLock { wanted = value } }
    }
    private nonisolated let notificationsGate: NotificationsGate

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation

    public init(
        config: ChainPollerConfig,
        algod: AlgodClient,
        indexer: IndexerClient? = nil,
        engine: AlertEngine = AlertEngine(),
        dispatcher: AlertDispatcher = AlertDispatcher(),
        dates: DateProviding = SystemDateProvider(),
        notificationsWanted: Bool = true
    ) {
        self.config = config
        self.algod = algod
        self.indexer = indexer
        self.engine = engine
        self.dispatcher = dispatcher
        self.dates = dates
        self.notificationsGate = NotificationsGate(notificationsWanted)

        var escaped: AsyncStream<Update>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { escaped = $0 }
        self.continuation = escaped
    }

    // MARK: - Lifecycle

    /// Begins polling. No-op if already running, or if `stop()` has been called.
    /// See `stop()` for why that is terminal.
    public func start() {
        guard !isStopped, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runCycle()
                let delay = await self.nextDelay
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    /// One cycle, atomically: poll, then publish, under a single in-flight
    /// guard shared by the loop and `refresh()`. The actor is reentrant at
    /// await points, so without this a refresh during the loop's suspended
    /// cycle (or the loop waking during a slow refresh) would run two cycles
    /// concurrently: duplicate requests, double-counted failures, and an
    /// older update publishing after a newer one.
    private var cycleInFlight = false

    private func runCycle() async {
        guard !cycleInFlight else { return }
        cycleInFlight = true
        defer { cycleInFlight = false }
        publish(await pollOnce())
    }

    /// Stops polling **permanently**. To resume, build a new poller.
    ///
    /// This is terminal because finishing the continuation ends the stream for
    /// good: a subsequent `start()` would poll happily while `publish()` dropped
    /// every update on the floor and each consumer's `for await` had already
    /// exited: polling forever, showing nothing, reporting no error. The
    /// `isStopped` flag makes that an explicit no-op instead.
    ///
    /// It also closes an ordering race: two `apply()` calls in quick succession
    /// can enqueue `stop()` and `start()` on this actor with no guaranteed
    /// order, and a `start()` running after its `stop()` would otherwise install
    /// an orphaned poll loop that nothing holds a reference to and nothing can
    /// cancel.
    public func stop() {
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        continuation.finish()
    }

    private func publish(_ update: Update) {
        continuation.yield(update)
    }

    /// Polls immediately **and publishes the result**, which is what a
    /// user-initiated refresh needs.
    ///
    /// `pollOnce()` returns its Update to the caller and publishes nothing,
    /// which is right for tests but wrong for a Refresh button: the poll ran,
    /// consumed requests, advanced the round clock and, worst of all, recorded
    /// dispatcher cooldowns, while the UI saw none of it and a notification
    /// could be marked delivered without ever being shown.
    public func refresh() async {
        // Serialised against the loop through runCycle's guard: a refresh
        // during an active cycle has nothing to offer, since that cycle's
        // result is already on its way.
        guard !isStopped else { return }
        await runCycle()
    }

    /// Reflects the app-side notifications toggle, so it can change without
    /// tearing the poller down. Nonisolated and synchronous: the toggle is
    /// effective the moment this returns, with no scheduling gap for a poll
    /// to stamp a cooldown nobody will see.
    public nonisolated func setNotificationsWanted(_ wanted: Bool) {
        notificationsGate.set(wanted)
    }

    /// Steady-state interval, or exponential backoff after failures.
    var nextDelay: TimeInterval {
        guard consecutiveFailures > 0 else { return config.accountInterval }
        let scaled = config.minBackoff * pow(2, Double(consecutiveFailures - 1))
        return min(config.maxBackoff, scaled)
    }

    // MARK: - One cycle

    /// Runs a single poll and returns the result. Split out from `start()` so
    /// every behaviour below is testable without timers or sleeping. Callers
    /// that publish go through `runCycle()`, which owns the in-flight guard.
    @discardableResult
    public func pollOnce() async -> Update {
        let now = dates.now
        let address = config.address.stringValue

        let account: AccountState
        do {
            account = try await algod.account(address)
        } catch {
            consecutiveFailures += 1
            if failingSince == nil { failingSince = now }
            return failedUpdate(
                at: now,
                failure: PollFailure(stage: .account, message: describe(error)))
        }

        failingSince = nil
        consecutiveFailures = 0
        let round = account.round
        roundClock.observe(round: round, at: now)

        // The three remaining fetches depend only on the account fetch above
        // and not on each other, so they overlap: a multi-fetch cycle pays for
        // its slowest leg rather than the sum of the round trips.
        let algod = self.algod
        let needSupply =
            supply == nil || elapsed(since: supplyFetchedAt, now: now) >= config.supplyInterval
        // The seed only changes when the challenge window rolls, so this is one
        // request per interval (~47 minutes at nominal round time).
        let challengeRound = Challenge.challengeRound(for: round, params: config.params)
        let seedRound = challengeRound != challengeSeedRound ? challengeRound : nil
        let rewardsDue = elapsed(since: rewardsFetchedAt, now: now) >= config.rewardsInterval
        let windowRounds = UInt64(config.rewardsWindowDays * 86_400 / max(roundClock.estimate, 0.5))
        let windowStart = round > windowRounds ? round - windowRounds : 0
        // Resume past what is already cached rather than re-downloading the
        // whole window every cycle: blocks are immutable, so anything held
        // cannot have changed, and a previously truncated fetch picks its tail
        // back up from here.
        let fetchFrom = max(windowStart, rewardsTracker.highestRound.map { $0 + 1 } ?? 0)

        async let supplyFetch = Self.attempt(needSupply ? algod : nil) { try await $0.supply() }
        async let seedFetch = Self.attempt(seedRound) { try await algod.blockHeader($0) }
        async let rewardsFetch = Self.attempt(rewardsDue ? indexer : nil) {
            try await Self.fetchProposals(indexer: $0, address: address, minRound: fetchFrom)
        }

        var failure: PollFailure?

        // Supply moves slowly, and a stale denominator is far better than no
        // absence assessment, so a failure here is tolerated and the cached
        // value reused.
        switch await supplyFetch {
        case .success(let fetched):
            supply = fetched
            supplyFetchedAt = now
        case .failure(let error):
            failure = failure ?? PollFailure(stage: .supply, message: describe(error))
        case nil:
            break
        }

        switch await seedFetch {
        case .success(let header):
            if let seed = header.seed {
                challengeSeed = seed
                challengeSeedRound = seedRound
            } else {
                // A 200 with no seed must not stamp the window as fetched:
                // that would silently disable challenge monitoring for the
                // next ~1000 rounds. Leaving the round unstamped retries on
                // the next poll, and the failure says why the row is gone.
                failure =
                    failure
                    ?? PollFailure(
                        stage: .challengeSeed,
                        message:
                            "The chain data source returned a block header without a seed, so challenge monitoring is paused."
                    )
            }
        case .failure(let error):
            failure = failure ?? PollFailure(stage: .challengeSeed, message: describe(error))
        case nil:
            break
        }

        switch await rewardsFetch {
        case .success(let page):
            rewardsTracker.ingest(page.blocks, windowStartRound: windowStart)
            rewardsTruncated = page.truncated
            rewardsFetchedAt = now
        case .failure(let error):
            failure = failure ?? PollFailure(stage: .rewards, message: describe(error))
        case nil:
            break
        }

        return successUpdate(account: account, at: now, failure: failure)
    }

    /// Runs `operation` on `input` when it is non-nil, capturing the error
    /// instead of throwing, so the independent fetches above can overlap and
    /// still report their failures individually.
    private nonisolated static func attempt<Input: Sendable, Value: Sendable>(
        _ input: Input?, _ operation: @Sendable (Input) async throws -> Value
    ) async -> Result<Value, any Error>? {
        guard let input else { return nil }
        do { return .success(try await operation(input)) } catch { return .failure(error) }
    }

    // MARK: - Derivation

    private func successUpdate(account: AccountState, at now: Date, failure: PollFailure?) -> Update
    {
        let round = account.round
        // Absenteeism and challenges are protocol mechanisms that apply only to
        // Online accounts, so the gate lives here at derivation: every consumer
        // (alerts, panel rows, menu bar metrics) inherits it instead of each
        // re-imposing the rule for its own surface.
        let isOnline = account.status == .online

        let absence: AbsenceAssessment? =
            !isOnline
            ? nil
            : supply.flatMap { supply in
                Absence.assess(
                    accountStake: account.amount,
                    totalOnlineStake: supply.effectiveOnlineStake,
                    lastSeen: account.lastSeen,
                    currentRound: round,
                    params: config.params)
            }

        // The cached seed is only meaningful for the window it was fetched for.
        // If that fetch failed, the previous window's seed is still in hand.
        // Evaluating against it can manufacture a critical "challenged and not
        // answered" for a window that closed long ago.
        var challenge: ChallengeState?
        if isOnline,
            let seed = challengeSeed,
            let seedRound = challengeSeedRound,
            seedRound == Challenge.challengeRound(for: round, params: config.params)
        {
            challenge = Challenge.evaluate(
                address: config.address,
                seed: seed,
                challengeRound: seedRound,
                currentRound: round,
                lastSeen: account.lastSeen,
                params: config.params)
        }

        let keyExpiry = account.participation.map {
            KeyExpiry(participation: $0, currentRound: round)
        }

        let snapshot = Snapshot(
            roundTime: roundClock.estimate,
            params: config.params,
            account: account,
            absence: absence,
            challenge: challenge,
            keyExpiry: keyExpiry)

        let alerts = engine.evaluate(snapshot)
        return Update(
            observedAt: now,
            currentRound: round,
            account: account,
            absence: absence,
            challenge: challenge,
            keyExpiry: keyExpiry,
            // Nil until the indexer has answered once. Publishing the empty
            // tracker before that would present "0 blocks, 0.00 ALGO" as real
            // data while the rewards fetch is in fact failing or pending.
            rewards: rewardsFetchedAt == nil ? nil : rewardsSummary(now: now),
            roundTime: roundClock.estimate,
            alerts: alerts,
            notifications: dispatch(alerts, now: now),
            failure: failure,
            alertHistory: dispatcher.notificationHistory,
            alertSeverities: dispatcher.severityHistory)
    }

    /// The dispatcher is consulted only when notifications will actually be
    /// shown. Otherwise its cooldown stamps would record deliveries that never
    /// happened, and the first real notification after re-enabling would be
    /// swallowed by a cooldown nobody benefited from.
    private func dispatch(_ alerts: [HealthAlert], now: Date) -> [HealthAlert] {
        guard notificationsGate.isWanted else { return [] }
        return dispatcher.dispatch(alerts, now: now)
    }

    /// A failed cycle deliberately evaluates **no** participation alerts.
    ///
    /// Every derived signal is a function of the current round, so re-running
    /// the rules against an account record from hours ago produces confident,
    /// wrong answers: a countdown that has silently stopped moving. The caller
    /// keeps its last data-bearing update on display and ages it from
    /// `observedAt`; the chain source itself is alerted on only after repeated
    /// failures.
    private func failedUpdate(at now: Date, failure: PollFailure) -> Update {
        var alerts = [HealthAlert]()
        let failingFor = failingSince.map { now.timeIntervalSince($0) } ?? 0

        // Both conditions, deliberately: enough attempts *and* enough elapsed
        // time. Either one alone fires on a momentary network blip.
        if consecutiveFailures >= config.failuresBeforeAlert, failingFor >= config.unreachableAfter
        {
            alerts.append(
                HealthAlert(
                    id: .chainSourceUnreachable,
                    severity: .warning,
                    title: "Chain data unavailable",
                    body:
                        "No response from the chain data source for \(quantity(failingFor / 60, "minute")). Participation status may be out of date."
                ))
        }

        return Update(
            observedAt: now,
            currentRound: nil,
            account: nil,
            absence: nil,
            challenge: nil,
            keyExpiry: nil,
            rewards: nil,
            roundTime: roundClock.estimate,
            alerts: alerts,
            notifications: dispatch(alerts, now: now),
            failure: failure,
            alertHistory: dispatcher.notificationHistory,
            alertSeverities: dispatcher.severityHistory)
    }

    // MARK: - Helpers

    /// - Returns: the proposals, and whether the page budget was exhausted with
    ///   results still outstanding.
    private nonisolated static func fetchProposals(
        indexer: IndexerClient,
        address: String,
        minRound: UInt64
    ) async throws -> (blocks: [IndexerClient.ProposedBlock], truncated: Bool) {
        // Results arrive oldest-first, so exhausting this budget drops the
        // *newest* proposals, the ones the 24h and 7d figures are made of.
        // 10 pages covers ~125 proposals a day, well past any account that
        // isn't among the largest stakers on the network.
        let pageBudget = 10
        var collected = [IndexerClient.ProposedBlock]()
        var next: String?
        var pages = 0

        repeat {
            let page = try await indexer.blockHeaders(
                proposer: address, minRound: minRound, limit: 100, next: next)
            collected.append(contentsOf: page.blocks)
            next = page.nextToken
            pages += 1
        } while next != nil && pages < pageBudget

        // A token still outstanding means recent proposals were never
        // fetched, so both figures are floors rather than merely incomplete.
        return (collected, next != nil)
    }

    private func rewardsSummary(now: Date) -> RewardsSummary {
        var summary = rewardsTracker.summary(now: now)
        summary.isTruncated = rewardsTruncated
        return summary
    }

    private func elapsed(since date: Date?, now: Date) -> TimeInterval {
        guard let date else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(date)
    }

    /// Plain language, for the panel to show as-is. The request that failed is
    /// identified by the failure's `stage` rather than by a raw path: a URL with
    /// an address embedded in it is a log line, not something to read.
    private func describe(_ error: any Error) -> String {
        guard let algodError = error as? AlgodError else {
            return "The chain data source could not be reached."
        }
        switch algodError {
        case .unauthorized:
            return "The chain data source requires a token. Public providers serve it without one."
        case .notFound:
            return
                "The chain data source has no record of this address. Check the address and the network."
        case .http(let status, _):
            return "The chain data source returned an error (\(status))."
        case .decoding:
            return
                "The chain data source returned an unexpected response. Check the URL points at algod."
        case .notHTTP:
            return "The chain data source did not return an HTTP response."
        }
    }
}
