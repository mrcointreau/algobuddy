import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Round clock")
struct RoundClockTests {
    let start = Date(timeIntervalSince1970: 1_786_000_000)

    @Test("reports the nominal estimate before it has measured anything")
    func nominal() {
        let clock = RoundClock()
        #expect(clock.estimate == RoundClock.nominal)
        #expect(clock.sampleCount == 0)
    }

    @Test("a single observation cannot produce an estimate")
    func singleObservation() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        #expect(clock.sampleCount == 0)
    }

    @Test("converges on the observed rate")
    func converges() {
        var clock = RoundClock()
        for step in 0...20 {
            clock.observe(
                round: UInt64(1_000 + step * 10), at: start.addingTimeInterval(Double(step) * 30))
        }
        #expect(clock.sampleCount > 0)
        #expect(abs(clock.estimate - 3.0) < 0.05)
    }

    @Test("ignores rounds that do not advance")
    func stalled() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        clock.observe(round: 1_000, at: start.addingTimeInterval(600))
        clock.observe(round: 999, at: start.addingTimeInterval(1_200))
        #expect(clock.sampleCount == 0)
        #expect(clock.estimate == RoundClock.nominal)
    }

    @Test("discards implausible samples instead of poisoning the estimate")
    func outliers() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        // Ten rounds in an hour: a stalled chain, not a round time.
        clock.observe(round: 1_010, at: start.addingTimeInterval(3_600))
        #expect(clock.sampleCount == 0)
        #expect(clock.estimate == RoundClock.nominal)
    }

    /// Waking from sleep advances wall time and rounds together, so the ratio
    /// still holds and the sample should be kept.
    @Test("a long gap with proportional round advance is a valid sample")
    func sleepWake() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        clock.observe(round: 1_000 + 10_285, at: start.addingTimeInterval(8 * 3_600))
        #expect(clock.sampleCount == 1)
        #expect(abs(clock.estimate - 2.8) < 0.01)
    }

    /// A refresh seconds after a poll sees a few rounds, where one round more
    /// or less is a large part of the sample. Its start stays, so the next
    /// sample spans both.
    @Test("a sample over too few rounds waits for a longer one")
    func shortSampleWaits() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        clock.observe(round: 1_003, at: start.addingTimeInterval(8))
        #expect(clock.sampleCount == 0)
        #expect(clock.estimate == RoundClock.nominal)

        clock.observe(round: 1_011, at: start.addingTimeInterval(30))
        #expect(clock.sampleCount == 1)
        let blended = RoundClock.nominal + 0.2 * (30.0 / 11 - RoundClock.nominal)
        #expect(abs(clock.estimate - blended) < 1e-9)
    }

    /// A backend behind a load balancer can answer with the same round again,
    /// or with an older one. Neither is a start: round 1,000 was already
    /// reached when it was first seen, so the next sample spans all 30 s.
    @Test("a round that does not advance keeps the sample's start")
    func stalledRoundKeepsStart() {
        var clock = RoundClock()
        clock.observe(round: 1_000, at: start)
        clock.observe(round: 1_000, at: start.addingTimeInterval(2))
        clock.observe(round: 995, at: start.addingTimeInterval(15))
        clock.observe(round: 1_011, at: start.addingTimeInterval(30))
        #expect(clock.sampleCount == 1)
        let blended = RoundClock.nominal + 0.2 * (30.0 / 11 - RoundClock.nominal)
        #expect(abs(clock.estimate - blended) < 1e-9)
    }

    @Test("an anchor gives the rate over a long span from the first observation")
    func anchorGivesLongSpan() {
        var clock = RoundClock()
        clock.anchor(round: 1_000, at: start)
        clock.observe(round: 1_900, at: start.addingTimeInterval(900 * 2.76))
        #expect(abs(clock.estimate - 2.76) < 1e-9)
        #expect(clock.sampleCount == 0)
    }

    /// An anchor is the start of the span, so one that is not earlier in both
    /// round and time than the start already held is ignored. Taking either of
    /// these would shorten the span below half an hour and lose the rate.
    @Test("an anchor that is not earlier than the span's start is ignored")
    func lateAnchorIgnored() {
        var clock = RoundClock()
        clock.anchor(round: 1_000, at: start)
        clock.anchor(round: 1_500, at: start.addingTimeInterval(1_000))
        clock.anchor(round: 500, at: start.addingTimeInterval(1_000))
        clock.observe(round: 1_900, at: start.addingTimeInterval(900 * 2.76))
        #expect(abs(clock.estimate - 2.76) < 1e-9)
    }

    /// Each 30 s poll sees 10 or 11 whole rounds of 2.8 s, a swing of about 5%
    /// per sample. Once the rounds have been watched long enough, the estimate
    /// comes from the whole span and stays within a small fraction of a
    /// percent.
    @Test("a long span removes the poll-to-poll swing")
    func longSpanIsSteady() {
        var clock = RoundClock()
        var worst = 0.0
        for poll in 0...(3 * 120) {
            let elapsed = Double(poll) * 30
            clock.observe(
                round: 1_000 + UInt64(elapsed / 2.8), at: start.addingTimeInterval(elapsed))
            if elapsed >= 75 * 60 { worst = max(worst, abs(clock.estimate - 2.8)) }
        }
        #expect(worst < 0.003)
    }
}

