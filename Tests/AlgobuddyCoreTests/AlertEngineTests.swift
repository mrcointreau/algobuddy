import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Alert engine")
struct AlertEngineTests {
    let engine = AlertEngine()

    func account(
        status: AccountState.Status = .online,
        amount: UInt64 = 149_734_756_595,
        eligible: Bool? = true
    ) -> AccountState {
        AccountState(
            address: "ADDR", status: status, amount: MicroAlgos(amount), round: 1_000,
            incentiveEligible: eligible, lastProposed: 990, lastHeartbeat: 900,
            participation: nil)
    }

    /// The first thing the engine must get right: with nothing fetched yet, it
    /// reports nothing rather than inventing a problem.
    @Test("an empty snapshot produces no alerts")
    func empty() {
        #expect(engine.evaluate(Snapshot()).isEmpty)
    }

    // MARK: - Challenge

    func challenge(
        remaining: Int64,
        challenged: Bool = true,
        answered: Bool = false
    ) -> ChallengeState {
        ChallengeState(
            challengeRound: 64_030_000,
            isChallenged: challenged, hasAnswered: answered,
            roundsUntilDeadline: remaining)
    }

    /// A challenge is issued roughly once a day and the node answers it from its
    /// own heartbeat. Alerting for the whole window would fire daily on a healthy
    /// node and then withdraw itself, which is how an alarm gets ignored.
    @Test("an unanswered challenge with grace remaining stays quiet")
    func challengeEarlyInGraceIsQuiet() {
        #expect(engine.evaluate(Snapshot(challenge: challenge(remaining: 150))).isEmpty)
        #expect(engine.evaluate(Snapshot(challenge: challenge(remaining: 97))).isEmpty)
        // One round above the threshold, still quiet.
        #expect(engine.evaluate(Snapshot(challenge: challenge(remaining: 61))).isEmpty)
    }

    @Test("it escalates once the node has missed its usual window")
    func challengeNearDeadlineIsCritical() {
        let alert = engine.evaluate(Snapshot(challenge: challenge(remaining: 60)))
            .first { $0.id == .challengeFailing }
        #expect(alert?.severity == .critical)
        #expect(alert?.body.contains("minutes") == true)
    }

    /// Units agree in number. "1 minutes" in the one alert that fires with
    /// minutes left reads as a placeholder someone forgot to finish.
    @Test("a single unit is singular")
    func singularUnits() {
        let alert = engine.evaluate(Snapshot(challenge: challenge(remaining: 20)))
            .first { $0.id == .challengeFailing }
        #expect(alert?.body.contains("about 1 minute unless") == true)

        #expect(quantity(1, "day", decimals: 1) == "1.0 days")
        #expect(quantity(0, "minute") == "0 minutes")
        #expect(quantity(2.4, "day") == "2 days")
    }

    @Test("past the grace period it is critical and says suspension is possible")
    func challengeEnforcing() {
        let alert = engine.evaluate(
            Snapshot(challenge: challenge(remaining: -300))
        ).first { $0.id == .challengeFailing }
        #expect(alert?.severity == .critical)
        #expect(alert?.body.contains("suspended") == true)
    }

