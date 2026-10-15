import Foundation

/// Decides which of the currently-holding alerts should actually interrupt the
/// user.
///
/// `AlertEngine.evaluate` is pure and re-derives every alert on every poll, so
/// without this a warning that holds for a day would fire 2,880 notifications.
/// Keeping the time-dependent state here is what lets the rules themselves stay
/// clock-free and fixture-testable.
public struct AlertDispatcher: Sendable, Equatable {
    /// How long a condition must stay gone before it counts as cleared, and
    /// before it can notify again on its return. A shorter gap is a condition
    /// wobbling on its threshold, so it keeps its place in the reminder
    /// schedule instead of being announced afresh on every poll.
    public var cooldown: TimeInterval

    private var lastNotified: [AlertKey: Date] = [:]
    /// The severity each alert last notified at. Escalation is measured against
    /// what the user was told rather than against the previous poll, so a
    /// severity that wobbles across a threshold announces the rise once.
    private var lastSeverity: [AlertKey: AlertSeverity] = [:]
    /// The alerts that held when their account was last evaluated.
    private var holding: Set<AlertKey> = []
    /// When each alert that held, or that a restored notification vouches for,
    /// was first found gone. Together with `holding`, this is what tells a
    /// condition that continues from one that cleared and came back.
    private var absentSince: [AlertKey: Date] = [:]
    /// The accounts evaluated since this dispatcher was created, nil standing
    /// for the watch itself. Until an account has been, its restored
    /// notifications count as still holding.
    private var everEvaluated: Set<AlgorandAddress?> = []
    private var evaluatedEverything = false

    /// - Parameters:
    ///   - lastNotified: Notification times persisted from an earlier run.
    ///     Seeding them keeps reminders on schedule across launches, so a
    ///     condition that holds for days is not announced afresh every time the
    ///     app starts.
    ///   - lastSeverity: The severities those notifications went out at.
    ///     Without them a warning that escalates to critical after a relaunch
    ///     would go unannounced, because escalation compares against the
    ///     severity last notified.
    public init(
        cooldown: TimeInterval = 900,
        lastNotified: [AlertKey: Date] = [:],
        lastSeverity: [AlertKey: AlertSeverity] = [:]
    ) {
        self.cooldown = cooldown
        self.lastNotified = lastNotified
        self.lastSeverity = lastSeverity
    }

    /// Notification times, for the caller to persist and hand back on relaunch.
    public var notificationHistory: [AlertKey: Date] { lastNotified }

    /// The severity each alert last notified at, persisted with
    /// `notificationHistory` so escalation detection survives a relaunch.
    public var severityHistory: [AlertKey: AlertSeverity] { lastSeverity }

    /// How long an alert that continues to hold waits before it notifies again.
    ///
    /// Nil means never: the condition was announced once, and the menu bar and
    /// the panel keep showing it for as long as it holds. A state such as an
    /// Offline account can last for months by choice, and repeating it would
    /// teach the user to silence every notification, the urgent ones included.
    /// Conditions that can cost money within minutes repeat at the cooldown.
    public func reminderInterval(for alert: HealthAlert) -> TimeInterval? {
        switch (alert.id, alert.severity) {
        case (.challengeFailing, _), (.absenceHeadroom, .critical): cooldown
        case (.absenceHeadroom, _), (.chainSourceUnreachable, _): 3_600
        case (.keyExpiry, .critical): 6 * 3_600
        case (.keyExpiry, _): 86_400
        case (.accountOffline, _), (.notEarning, _), (.balanceOutOfRange, _): nil
        }
    }

    /// Returns the subset of `alerts` to notify about now.
    ///
    /// An alert notifies when it first appears, when it rises above the
    /// severity it last notified at, when it comes back after staying gone for
    /// the cooldown, or when it has held for its reminder interval.
    ///
    /// - Parameter evaluated: The accounts whose alerts this call describes, nil
    ///   standing for the watch itself. An alert of an account that was not
    ///   evaluated, because its fetch failed, has not cleared. Nil means every
    ///   account was evaluated.
    public mutating func dispatch(
        _ alerts: [HealthAlert], evaluated: Set<AlgorandAddress?>? = nil, now: Date
    ) -> [HealthAlert] {
        var notify = [HealthAlert]()

        for alert in alerts {
            let key = alert.key
            let escalated = lastSeverity[key].map { alert.severity > $0 } ?? false
            if escalated || isDue(alert, now: now) {
                notify.append(alert)
                lastNotified[key] = now
                lastSeverity[key] = alert.severity
            }
        }

        record(alerts, evaluated: evaluated, now: now)
        return notify
    }

    private func isDue(_ alert: HealthAlert, now: Date) -> Bool {
        guard let last = lastNotified[alert.key] else { return true }
        let elapsed = now.timeIntervalSince(last)
        guard continues(alert.key, now: now) else { return elapsed >= cooldown }
        return reminderInterval(for: alert).map { elapsed >= $0 } ?? false
    }

    /// Whether the alert has held without a real break: it held at its
    /// account's previous evaluation, or it has been gone for less than the
    /// cooldown. Before the account has been evaluated at all, a notification
    /// restored from an earlier run means the user has been told, and the
    /// condition is taken to have held since.
    private func continues(_ key: AlertKey, now: Date) -> Bool {
        guard evaluatedEverything || everEvaluated.contains(key.address) else { return true }
        if holding.contains(key) { return true }
        guard let since = absentSince[key] else { return false }
        return now.timeIntervalSince(since) < cooldown
    }

    private mutating func record(
        _ alerts: [HealthAlert], evaluated: Set<AlgorandAddress?>?, now: Date
    ) {
        let present = Set(alerts.map(\.key))
        // Only the evaluated accounts can have cleared. A failed fetch evaluates
        // nothing for its account, and a sleeping Mac makes no call at all, so
        // whatever held before still holds.
        let covered: (AlertKey) -> Bool
        if let evaluated {
            let addresses = evaluated.union(alerts.map(\.address))
            covered = { addresses.contains($0.address) }
            everEvaluated.formUnion(addresses)
        } else {
            covered = { _ in true }
            evaluatedEverything = true
        }

        for key in holding.union(lastNotified.keys) where covered(key) && !present.contains(key) {
            absentSince[key] = absentSince[key] ?? now
        }
        for key in present { absentSince[key] = nil }
        holding = holding.filter { !covered($0) }.union(present)
    }
}
