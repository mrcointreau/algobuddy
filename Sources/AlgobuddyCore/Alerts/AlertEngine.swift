import Foundation

public enum AlertSeverity: Int, Sendable, Comparable {
    case info, warning, critical

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AlertID: String, Sendable, CaseIterable, Codable {
    /// The configured chain data source. algobuddy holds no separate connection to the user's
    /// own node, so there is no "node unreachable" counterpart.
    case chainSourceUnreachable
    case accountOffline
    case challengeFailing
    case absenceHeadroom
    case keyExpiry
    case notEarning
    case balanceOutOfRange
}

/// Formats a number with its unit, agreeing in number: "1 minute", not
/// "1 minutes". Only a value that formats as exactly "1" takes the singular, so
/// "1.0 days" stays plural, which is what English expects of a decimal.
public func quantity(_ value: Double, _ unit: String, decimals: Int = 0) -> String {
    let text = String(format: "%.\(decimals)f", value)
    return text == "1" ? "\(text) \(unit)" : "\(text) \(unit)s"
}

/// What a cooldown is held against: the rule, and the account it holds for.
///
/// Both halves are needed. Several accounts can be watched at once and every
/// rule applies to each of them, so keying on the rule alone would let one
/// account's notification silence another account's first alert of the same
/// kind for the whole cooldown.
public struct AlertKey: Hashable, Sendable {
    /// Nil for the alerts that are about the watch itself rather than about one
    /// account, such as the chain data source being unreachable.
    public let address: AlgorandAddress?
    public let id: AlertID

    public init(address: AlgorandAddress?, id: AlertID) {
        self.address = address
        self.id = id
    }

    /// The key as a single string, for callers that persist cooldowns in a
    /// store with string keys. `init(storageKey:)` reads it back. The separator
    /// appears in neither half: an address is base32 and a rule name is
    /// alphanumeric.
    public var storageKey: String { "\(address?.stringValue ?? "")|\(id.rawValue)" }

    /// Nil when the string was not written by `storageKey`, or names a rule or
    /// an address this version cannot make sense of. A cooldown that cannot be
    /// read is dropped rather than guessed at, which at worst re-announces a
    /// condition that still holds.
    public init?(storageKey: String) {
        let parts = storageKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = AlertID(rawValue: String(parts[1])) else { return nil }
        if parts[0].isEmpty {
            self.init(address: nil, id: id)
        } else if let address = try? AlgorandAddress(String(parts[0])) {
            self.init(address: address, id: id)
        } else {
            return nil
        }
    }
}

public struct HealthAlert: Sendable, Equatable, Identifiable {
    public let id: AlertID
    /// The account the alert holds for, nil when it is about the watch itself.
    public let address: AlgorandAddress?
    public let severity: AlertSeverity
    public let title: String
    public let body: String

    public init(
        id: AlertID,
        address: AlgorandAddress? = nil,
        severity: AlertSeverity,
        title: String,
        body: String
    ) {
        self.id = id
        self.address = address
        self.severity = severity
        self.title = title
        self.body = body
    }

    public var key: AlertKey { AlertKey(address: address, id: id) }

    /// The same alert, attributed to an account. The rules derive alerts from
    /// thresholds alone, so the account is attached once on the way out rather
    /// than repeated at every construction site.
    func held(for address: AlgorandAddress?) -> HealthAlert {
        HealthAlert(id: id, address: address, severity: severity, title: title, body: body)
    }
}

/// Everything the alert rules read.
///
/// The chain-derived fields are optional because a poll can fail or an account can lack
/// participation keys; rules whose inputs are missing simply do not fire.
public struct Snapshot: Sendable {
    public var roundTime: TimeInterval
    public var params: ConsensusParams
    /// The account the snapshot describes. Every alert it produces is stamped
    /// with this, so the cooldowns of one watched account stay its own.
    public var address: AlgorandAddress?
    public var account: AccountState?
    public var absence: AbsenceAssessment?
    public var challenge: ChallengeState?
    public var keyExpiry: KeyExpiry?

    public init(
        roundTime: TimeInterval = 2.8,
        params: ConsensusParams = .v40,
        address: AlgorandAddress? = nil,
        account: AccountState? = nil,
        absence: AbsenceAssessment? = nil,
        challenge: ChallengeState? = nil,
        keyExpiry: KeyExpiry? = nil
    ) {
        self.roundTime = roundTime
        self.params = params
        self.address = address
        self.account = account
        self.absence = absence
        self.challenge = challenge
        self.keyExpiry = keyExpiry
    }
}

public struct AlertThresholds: Sendable {
    /// Rounds of grace remaining below which an unanswered challenge becomes
    /// critical.
    ///
    /// A challenge is issued every 1000 rounds and answered by the node's own
    /// heartbeat. Treating the whole grace period as critical would raise the
    /// app's most severe alert roughly once a day on a healthy node and then
    /// withdraw it minutes later, which teaches people to ignore the one signal
    /// that matters. Reserving it for the tail of the window means an account
    /// still silent here is one whose node is genuinely not answering.
    public var challengeUrgentRounds: UInt64 = 60
    public var keyExpiryWarningDays: Double = 14
    public var keyExpiryCriticalDays: Double = 3
    public var absenceWarningRatio: Double = 0.5
    public var absenceCriticalRatio: Double = 0.8