extension AlertDispatcher {
    /// A dispatch that evaluates the watch alone, which is all the alerts of
    /// `AlertDispatcherTests.alert` belong to, since they name no account.
    fileprivate mutating func dispatch(_ alerts: [HealthAlert], now: Date) -> [HealthAlert] {
        dispatch(alerts, evaluated: [nil], now: now)
    }
}

@Suite("Alert dispatcher")
struct AlertDispatcherTests {
    let start = Date(timeIntervalSince1970: 1_786_000_000)

    func alert(_ id: AlertID = .keyExpiry, _ severity: AlertSeverity = .warning) -> HealthAlert {
        HealthAlert(id: id, severity: severity, title: "t", body: "b")
    }

    @Test("a new alert notifies immediately")
    func firstFire() {
        var dispatcher = AlertDispatcher()
        #expect(dispatcher.dispatch([alert()], now: start).count == 1)
    }

    /// The rules re-derive every alert on every poll, so without suppression a
    /// day-long warning would notify thousands of times.
    @Test("a holding alert is suppressed within the cooldown")
    func suppressed() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert()], now: start)
        #expect(dispatcher.dispatch([alert()], now: start.addingTimeInterval(60)).isEmpty)
        #expect(dispatcher.dispatch([alert()], now: start.addingTimeInterval(800)).isEmpty)
    }

    /// A challenge left unanswered can suspend the account within minutes, so
    /// it repeats at the cooldown for as long as it holds.
    @Test("an urgent alert reminds once the cooldown lapses")
    func urgentReminds() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        let challenge = alert(.challengeFailing, .critical)
        _ = dispatcher.dispatch([challenge], now: start)
        #expect(dispatcher.dispatch([challenge], now: start.addingTimeInterval(901)).count == 1)
    }

    /// Keys that expire in two weeks are worth a daily reminder, not one every
    /// fifteen minutes for eleven days.
    @Test("a key-expiry warning reminds once a day")
    func keyWarningRemindsDaily() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert()], now: start)
        #expect(dispatcher.dispatch([alert()], now: start.addingTimeInterval(901)).isEmpty)
        #expect(dispatcher.dispatch([alert()], now: start.addingTimeInterval(86_401)).count == 1)
    }

    /// An account can be Offline by choice for months. It is announced when it
    /// appears, and the menu bar and the panel carry it from there.
    @Test("an Offline account never reminds while it holds")
    func offlineNeverReminds() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        let offline = alert(.accountOffline, .critical)
        #expect(dispatcher.dispatch([offline], now: start).count == 1)
        for elapsed: TimeInterval in [901, 86_401, 30 * 86_400] {
            #expect(dispatcher.dispatch([offline], now: start.addingTimeInterval(elapsed)).isEmpty)
        }
    }

    /// The cooldown is persisted across launches; the severity must be too, or
    /// a warning that comes back critical inside the restored cooldown would
    /// notify nobody after a relaunch.
    @Test("escalation survives a relaunch via seeded severity")
    func escalationSurvivesRelaunch() {
        var before = AlertDispatcher(cooldown: 900)
        _ = before.dispatch([alert(.absenceHeadroom, .warning)], now: start)

        var after = AlertDispatcher(
            cooldown: 900,
            lastNotified: before.notificationHistory,
            lastSeverity: before.severityHistory)
        let notified = after.dispatch(
            [alert(.absenceHeadroom, .critical)], now: start.addingTimeInterval(300))
        #expect(notified.count == 1)
    }

    @Test("escalation bypasses the cooldown")
    func escalation() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.keyExpiry, .warning)], now: start)
        let notified = dispatcher.dispatch(
            [alert(.keyExpiry, .critical)], now: start.addingTimeInterval(10))
        #expect(notified.count == 1)
        #expect(notified.first?.severity == .critical)
    }

    @Test("de-escalation does not notify")
    func deescalation() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.keyExpiry, .critical)], now: start)
        #expect(
            dispatcher.dispatch([alert(.keyExpiry, .warning)], now: start.addingTimeInterval(10))
                .isEmpty)
    }

    /// A condition sitting exactly on a threshold would otherwise notify on
    /// every poll by clearing and immediately re-firing.
    @Test("flapping cannot notify more often than the cooldown")
    func flapping() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert()], now: start)
        for step in 1...10 {
            let at = start.addingTimeInterval(Double(step) * 30)
            _ = dispatcher.dispatch([], now: at)  // The alert clears.
            #expect(dispatcher.dispatch([alert()], now: at).isEmpty)  // It returns at once.
        }
    }

    /// Escalation must survive a clear. Without a remembered severity, a
    /// warning that cleared and returned as critical inside the cooldown
    /// notifies nobody, which defeats the escalation bypass entirely.
    @Test("escalation still notifies after the condition briefly cleared")
    func escalationSurvivesClear() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.absenceHeadroom, .warning)], now: start)

        // Recovers two minutes later.
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(120))

        // Returns as critical three minutes after that, well inside the
        // cooldown.
        let notified = dispatcher.dispatch(
            [alert(.absenceHeadroom, .critical)], now: start.addingTimeInterval(300))

        #expect(notified.count == 1)
        #expect(notified.first?.severity == .critical)
    }

    @Test("returning at the same severity inside the cooldown stays quiet")
    func sameSeverityAfterClearIsQuiet() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.absenceHeadroom, .warning)], now: start)
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(120))
        #expect(
            dispatcher.dispatch(
                [alert(.absenceHeadroom, .warning)], now: start.addingTimeInterval(300)
            ).isEmpty)
    }

    @Test("distinct alert ids are tracked independently")
    func independent() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.keyExpiry)], now: start)
        let notified = dispatcher.dispatch(
            [alert(.keyExpiry), alert(.notEarning)], now: start.addingTimeInterval(10))
        #expect(notified.map(\.id) == [.notEarning])
    }

    /// A countdown read through a noisy round-time estimate can sit on either
    /// side of a threshold from one poll to the next. Its first rise is
    /// announced; every later one only returns to what the user was told.
    @Test("a severity that wobbles across a threshold notifies its rise once")
    func wobbleNotifiesOnce() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.keyExpiry, .warning)], now: start)
        var notified = 0
        for step in 1...20 {
            let severity: AlertSeverity = step.isMultiple(of: 2) ? .warning : .critical
            let at = start.addingTimeInterval(Double(step) * 30)
            notified += dispatcher.dispatch([alert(.keyExpiry, severity)], now: at).count
        }
        #expect(notified == 1)
    }

    /// A condition counts as cleared only once it has stayed gone for the
    /// cooldown. A shorter gap is the condition wobbling on its threshold, and
    /// announcing each return would be exactly the noise the cooldown prevents.
    @Test("a condition notifies on its return only after staying gone for the cooldown")
    func returnAfterStayingGone() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        let offline = alert(.accountOffline, .critical)
        _ = dispatcher.dispatch([offline], now: start)
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(30))
        #expect(dispatcher.dispatch([offline], now: start.addingTimeInterval(600)).isEmpty)
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(630))
        #expect(dispatcher.dispatch([offline], now: start.addingTimeInterval(1_200)).isEmpty)
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(1_230))
        #expect(dispatcher.dispatch([offline], now: start.addingTimeInterval(2_200)).count == 1)
    }

    /// A key countdown near fourteen days can drop in and out of its warning
    /// from one poll to the next for as long as the estimate needs to settle.
    @Test("a condition that wobbles in and out for hours notifies once")
    func longWobbleNotifiesOnce() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        var notified = 0
        for step in 0..<240 {
            let at = start.addingTimeInterval(Double(step) * 30)
            notified += dispatcher.dispatch(step.isMultiple(of: 2) ? [alert()] : [], now: at).count
        }
        #expect(notified == 1)
    }

    /// A failed fetch says nothing about whether a condition cleared. Counting
    /// it as cleared would announce the alert afresh after every blip.
    @Test("only an evaluated account can clear its alerts")
    func onlyEvaluatedAccountsClear() {
        let first = ChainPollerTests.filledAddress(0x21)
        let second = ChainPollerTests.filledAddress(0x22)
        let both: Set<AlgorandAddress?> = [first, second, nil]
        let offline = HealthAlert(
            id: .accountOffline, address: second, severity: .critical, title: "t", body: "b")
        let later = start.addingTimeInterval(1_000)

        var failedFetch = AlertDispatcher(cooldown: 900)
        _ = failedFetch.dispatch([offline], evaluated: both, now: start)
        _ = failedFetch.dispatch([], evaluated: [first, nil], now: start.addingTimeInterval(30))
        #expect(failedFetch.dispatch([offline], evaluated: both, now: later).isEmpty)

        var cleared = AlertDispatcher(cooldown: 900)
        _ = cleared.dispatch([offline], evaluated: both, now: start)
        _ = cleared.dispatch([], evaluated: both, now: start.addingTimeInterval(30))
        #expect(cleared.dispatch([offline], evaluated: both, now: later).count == 1)
    }

    /// An account whose fetch failed still gets its "data unavailable" alert
    /// dispatched. That alert must not make the account count as evaluated, or
    /// its other alerts would look cleared and be announced again on its
    /// return.
    @Test("an alert for an unevaluated account clears none of its others")
    func unevaluatedAlertClearsNothing() {
        let first = ChainPollerTests.filledAddress(0x21)
        let second = ChainPollerTests.filledAddress(0x22)
        let both: Set<AlgorandAddress?> = [first, second, nil]
        let offline = HealthAlert(
            id: .accountOffline, address: second, severity: .critical, title: "t", body: "b")
        let unavailable = HealthAlert(
            id: .accountDataUnavailable, address: second, severity: .warning, title: "t",
            body: "b")

        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([offline], evaluated: both, now: start)
        let failing = dispatcher.dispatch(
            [unavailable], evaluated: [first, nil], now: start.addingTimeInterval(200))
        #expect(failing.map(\.id) == [.accountDataUnavailable])
        #expect(
            dispatcher.dispatch([offline], evaluated: both, now: start.addingTimeInterval(2_000))
                .isEmpty)
    }

    /// Relaunching, or rebuilding the poller after a Settings edit, must not
    /// announce afresh a condition the user was already told about.
    @Test("a restored notification counts as still holding")
    func restoredCountsAsHolding() {
        let offline = alert(.accountOffline, .critical)
        var dispatcher = AlertDispatcher(
            cooldown: 900, lastNotified: [offline.key: start],
            lastSeverity: [offline.key: .critical])
        #expect(dispatcher.dispatch([offline], now: start.addingTimeInterval(7_200)).isEmpty)
    }

    @Test("reminder intervals follow the rule and its severity")
    func reminderIntervals() {
        let dispatcher = AlertDispatcher(cooldown: 900)
        let expected: [(AlertID, AlertSeverity, TimeInterval?)] = [
            (.challengeFailing, .critical, 900),
            (.absenceHeadroom, .critical, 900),
            (.absenceHeadroom, .warning, 3_600),
            (.chainSourceUnreachable, .warning, 3_600),
            (.accountDataUnavailable, .warning, 3_600),
            (.keyExpiry, .critical, 21_600),
            (.keyExpiry, .warning, 86_400),
            (.accountOffline, .critical, nil),
            (.notEarning, .warning, nil),
            (.balanceOutOfRange, .warning, nil),
        ]
        for (id, severity, interval) in expected {
            #expect(dispatcher.reminderInterval(for: alert(id, severity)) == interval)
        }
    }
}

