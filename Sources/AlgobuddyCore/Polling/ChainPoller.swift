import Foundation

public struct ChainPollerConfig: Sendable {
    /// The watched accounts, in the order the caller listed them.
    public var addresses: [AlgorandAddress]
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

    public init(addresses: [AlgorandAddress]) {
        self.addresses = addresses
    }

    /// Convenience for the one-account case, which is most of them.
    public init(address: AlgorandAddress) {
        self.init(addresses: [address])
    }
}

public struct PollFailure: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case account, supply, challengeSeed, rewards

        /// Whether the stage belongs to the cycle rather than to one watched
        /// account. Supply and the challenge seed are fetched once and reach
        /// every account, so a failure there is worth stating for the whole
        /// portfolio; an account fetch and its rewards query are one address's
        /// own, and saying so portfolio-wide would blame every account for one.
        public var isShared: Bool {
            switch self {
            case .supply, .challengeSeed: true
            case .account, .rewards: false
            }
        }
    }
    public let stage: Stage
    public let message: String
}

/// Everything derivable about a set of participation accounts from public chain
/// data, with no credentials and no access to the user's node.
///
/// One poller watches every configured address rather than one poller each: the
/// supply denominator and the challenge seed are the same for all of them, so
/// separate pollers would fetch the same two values over and over and keep as
/// many round clocks, backoffs and update streams as there are accounts.
///
/// Poll shape per cycle: one account fetch per address always; supply, challenge
/// seed and rewards only when their own intervals lapse or the challenge window
/// rolls. In the steady state that is one request per account every 30 s.
/// Rewards run beside the cycles rather than inside one, so an indexer that is
/// slow or unreachable never holds back the figures and alerts that come from
/// algod.
public actor ChainPoller {

    public struct Update: Sendable {
        public let observedAt: Date
        /// The furthest round any account was reported at. The accounts of one
        /// cycle can answer a round apart, and the cycle's own clock takes the
        /// freshest of them.
        public let currentRound: UInt64?
        /// One entry per watched address, in configured order.
        public let entries: [AccountUpdate]
        public let roundTime: TimeInterval
        public let alerts: [HealthAlert]
        /// The subset of `alerts` that should raise a notification now.
        public let notifications: [HealthAlert]
        /// The first thing that went wrong, whichever account or shared stage
        /// it belonged to. An entry's own failure is on the entry.
        public let failure: PollFailure?
        /// Notification times, for the caller to persist so cooldowns survive a
        /// relaunch. See `AlertDispatcher.init(cooldown:lastNotified:lastSeverity:)`.
        public let alertHistory: [AlertKey: Date]
        /// The severity each alert last notified at, persisted with
        /// `alertHistory` so escalation detection survives a relaunch too.
        public let alertSeverities: [AlertKey: AlertSeverity]

        /// Whether any account was actually fetched this cycle. A cycle where
        /// none were carries no figures at all, and its consumers keep the last
        /// update that did on display. A stale entry stands in for a failed
        /// fetch and does not count.
        public var hasData: Bool { entries.contains { $0.account != nil && !$0.isStale } }

        /// What the entries amount to together. Derived on demand, since it is
        /// a pure function of what is already here.
        public var portfolio: PortfolioSummary {
            PortfolioSummary(entries: entries, roundTime: roundTime)
        }
    }

    private let config: ChainPollerConfig
    private let algod: AlgodClient
    private let indexer: IndexerClient?
    private let dates: DateProviding
    private let engine: AlertEngine

    private var roundClock = RoundClock()
    private var dispatcher: AlertDispatcher

    /// One account's proposal history. Kept per address because the
    /// incremental refetch resumes from the newest round already cached, which
    /// is a different round for every account.
    private struct AccountRewards {
        var tracker = RewardsTracker()
        var fetchedAt: Date?
        var isTruncated = false
        /// Why the latest query failed, kept until one succeeds, since the
        /// query finishes after the cycle that started it.
        var failure: PollFailure?
    }
    private var rewards: [AlgorandAddress: AccountRewards] = [:]

    /// The rewards fetch under way, if any. No second one starts beside it, so
    /// a slow indexer is asked once at a time rather than again every cycle.
    private var rewardsFetch: Task<Void, Never>?

    /// Each account's last fetched entry, with the alerts evaluated for it
    /// then. When a later fetch of that account fails while others answer,
    /// these stand in, marked stale: a dropped request must not make a critical
    /// account look healthy.
    private struct LastGood {
        let entry: AccountUpdate
        let alerts: [HealthAlert]
    }
    private var lastGood: [AlgorandAddress: LastGood] = [:]

    /// Consecutive failed fetches of one account, and since when, so an account
    /// that keeps failing raises its own alert even while the others answer.
    private struct AccountOutage {
        var failures: Int
        let since: Date
    }
    private var accountOutages: [AlgorandAddress: AccountOutage] = [:]

    private var supply: LedgerSupply?
    private var supplyFetchedAt: Date?
    private var challengeSeed: Data?
    private var challengeSeedRound: UInt64?
    /// Whether the round clock's anchor block has been asked for. Once per
    /// poller: whatever the answer, the clock times itself after that.
    private var anchorRequested = false
    /// How far back the anchor block lies: about 41 minutes of rounds, past
    /// the half hour the round clock needs for a long span, and within the
    /// last 1000 rounds, which a non-archival algod keeps.
    static let anchorDistance: UInt64 = 900
    private var failingSince: Date?
    private var consecutiveFailures = 0
    private var isStopped = false
    private var pollTask: Task<Void, Never>?
    /// Whether dispatched notifications will actually be shown. When they will
    /// not, the dispatcher is not consulted at all: stamping a notification
    /// nobody saw would silence the real one after the user turns notifications
    /// back on, until its next reminder or, for a rule that never reminds, for
    /// as long as the condition holds. A lock rather than actor state, so a
    /// change takes effect for the very next dispatch instead of after a
    /// task-scheduling hop during which a poll could still stamp.
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
    /// The update most recently published, which a rewards answer arriving
    /// between cycles is shown in. See `republishRewards()`.
    private var lastPublished: Update?

    private func runCycle() async {
        guard !cycleInFlight else { return }
        cycleInFlight = true
        defer { cycleInFlight = false }
        let update = await pollOnce()
        lastPublished = update
        publish(update)
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
        rewardsFetch?.cancel()
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

    /// Reflects whether notifications will be shown, which the app derives
    /// from its toggle and the system's permission, so either can change
    /// without tearing the poller down. Nonisolated and synchronous: a change
    /// is effective the moment this returns, with no scheduling gap for a poll
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
    /// A rewards fetch it starts answers after it: in the published update
    /// again, or in the next one; see `rewardsSettled()`.
    @discardableResult
    func pollOnce() async -> Update {
        let now = dates.now
        let addresses = config.addresses

        var accounts = [AlgorandAddress: AccountState]()
        // Keyed by address, so a failure stays with the account it belongs to
        // instead of standing for the whole cycle.
        var failures = [AlgorandAddress: PollFailure]()
        for (address, result) in await fetchAccounts(addresses) {
            switch result {
            case .success(let account):
                accounts[address] = account
            case .failure(let error):
                failures[address] = pollFailure(error, at: .account)
            }
        }
        for address in addresses {
            if accounts[address] != nil {
                accountOutages[address] = nil
            } else {
                let outage = accountOutages[address]
                accountOutages[address] = AccountOutage(
                    failures: (outage?.failures ?? 0) + 1, since: outage?.since ?? now)
            }
        }

        // A cycle fails only when not one account could be fetched. One
        // unreachable address degrades to that entry's own failure: the rest
        // keep updating, the round still stands, and the shared backoff stays
        // at the steady-state interval rather than punishing every account for
        // one of them.
        guard let round = accounts.values.map(\.round).max() else {
            consecutiveFailures += 1
            if failingSince == nil { failingSince = now }
            return failedUpdate(at: now, failures: failures)
        }

        failingSince = nil
        consecutiveFailures = 0
        roundClock.observe(round: round, at: now)

        // The supply and seed fetches depend only on the accounts above and not
        // on each other, so they overlap: a multi-fetch cycle pays for its
        // slowest leg rather than the sum of the round trips.
        let algod = self.algod
        let needSupply =
            supply == nil || elapsed(since: supplyFetchedAt, now: now) >= config.supplyInterval
        // The seed only changes when the challenge window rolls, so this is one
        // request per interval (~47 minutes at nominal round time), however
        // many accounts are watched.
        let challengeRound = Challenge.challengeRound(for: round, params: config.params)
        let seedRound = challengeRound != challengeSeedRound ? challengeRound : nil

        // The first cycle times the round clock against a block well in the
        // past, so countdowns are right from launch rather than after half an
        // hour of polls.
        let anchorRound =
            !anchorRequested && round > Self.anchorDistance ? round - Self.anchorDistance : nil
        if anchorRound != nil { anchorRequested = true }

        async let supplyFetch = Self.attempt(needSupply ? algod : nil) { try await $0.supply() }
        async let seedFetch = Self.attempt(seedRound) { try await algod.blockHeader($0) }
        async let anchorFetch = Self.attempt(anchorRound) { try await algod.blockHeader($0) }

        var failure: PollFailure?

        // Supply moves slowly, and a stale denominator is far better than no
        // absence assessment, so a failure here is tolerated and the cached
        // value reused.
        switch await supplyFetch {
        case .success(let fetched):
            supply = fetched
            supplyFetchedAt = now
        case .failure(let error):
            failure = failure ?? pollFailure(error, at: .supply)
        case nil:
            break
        }

        switch await seedFetch {
        case .success(let header):
            // Only the header of the round asked for, since another block's
            // seed selects other accounts than the challenge does. A header
            // that omits its round cannot be checked, and is taken as the one
            // asked for.
            let isAsked = header.round.map { $0 == seedRound } ?? true
            if let seed = header.seed, isAsked {
                challengeSeed = seed
                challengeSeedRound = seedRound
            } else {
                // Neither case may stamp the window as fetched: that would
                // silently disable challenge monitoring for the next ~1000
                // rounds. Leaving the round unstamped retries on the next
                // poll, and the failure says why the row is gone.
                let message =
                    isAsked
                    ? "The chain data source returned a block header without a seed, so challenge monitoring is paused."
                    : "The chain data source returned a block other than the challenge block, so challenge monitoring is paused."
                failure = failure ?? PollFailure(stage: .challengeSeed, message: message)
            }
        case .failure(let error):
            failure = failure ?? pollFailure(error, at: .challengeSeed)
        case nil:
            break
        }

        // Only a header for the round asked for, with its time. Anything else,
        // a failure included, leaves the clock to time itself, which it does
        // within half an hour, so it is no failure of the cycle.
        if case .success(let header) = await anchorFetch, let anchorRound,
            header.round == anchorRound, let timestamp = header.timestamp
        {
            roundClock.anchor(
                round: anchorRound, at: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        }

        let fetched = addresses.filter { accounts[$0] != nil }
        // Started after the cycle's last wait, so its answer reaches a later
        // update rather than racing this one.
        startRewardsFetch(for: fetched, round: round, now: now)
        // A fetched account's own failure, if any, is its latest rewards
        // query's, which may have finished between two cycles.
        for address in fetched {
            failures[address] = rewards[address]?.failure
        }

        return successUpdate(
            accounts: accounts, failures: failures, round: round, at: now, failure: failure)
    }

    /// Fetches every watched account at once, so a cycle costs its slowest
    /// account rather than the sum of them, and reports each address's outcome
    /// on its own.
    private func fetchAccounts(
        _ addresses: [AlgorandAddress]
    ) async -> [(AlgorandAddress, Result<AccountState, any Error>)] {
        let algod = self.algod
        return await withTaskGroup(of: (AlgorandAddress, Result<AccountState, any Error>).self) {
            group in
            for address in addresses {
                group.addTask {
                    do {
                        return (address, .success(try await algod.account(address.stringValue)))
                    } catch {
                        return (address, .failure(error))
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
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

    // MARK: - Rewards

    /// Starts the proposal queries that are due, unless a fetch is still out.
    /// A cycle can finish after `stop()`, and a query started then would
    /// outlive the poller and could reach a host the user has since replaced.
    private func startRewardsFetch(for addresses: [AlgorandAddress], round: UInt64, now: Date) {
        guard !isStopped, rewardsFetch == nil, let indexer else { return }
        let windowRounds = UInt64(config.rewardsWindowDays * 86_400 / max(roundClock.estimate, 0.5))
        let windowStart = round > windowRounds ? round - windowRounds : 0
        let requests = addresses.compactMap { address -> ProposalRequest? in
            let state = rewards[address] ?? AccountRewards()
            guard elapsed(since: state.fetchedAt, now: now) >= config.rewardsInterval
            else { return nil }
            // Resume past what is already cached rather than re-downloading
            // the whole window every cycle: blocks are immutable, so anything
            // held cannot have changed, and a previously truncated fetch picks
            // its tail back up from here. The step saturates rather than traps,
            // because the round comes from a user-configured endpoint.
            let resume = state.tracker.highestRound.map { $0 < .max ? $0 + 1 : $0 } ?? 0
            return ProposalRequest(address: address, minRound: max(windowStart, resume))
        }
        guard !requests.isEmpty else { return }
        rewardsFetch = Task { [weak self] in
            let results = await Self.fetchProposals(indexer: indexer, requests: requests)
            await self?.receiveRewards(
                results, windowStart: windowStart, round: round, requestedAt: now)
        }
    }

    /// Takes in a finished rewards fetch, whichever cycle is under way, and
    /// shows it at once. A failed query leaves the account's figures as they
    /// were and records why.
    ///
    /// Shown in the last update, published again, rather than in a cycle run
    /// at once: that cycle would give the round clock a sample over a second
    /// or so, where one round more or less is most of the measurement, and
    /// skew every countdown.
    private func receiveRewards(
        _ results: [(AlgorandAddress, Result<ProposalPage, any Error>)],
        windowStart: UInt64, round: UInt64, requestedAt: Date
    ) {
        rewardsFetch = nil
        for (address, result) in results {
            var state = rewards[address] ?? AccountRewards()
            switch result {
            case .success(let page):
                state.tracker.ingest(page.blocks, windowStartRound: windowStart, latestRound: round)
                state.isTruncated = page.truncated
                state.fetchedAt = requestedAt
                state.failure = nil
            case .failure(let error):
                state.failure = pollFailure(error, at: .rewards)
            }
            rewards[address] = state
        }
        republishRewards()
    }

    /// Publishes the last update again with each account's latest rewards, so
    /// an answer that lands between cycles shows at once rather than with the
    /// next cycle, up to an interval later. Nothing else in the update changes:
    /// no request is made, the round clock takes no sample, and nothing is
    /// dispatched, since no alert rule reads rewards.
    private func republishRewards() {
        guard !isStopped, let last = lastPublished else { return }
        var changed = false
        let entries = last.entries.map { entry -> AccountUpdate in
            // Only an account fetched in that cycle has its rewards shown with
            // it. A stale entry carries an earlier cycle's figures as a whole.
            guard entry.account != nil, !entry.isStale else { return entry }
            let summary = rewardsSummary(for: entry.address, now: last.observedAt)
            let failure = rewards[entry.address]?.failure
            guard summary != entry.rewards || failure != entry.failure else { return entry }
            changed = true
            let answered = entry.answered(rewards: summary, failure: failure)
            // A later cycle that fails to fetch the account carries this
            // entry, so it carries these rewards too.
            if let held = lastGood[entry.address] {
                lastGood[entry.address] = LastGood(entry: answered, alerts: held.alerts)
            }
            return answered
        }
        guard changed else { return }
        let shared = last.failure.flatMap { $0.stage.isShared ? $0 : nil }
        let update = Update(
            observedAt: last.observedAt,
            currentRound: last.currentRound,
            entries: entries,
            roundTime: last.roundTime,
            alerts: last.alerts,
            notifications: [],
            failure: shared ?? entries.compactMap(\.failure).first,
            alertHistory: last.alertHistory,
            alertSeverities: last.alertSeverities)
        lastPublished = update
        publish(update)
    }

    /// An account's proposal history as of `now`. Nil until the indexer has
    /// answered once for it: publishing the empty tracker before that would
    /// present "0 blocks, 0.00 ALGO" as real data while the rewards fetch is in
    /// fact failing or pending.
    private func rewardsSummary(for address: AlgorandAddress, now: Date) -> RewardsSummary? {
        guard let state = rewards[address], state.fetchedAt != nil else { return nil }
        var summary = state.tracker.summary(now: now)
        summary.isTruncated = state.isTruncated
        return summary
    }

    /// Waits until the rewards fetch under way, if any, has been taken in. No
    /// cycle waits for it; a test does, to know which update will show it.
    func rewardsSettled() async {
        await rewardsFetch?.value
    }

    // MARK: - Derivation

    private func successUpdate(
        accounts: [AlgorandAddress: AccountState],
        failures: [AlgorandAddress: PollFailure],
        round: UInt64,
        at now: Date,
        failure: PollFailure?
    ) -> Update {
        var entries = [AccountUpdate]()
        // Everything that holds, for display, and the part of it derived from
        // fresh figures, which alone may notify.
        var alerts = [HealthAlert]()
        var fresh = [HealthAlert]()

        for address in config.addresses {
            guard let account = accounts[address] else {
                // Nothing new was learned about this account, so no rule is run
                // against figures from an earlier round. Its last good entry
                // and the alerts evaluated with it stand in, marked stale, and
                // stay off the dispatch: a reminder needs current figures.
                let failure = failures[address]
                if let held = lastGood[address] {
                    entries.append(held.entry.stale(failure: failure))
                    alerts.append(contentsOf: held.alerts)
                } else {
                    entries.append(AccountUpdate(address: address, failure: failure))
                }
                if let unavailable = unavailableAlert(for: address, now: now) {
                    alerts.append(unavailable)
                    fresh.append(unavailable)
                }
                continue
            }
            let entry = derive(
                address: address, account: account, failure: failures[address], now: now)
            let entryAlerts = engine.evaluate(snapshot(for: entry))
            lastGood[address] = LastGood(entry: entry, alerts: entryAlerts)
            entries.append(entry)
            alerts.append(contentsOf: entryAlerts)
            fresh.append(contentsOf: entryAlerts)
        }

        // The watch itself counts as evaluated: an account answered, so the
        // source is reachable and its outage alert has cleared.
        let evaluated = Set(accounts.keys.map { Optional($0) } + [nil])
        return Update(
            observedAt: now,
            currentRound: round,
            entries: entries,
            roundTime: roundClock.estimate,
            alerts: ordered(alerts),
            notifications: dispatch(ordered(fresh), evaluated: evaluated, now: now),
            // A shared stage that failed outranks an individual account's
            // failure: it is the one that reaches every entry.
            failure: failure ?? config.addresses.compactMap { failures[$0] }.first,
            alertHistory: dispatcher.notificationHistory,
            alertSeverities: dispatcher.severityHistory)
    }

    /// One account's share of the cycle, derived against the round that account
    /// itself was reported at.
    private func derive(
        address: AlgorandAddress, account: AccountState, failure: PollFailure?, now: Date
    ) -> AccountUpdate {
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
                address: address,
                seed: seed,
                challengeRound: seedRound,
                currentRound: round,
                lastSeen: account.lastSeen,
                params: config.params)
        }

        return AccountUpdate(
            address: address,
            account: account,
            absence: absence,
            challenge: challenge,
            keyExpiry: account.participation.map {
                KeyExpiry(participation: $0, currentRound: round)
            },
            rewards: rewardsSummary(for: address, now: now),
            failure: failure,
            fetchedAt: now)
    }

    /// The alert for one account the source keeps failing to return while it
    /// answers for others, on the same two conditions as the source's own
    /// outage alert: enough attempts and enough time. A full outage raises
    /// only that one instead, rather than repeating it once per account.
    private func unavailableAlert(for address: AlgorandAddress, now: Date) -> HealthAlert? {
        guard let outage = accountOutages[address],
            outage.failures >= config.failuresBeforeAlert,
            now.timeIntervalSince(outage.since) >= config.unreachableAfter
        else { return nil }
        let minutes = now.timeIntervalSince(outage.since) / 60
        return HealthAlert(
            id: .accountDataUnavailable,
            address: address,
            severity: .warning,
            title: "Account data unavailable",
            body:
                "The chain data source has not returned this account for \(quantity(minutes, "minute")), although it answers for the others. Its figures and alerts may be out of date."
        )
    }

    private func snapshot(for entry: AccountUpdate) -> Snapshot {
        Snapshot(
            roundTime: roundClock.estimate,
            params: config.params,
            address: entry.address,
            account: entry.account,
            absence: entry.absence,
            challenge: entry.challenge,
            keyExpiry: entry.keyExpiry)
    }

    /// Severity first, and within a severity the order the accounts are watched
    /// in, which Swift's stable sort keeps, so equally severe alerts never
    /// swap places between polls and read as something changing.
    private func ordered(_ alerts: [HealthAlert]) -> [HealthAlert] {
        alerts.sorted { $0.severity > $1.severity }
    }

    /// The dispatcher is consulted only when notifications will actually be
    /// shown. Otherwise its stamps would record deliveries that never happened,
    /// and the first real notification after re-enabling would be held back by
    /// a reminder interval nobody benefited from.
    ///
    /// - Parameter evaluated: The accounts this cycle derived alerts for, nil
    ///   standing for the watch itself, so an account whose fetch failed does
    ///   not count as having cleared.
    private func dispatch(
        _ alerts: [HealthAlert], evaluated: Set<AlgorandAddress?>, now: Date
    ) -> [HealthAlert] {
        guard notificationsGate.isWanted else { return [] }
        return dispatcher.dispatch(alerts, evaluated: evaluated, now: now)
    }

    /// A failed cycle deliberately evaluates **no** participation alerts.
    ///
    /// Every derived signal is a function of the current round, so re-running
    /// the rules against an account record from hours ago produces confident,
    /// wrong answers: a countdown that has silently stopped moving. The caller
    /// keeps its last data-bearing update on display and ages it from
    /// `observedAt`; the chain source itself is alerted on only after repeated
    /// failures.
    private func failedUpdate(at now: Date, failures: [AlgorandAddress: PollFailure]) -> Update {
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
            entries: config.addresses.map { AccountUpdate(address: $0, failure: failures[$0]) },
            roundTime: roundClock.estimate,
            alerts: alerts,
            // No account was fetched, so only the watch itself was evaluated
            // and none of the accounts' alerts has cleared.
            notifications: dispatch(alerts, evaluated: [nil], now: now),
            // Every account failed, so the first one's reason stands for the
            // cycle. Repeating the same sentence per address would say nothing
            // more about a source that is simply unreachable.
            failure: config.addresses.compactMap { failures[$0] }.first,
            alertHistory: dispatcher.notificationHistory,
            alertSeverities: dispatcher.severityHistory)
    }

    // MARK: - Helpers

    /// One account's proposal query for this cycle.
    private struct ProposalRequest: Sendable {
        let address: AlgorandAddress
        let minRound: UInt64
    }

    private struct ProposalPage: Sendable {
        let blocks: [IndexerClient.ProposedBlock]
        /// The page budget was exhausted with results still outstanding.
        let truncated: Bool
    }

    /// Runs every due account's proposal query at once, and reports each
    /// address's outcome on its own so one indexer error cannot blank the
    /// rewards of the accounts that answered.
    private nonisolated static func fetchProposals(
        indexer: IndexerClient, requests: [ProposalRequest]
    ) async -> [(AlgorandAddress, Result<ProposalPage, any Error>)] {
        await withTaskGroup(of: (AlgorandAddress, Result<ProposalPage, any Error>).self) {
            group in
            for request in requests {
                group.addTask {
                    do {
                        let page = try await fetchProposals(
                            indexer: indexer,
                            address: request.address.stringValue,
                            minRound: request.minRound)
                        return (request.address, .success(page))
                    } catch {
                        return (request.address, .failure(error))
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    /// - Returns: the proposals, and whether the page budget was exhausted with
    ///   results still outstanding.
    private nonisolated static func fetchProposals(
        indexer: IndexerClient,
        address: String,
        minRound: UInt64
    ) async throws -> ProposalPage {
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
        return ProposalPage(blocks: collected, truncated: next != nil)
    }

    private func elapsed(since date: Date?, now: Date) -> TimeInterval {
        guard let date else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(date)
    }

    /// A failure at one stage, described for that stage.
    private func pollFailure(_ error: any Error, at stage: PollFailure.Stage) -> PollFailure {
        PollFailure(stage: stage, message: describe(error, at: stage))
    }

    /// Plain language, for the panel to show as-is. The request that failed is
    /// identified by the failure's `stage` rather than by a raw path: a URL with
    /// an address embedded in it is a log line, not something to read. The
    /// stage also decides what a status can mean, since the same 404 says one
    /// thing from the challenge block and another from the account.
    private func describe(_ error: any Error, at stage: PollFailure.Stage) -> String {
        // Only the rewards stage asks the indexer; every other stage asks algod.
        let source = stage == .rewards ? "The indexer" : "The chain data source"
        let check = stage == .rewards ? "Check the indexer URL." : "Check the URL points at algod."
        guard let algodError = error as? AlgodError else {
            return "\(source) could not be reached."
        }
        switch algodError {
        case .unauthorized:
            return "\(source) requires a token. Public providers serve it without one."
        case .notFound where stage == .challengeSeed:
            // The accounts answered at or past this block's round, so the block
            // exists, and the backend that took this request is behind, as one
            // behind a load balancer can be.
            return
                "The chain data source does not have the challenge block yet, so challenge monitoring is paused until the next poll."
        case .notFound:
            // algod answers for every well-formed address, one never funded
            // included, so a missing record means a URL that misses its API.
            return "\(source) has no such endpoint. \(check)"
        case .http(let status, _):
            return "\(source) returned an error (\(status))."
        case .decoding:
            return "\(source) returned an unexpected response. \(check)"
        case .notHTTP:
            return "\(source) did not return an HTTP response."
        case .redirectRefused:
            return
                "\(source) redirected elsewhere, and algobuddy only contacts the configured hosts. Check the URL."
        }
    }
}