    @Test("an answered challenge is silent at any point in the window")
    func challengeAnswered() {
        #expect(
            engine.evaluate(Snapshot(challenge: challenge(remaining: 5, answered: true))).isEmpty)
        #expect(
            engine.evaluate(
                Snapshot(challenge: challenge(remaining: -300, answered: true))
            ).isEmpty)
    }

    @Test("an unselected account is never challenged, however stale")
    func challengeNotSelected() {
        #expect(
            engine.evaluate(Snapshot(challenge: challenge(remaining: -900, challenged: false)))
                .isEmpty)
    }

    // MARK: - Absence

    @Test("absence headroom escalates by ratio")
    func absence() {
        func assessment(ratio: Double, absent: Bool = false) -> AbsenceAssessment {
            AbsenceAssessment(
                allowableLag: 252_022,
                roundsSinceLastSeen: UInt64(252_022.0 * ratio),
                headroomRounds: Int64(252_022.0 * (1 - ratio)),
                ratio: ratio, isAbsent: absent)
        }
        #expect(engine.evaluate(Snapshot(absence: assessment(ratio: 0.1))).isEmpty)
        #expect(
            engine.evaluate(Snapshot(absence: assessment(ratio: 0.6)))
                .first { $0.id == .absenceHeadroom }?.severity == .warning)
        #expect(
            engine.evaluate(Snapshot(absence: assessment(ratio: 0.9)))
                .first { $0.id == .absenceHeadroom }?.severity == .critical)
        #expect(
            engine.evaluate(Snapshot(absence: assessment(ratio: 1.2, absent: true)))
                .first { $0.id == .absenceHeadroom }?.severity == .critical)
    }

    // MARK: - Key expiry

    @Test("key expiry escalates as the window closes")
    func keyExpiry() {
        func expiry(days: Double) -> KeyExpiry {
            let rounds = UInt64(days * 86_400 / 2.8)
            return KeyExpiry(
                participation: .init(
                    voteFirstValid: 0, voteLastValid: 1_000_000 + rounds, voteKeyDilution: 1),
                currentRound: 1_000_000)
        }
        #expect(engine.evaluate(Snapshot(keyExpiry: expiry(days: 60))).isEmpty)
        #expect(
            engine.evaluate(Snapshot(keyExpiry: expiry(days: 10)))
                .first { $0.id == .keyExpiry }?.severity == .warning)
        #expect(
            engine.evaluate(Snapshot(keyExpiry: expiry(days: 2)))
                .first { $0.id == .keyExpiry }?.severity == .critical)
    }

    @Test("expired keys are critical regardless of the countdown")
    func keyExpired() {
        let expiry = KeyExpiry(
            participation: .init(voteFirstValid: 1, voteLastValid: 100, voteKeyDilution: 1),
            currentRound: 500)
        let alert = engine.evaluate(Snapshot(keyExpiry: expiry)).first { $0.id == .keyExpiry }
        #expect(alert?.severity == .critical)
        #expect(alert?.title.contains("expired") == true)
    }

    // MARK: - Eligibility

    @Test("online but not incentive-eligible warns")
    func notEarning() {
        #expect(
            engine.evaluate(Snapshot(account: account(eligible: false)))
                .contains { $0.id == .notEarning })
        #expect(
            !engine.evaluate(Snapshot(account: account(eligible: true)))
                .contains { $0.id == .notEarning })
    }

    /// algod omits `incentive-eligible` from the response entirely when it is
    /// false, so nil is the wire representation of "not eligible" and must warn
    /// exactly like an explicit false.
    @Test("a missing eligibility field warns like an explicit false")
    func notEarningWhenFieldAbsent() {
        #expect(
            engine.evaluate(Snapshot(account: account(eligible: nil)))
                .contains { $0.id == .notEarning })
    }

    @Test(
        "balance outside the payout window warns",
        arguments: [
            UInt64(29_999_000_000),  // just under 30,000 ALGO
            UInt64(70_000_000_000_001),  // just over 70M ALGO
        ])
    func balanceRange(amount: UInt64) {
        #expect(
            engine.evaluate(Snapshot(account: account(amount: amount)))
                .contains { $0.id == .balanceOutOfRange })
    }

    /// Suspension is the event this app exists to catch, so an Offline account
    /// has to raise something rather than only colouring a dot in the panel.
    @Test("an offline account raises one critical alert")
    func offlineAlerts() {
        let alerts = engine.evaluate(Snapshot(account: account(status: .offline)))
        #expect(alerts.map(\.id) == [.accountOffline])
        #expect(alerts.first?.severity == .critical)
    }

    /// Warning that an already-Offline account may be suspended is a
    /// contradiction, and its keys and challenges no longer matter either.
    @Test("an offline account is not also warned about suspension or keys")
    func offlineSuppressesTheRest() {
        let expiry = KeyExpiry(
            participation: .init(voteFirstValid: 1, voteLastValid: 100, voteKeyDilution: 1),
            currentRound: 500)
        let absence = AbsenceAssessment(
            allowableLag: 252_022, roundsSinceLastSeen: 240_000,
            headroomRounds: 12_022, ratio: 0.95, isAbsent: false)

        let alerts = engine.evaluate(
            Snapshot(
                account: account(status: .offline, amount: 1, eligible: false),
                absence: absence,
                challenge: challenge(remaining: 10),
                keyExpiry: expiry))

        #expect(alerts.map(\.id) == [.accountOffline])
    }

    @Test("a not-participating account raises nothing")
    func notParticipatingIsQuiet() {
        #expect(
            engine.evaluate(
                Snapshot(account: account(status: .notParticipating, amount: 1, eligible: false))
            ).isEmpty)
    }

    // MARK: - Ordering

    @Test("alerts are ordered most severe first")
    func ordering() {
        let alerts = engine.evaluate(
            Snapshot(
                account: account(amount: 1, eligible: false),
                challenge: challenge(remaining: 10)))

        #expect(alerts.count >= 3)
        #expect(alerts.first?.severity == .critical)
        #expect(zip(alerts, alerts.dropFirst()).allSatisfy { $0.severity >= $1.severity })
    }
}
