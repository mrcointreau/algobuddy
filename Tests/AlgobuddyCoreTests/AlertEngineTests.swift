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

    /// Below a day, a count of days to one decimal reads "about 0.0 days" with
    /// most of an hour left, so the bodies move to hours, then to minutes.
    @Test("a deadline under a day is stated in hours or minutes")
    func shortDeadlinesUseSmallerUnits() {
        let absence = AbsenceAssessment(
            allowableLag: 10_000, roundsSinceLastSeen: 9_057, headroomRounds: 943,
            ratio: 0.9057, isAbsent: false)
        let near = engine.evaluate(Snapshot(absence: absence)).first { $0.id == .absenceHeadroom }
        #expect(near?.body.contains("about 44 minutes") == true)

        func expiry(seconds: Double) -> KeyExpiry {
            KeyExpiry(
                participation: .init(
                    voteFirstValid: 0, voteLastValid: 1_000_000 + UInt64(seconds / 2.8),
                    voteKeyDilution: 1),
                currentRound: 1_000_000)
        }
        let hours = engine.evaluate(Snapshot(keyExpiry: expiry(seconds: 5 * 3_600)))
            .first { $0.id == .keyExpiry }
        #expect(hours?.body.contains("about 5 hours") == true)
        let days = engine.evaluate(Snapshot(keyExpiry: expiry(seconds: 2.5 * 86_400)))
            .first { $0.id == .keyExpiry }
        #expect(days?.body.contains("about 2.5 days") == true)
    }

    @Test("a duration is told in days, then hours, then minutes, never fewer than one")
    func durationUnits() {
        #expect(duration(2.5 * 86_400) == "2.5 days")
        #expect(duration(86_400) == "1.0 days")
        #expect(duration(5 * 3_600) == "5 hours")
        #expect(duration(3_600) == "1 hour")
        #expect(duration(44 * 60) == "44 minutes")
        #expect(duration(20) == "1 minute")
    }

    /// New keys vote only once the balance lookback has passed since their
    /// registration, so the critical alert says how early to register them,
    /// and once that is no longer possible, how long the account goes without.
    @Test("the critical key alert says to register new keys 320 rounds ahead")
    func criticalKeysNameTheLookback() {
        func alert(roundsLeft: UInt64, roundTime: TimeInterval = 2.8) -> HealthAlert? {
            let expiry = KeyExpiry(
                participation: .init(
                    voteFirstValid: 0, voteLastValid: 1_000_000 + roundsLeft, voteKeyDilution: 1),
                currentRound: 1_000_000)
            return engine.evaluate(Snapshot(roundTime: roundTime, keyExpiry: expiry))
                .first { $0.id == .keyExpiry }
        }
        // 2.5 days ahead: the lead is given in rounds and in time.
        let early = alert(roundsLeft: 77_142)
        #expect(early?.severity == .critical)
        #expect(early?.body.contains("320 rounds (about 15 minutes)") == true)
        #expect(early?.body.contains("at least that long before these expire") == true)
        // The time follows the round clock: 320 rounds of 3.6 s are 19 minutes.
        let slower = alert(roundsLeft: 50_000, roundTime: 3.6)
        #expect(slower?.body.contains("about 19 minutes") == true)
        // Exactly the lookback left: registered now, the new keys take over as
        // the old ones end.
        #expect(alert(roundsLeft: 320)?.body.contains("at least that long") == true)
        // Fewer rounds left than that: 120 rounds of 2.8 s go without keys.
        let late = alert(roundsLeft: 200)
        #expect(late?.body.contains("register them now: even then") == true)
        #expect(late?.body.contains("no keys in effect for about 6 minutes") == true)
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

    /// "Earning" on a card or a row has to agree with the alerts beside it: it
    /// holds exactly when neither eligibility alert does.
    @Test("earning means Online, eligible and inside the payout window, as the alerts do")
    func earningMatchesTheAlerts() {
        let cases: [(AccountState, Bool)] = [
            (account(), true),
            (account(eligible: false), false),
            (account(eligible: nil), false),
            (account(amount: 29_999_000_000), false),
            (account(amount: 70_000_000_000_001), false),
            (account(status: .offline), false),
        ]
        for (account, earns) in cases {
            #expect(account.earnsPayouts() == earns)
            guard account.status == .online else { continue }
            let alerts = engine.evaluate(Snapshot(account: account)).map(\.id)
            #expect(earns == !(alerts.contains(.notEarning) || alerts.contains(.balanceOutOfRange)))
        }
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

    // MARK: - One account's alerts

    func alert(_ id: AlertID, for address: AlgorandAddress?) -> HealthAlert {
        HealthAlert(id: id, address: address, severity: .warning, title: "", body: "")
    }

    var watched: (first: AlgorandAddress, second: AlgorandAddress) {
        let keys = ([UInt8](repeating: 0x11, count: 32), [UInt8](repeating: 0x22, count: 32))
        func address(_ key: [UInt8]) -> AlgorandAddress {
            try! AlgorandAddress(Base32.encode(key + SHA512_256.hash(key).suffix(4)))
        }
        return (address(keys.0), address(keys.1))
    }

    @Test("an account's own alerts leave out every other account's")
    func ownAlertsOnly() {
        let (first, second) = watched
        let alerts = [
            alert(.keyExpiry, for: first), alert(.accountOffline, for: second),
            alert(.chainSourceUnreachable, for: nil),
        ]

        #expect(alerts.about(first, includingWatchAlerts: false).map(\.id) == [.keyExpiry])
    }

    /// A source outage holds for every account at once, so a page about any
    /// one of them must still say so.
    @Test("watch alerts are included only when asked for")
    func watchAlertsOnRequest() {
        let (first, second) = watched
        let alerts = [
            alert(.chainSourceUnreachable, for: nil), alert(.keyExpiry, for: first),
            alert(.accountOffline, for: second),
        ]

        #expect(
            alerts.about(first, includingWatchAlerts: true).map(\.id)
                == [.chainSourceUnreachable, .keyExpiry])
        #expect(alerts.about(second, includingWatchAlerts: false).map(\.id) == [.accountOffline])
    }
}

