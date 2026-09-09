import Foundation

/// Decides which of the currently-holding alerts should actually interrupt the
/// user.
///
/// `AlertEngine.evaluate` is pure and re-derives every alert on every poll, so
/// without this a warning that holds for a day would fire 2,880 notifications.
/// Keeping the time-dependent state here is what lets the rules themselves stay
/// clock-free and fixture-testable.
public struct AlertDispatcher: Sendable, Equatable {
    /// How long before a still-holding alert notifies again.
    public var cooldown: TimeInterval

    private var lastNotified: [AlertKey: Date] = [:]
    private var lastSeverity: [AlertKey: AlertSeverity] = [:]

    /// - Parameters:
    ///   - lastNotified: Notification times persisted from an earlier run.
    ///     Seeding them keeps the cooldown across launches, so a condition that
    ///     holds for days does not re-notify every time the app starts.
    ///   - lastSeverity: Severities persisted alongside. Without them a warning
    ///     that escalates to critical inside the restored cooldown would go
    ///     unannounced after a relaunch, because `escalated` needs the previous
    ///     severity to compare against.
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

    /// Severities at last evaluation, persisted with `notificationHistory` so
    /// escalation detection survives a relaunch.
    public var severityHistory: [AlertKey: AlertSeverity] { lastSeverity }

    /// Returns the subset of `alerts` to notify about now.
    ///
    /// An alert notifies when it first appears, when it escalates in severity,
    /// or when it has held continuously past the cooldown. Note that the
    /// cooldown is keyed on *last notification*, not on when the condition
    /// cleared, so a flapping condition cannot notify repeatedly by
    /// disappearing and coming straight back.
    public mutating func dispatch(_ alerts: [HealthAlert], now: Date) -> [HealthAlert] {
        var notify = [HealthAlert]()

        for alert in alerts {
            let key = alert.key
            let escalated = lastSeverity[key].map { alert.severity > $0 } ?? false
            let cooledDown =
                lastNotified[key].map {
                    now.timeIntervalSince($0) >= cooldown
                } ?? true

            if escalated || cooledDown {
                notify.append(alert)
                lastNotified[key] = now
            }
            lastSeverity[key] = alert.severity
        }

        // `lastSeverity` survives a clear on purpose. Without a remembered
        // severity, `escalated` is false when a condition returns at a higher
        // one, so a warning that cleared and came back as critical inside the
        // cooldown would notify nobody. `lastNotified` survives too, so a
        // flapping condition still cannot notify faster than the cooldown.
        return notify
    }
}