@Suite("Rewards tracker")
struct RewardsTrackerTests {
    let now = Date(timeIntervalSince1970: 1_786_600_000)

    func block(_ round: UInt64, hoursAgo: Double, payout: UInt64?) -> IndexerClient.ProposedBlock {
        let json = """
            {"round":\(round),"timestamp":\(Int64(now.timeIntervalSince1970 - hoursAgo * 3_600)),\
            "proposer":"A"\(payout.map { ",\"proposer-payout\":\($0)" } ?? "")}
            """
        return try! JSONDecoder().decode(IndexerClient.ProposedBlock.self, from: Data(json.utf8))
    }

    @Test("splits proposals across the 24h and 7d windows")
    func windows() {
        var tracker = RewardsTracker()
        tracker.ingest(
            [
                block(1, hoursAgo: 2, payout: 8_000_000),
                block(2, hoursAgo: 20, payout: 8_000_000),
                block(3, hoursAgo: 50, payout: 8_000_000),
                // 8.3 days ago: inside the fetch window, outside the 7 days.
                block(4, hoursAgo: 200, payout: 8_000_000),
            ], windowStartRound: 0)

        let summary = tracker.summary(now: now)
        #expect(summary.proposals24h == 2)
        #expect(summary.proposals7d == 3)
        #expect(summary.earned24h == MicroAlgos(16_000_000))
        #expect(summary.earned7d == MicroAlgos(24_000_000))
    }