    public init() {}
}

/// Pure evaluation: a snapshot in, the alerts that currently hold out.
///
/// Deliberately stateless. Debouncing, cooldowns and "fire once per event"
/// behaviour belong to the caller, which owns the clock. Keeping this function
/// pure is what makes every rule testable against a fixture.
public struct AlertEngine: Sendable {
    public var thresholds: AlertThresholds

    public init(thresholds: AlertThresholds = AlertThresholds()) {
        self.thresholds = thresholds
    }

    public func evaluate(_ snapshot: Snapshot) -> [HealthAlert] {
        var alerts = [HealthAlert]()
        alerts.append(contentsOf: participationAlerts(snapshot))
        return alerts.map { $0.held(for: snapshot.address) }.sorted { $0.severity > $1.severity }
    }

    /// Every alert follows one shape: the title names the condition, and the body states the
    /// consequence, then the action where the reader has one.
    private func participationAlerts(_ snapshot: Snapshot) -> [HealthAlert] {
        var alerts = [HealthAlert]()

        // An account that is already Offline cannot be warned about suspension,
        // and its keys and challenges no longer matter. Suppress the lot and say
        // the one thing that is true.
        if snapshot.account?.status == .offline {
            return [
                HealthAlert(
                    id: .accountOffline, severity: .critical,
                    title: "Account is offline",
                    body:
                        "It is not participating and earns nothing. Register it online again with a keyreg transaction."
                )
            ]
        }
        guard snapshot.account?.status != .notParticipating else { return [] }

        if let challenge = snapshot.challenge, challenge.isFailing {
            let seconds = challenge.timeUntilDeadline(roundTime: snapshot.roundTime)
            let remaining = UInt64(max(0, challenge.roundsUntilDeadline))

            if challenge.phase == .enforcing {
                alerts.append(
                    HealthAlert(
                        id: .challengeFailing, severity: .critical,
                        title: "Challenge expired",
                        body:
                            "The account can be suspended at any block. Check the node is running."
                    ))
            } else if remaining <= thresholds.challengeUrgentRounds {
                alerts.append(
                    HealthAlert(
                        id: .challengeFailing, severity: .critical,
                        title: "Challenge not answered",
                        body:
                            "The account is suspended in about \(quantity(max(1, seconds / 60), "minute")) unless it answers. Check the node is running."
                    ))
            }
            // Earlier in the grace period an unanswered challenge is ordinary:
            // the node has not had time to respond yet. The panel shows the
            // countdown; nothing is raised.
        }

        if let absence = snapshot.absence {
            let days = absence.headroom(roundTime: snapshot.roundTime) / 86_400
            if absence.isAbsent {
                alerts.append(
                    HealthAlert(
                        id: .absenceHeadroom, severity: .critical,
                        title: "Absence limit passed",
                        body:
                            "The account can be suspended at any block. Check the node is running."
                    ))
            } else if absence.ratio >= thresholds.absenceCriticalRatio {
                alerts.append(
                    HealthAlert(
                        id: .absenceHeadroom, severity: .critical,
                        title: "Absence limit near",
                        body:
                            "The account can be suspended in about \(quantity(days, "day", decimals: 1)). Check the node is proposing."
                    ))
            } else if absence.ratio >= thresholds.absenceWarningRatio {
                alerts.append(
                    HealthAlert(
                        id: .absenceHeadroom, severity: .warning,
                        title: "Absence headroom low",
                        body:
                            "The account can be suspended in about \(quantity(days, "day", decimals: 1)). Check the node is proposing."
                    ))
            }
        }

        if let expiry = snapshot.keyExpiry {
            let days = expiry.timeRemaining(roundTime: snapshot.roundTime) / 86_400
            if expiry.hasExpired {
                alerts.append(
                    HealthAlert(
                        id: .keyExpiry, severity: .critical,
                        title: "Participation keys expired",
                        body:
                            "The account has stopped participating. Generate new keys and register them."
                    ))
            } else if days <= thresholds.keyExpiryCriticalDays {
                alerts.append(
                    HealthAlert(
                        id: .keyExpiry, severity: .critical,
                        title: "Participation keys expiring",
                        body:
                            "They expire in about \(quantity(days, "day", decimals: 1)), after which the account stops participating. Generate new keys and register them."
                    ))
            } else if days <= thresholds.keyExpiryWarningDays {
                alerts.append(
                    HealthAlert(
                        id: .keyExpiry, severity: .warning,
                        title: "Participation keys expiring",
                        body:
                            "They expire in about \(quantity(days, "day")), after which the account stops participating. Generate new keys and register them."
                    ))
            }
        }

        if let account = snapshot.account, account.status == .online {
            // `!= true`, not `== false`: algod omits `incentive-eligible` from
            // the response entirely when it is false, so against a real node
            // the not-eligible case decodes as nil and a strict `== false`
            // comparison would never fire. Absent means not eligible.
            if account.incentiveEligible != true {
                alerts.append(
                    HealthAlert(
                        id: .notEarning, severity: .warning,
                        title: "Account is not incentive-eligible",
                        body:
                            "Proposing a block pays nothing. A keyreg transaction with the eligibility fee restores it."
                    ))
            }
            if !snapshot.params.isBalanceEligible(account.amount) {
                alerts.append(
                    HealthAlert(
                        id: .balanceOutOfRange, severity: .warning,
                        title: "Balance outside the payout window",
                        body:
                            "Proposing a block pays nothing. Payouts require a balance between \(snapshot.params.minBalance) and \(snapshot.params.maxBalance)."
                    ))
            }
        }

        return alerts
    }
}