/// The storage key is the only way persisted cooldowns come back after a
/// relaunch, so a key that fails to read back silently drops all of them, and
/// every condition still holding is announced again.
@Suite("Alert keys")
struct AlertKeyTests {
    let address = try! AlgorandAddress(
        "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ")

    @Test("every rule reads back, for an account and for the watch")
    func roundTrip() {
        for id in AlertID.allCases {
            for key in [AlertKey(address: address, id: id), AlertKey(address: nil, id: id)] {
                #expect(AlertKey(storageKey: key.storageKey) == key)
            }
        }
    }

    /// Each of these lacks a part that `storageKey` always writes, or names a
    /// rule or an address that does not exist.
    @Test("a string that storageKey did not write reads back as nil")
    func foreignStrings() {
        for text in ["", "keyExpiry", "|noSuchRule", "NOTANADDRESS|keyExpiry", "|keyExpiry|x"] {
            #expect(AlertKey(storageKey: text) == nil)
        }
    }

    /// Stable, so a reminder replaces the banner it follows; distinct per
    /// account and rule, so one account's banner never replaces another's;
    /// and free of the address, which the notification store would otherwise
    /// keep after the app's own preferences are gone.
    @Test("the notification identifier is stable, distinct and names no address")
    func notificationIdentifier() {
        let other = ChainPollerTests.filledAddress(0x31)
        let keys = [
            AlertKey(address: address, id: .keyExpiry),
            AlertKey(address: address, id: .accountOffline),
            AlertKey(address: other, id: .keyExpiry),
            AlertKey(address: nil, id: .chainSourceUnreachable),
        ]
        let identifiers = keys.map(\.notificationIdentifier)

        #expect(identifiers == keys.map(\.notificationIdentifier))
        #expect(Set(identifiers).count == keys.count)
        // A short lowercase digest has no room for a 58-character address.
        for identifier in identifiers {
            #expect(identifier.count == 24)
            #expect(identifier.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
}