    /// A proposal that paid nothing is the visible symptom of an ineligible
    /// account, so it is counted rather than folded into a zero.
    @Test("counts proposals that earned nothing")
    func unpaid() {
        var tracker = RewardsTracker()
        tracker.ingest(
            [
                block(1, hoursAgo: 1, payout: 8_000_000),
                block(2, hoursAgo: 2, payout: nil),
                block(3, hoursAgo: 3, payout: 0),
            ], windowStartRound: 0)

        let summary = tracker.summary(now: now)
        #expect(summary.unpaidProposals == 2)
        #expect(summary.proposals24h == 3)
    }

    @Test("re-ingesting the same rounds does not double count")
    func dedup() {
        var tracker = RewardsTracker()
        let blocks = [
            block(1, hoursAgo: 1, payout: 8_000_000), block(2, hoursAgo: 2, payout: 8_000_000),
        ]
        tracker.ingest(blocks, windowStartRound: 0)
        tracker.ingest(blocks, windowStartRound: 0)
        #expect(tracker.count == 2)
        #expect(tracker.summary(now: now).earned24h == MicroAlgos(16_000_000))
    }

    /// The cache holds the window being fetched, rather than every block seen
    /// since launch.
    @Test("advancing the window drops rounds that fall outside it")
    func pruning() {
        var tracker = RewardsTracker()
        tracker.ingest(
            [
                block(100, hoursAgo: 200, payout: 8_000_000),
                block(500, hoursAgo: 2, payout: 8_000_000),
            ], windowStartRound: 0)
        #expect(tracker.count == 2)

        tracker.ingest([], windowStartRound: 400)
        #expect(tracker.count == 1)
        #expect(tracker.highestRound == 500)
    }

