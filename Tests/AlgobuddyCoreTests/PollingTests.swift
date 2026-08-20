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
        // One round after an hour: a stalled chain, not a round time.
        clock.observe(round: 1_001, at: start.addingTimeInterval(3_600))
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

    @Test("it notifies again once the cooldown lapses")
    func refires() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert()], now: start)
        #expect(dispatcher.dispatch([alert()], now: start.addingTimeInterval(901)).count == 1)
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
            _ = dispatcher.dispatch([], now: at)  // clears
            #expect(dispatcher.dispatch([alert()], now: at).isEmpty)  // and returns
        }
    }

    /// Escalation must survive a clear. Without a remembered severity, a warning
    /// that cleared and returned as critical inside the cooldown notifies
    /// nobody, which defeats the escalation bypass entirely.
    @Test("escalation still notifies after the condition briefly cleared")
    func escalationSurvivesClear() {
        var dispatcher = AlertDispatcher(cooldown: 900)
        _ = dispatcher.dispatch([alert(.absenceHeadroom, .warning)], now: start)

        // Recovers two minutes later.
        _ = dispatcher.dispatch([], now: start.addingTimeInterval(120))

        // Returns as critical three minutes after that, well inside the cooldown.
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
                block(4, hoursAgo: 200, payout: 8_000_000),  // 8.3 days, inside the
            ], windowStartRound: 0)  // fetch window, outside 7d

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

    /// Otherwise "in window" would quietly accumulate history from wider
    /// earlier fetches and stop meaning what its name says.
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
        #expect(tracker.windowStartRound == 400)
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

    @Test("an empty tracker summarises to zero, not nil")
    func empty() {
        let summary = RewardsTracker().summary(now: now)
        #expect(summary.proposals7d == 0)
        #expect(summary.earned7d == .zero)
    }
}