    /// The newest cached round is what lets the poller resume an incremental
    /// fetch past what it already holds.
    @Test("tracks the newest cached round")
    func highestRound() {
        var tracker = RewardsTracker()
        #expect(tracker.highestRound == nil)
        tracker.ingest(
            [
                block(10, hoursAgo: 50, payout: 1),
                block(90, hoursAgo: 1, payout: 1),
                block(50, hoursAgo: 20, payout: 1),
            ], windowStartRound: 0)
        #expect(tracker.highestRound == 90)
    }

    /// A round past the chain's own latest is early at best and corrupt at
    /// worst. Kept, a corrupt one would become the resume point and hide every
    /// real proposal after it.
    @Test("drops blocks past the latest round")
    func dropsFutureRounds() {
        var tracker = RewardsTracker()
        tracker.ingest(
            [
                block(10, hoursAgo: 1, payout: 1),
                block(5_000_000, hoursAgo: 1, payout: 1),
                block(.max, hoursAgo: 1, payout: 1),
            ], windowStartRound: 0, latestRound: 1_000)
        #expect(tracker.count == 1)
        #expect(tracker.highestRound == 10)
    }

    @Test("an empty tracker summarises to zero, not nil")
    func empty() {
        let summary = RewardsTracker().summary(now: now)
        #expect(summary.proposals7d == 0)
        #expect(summary.earned7d == .zero)
    }
}
