import AlgobuddyCore
import Foundation
import OSLog
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

/// A menu bar agent has no console to print to, so diagnostics go to the
/// unified log. Inspect with:
///
///     log stream --predicate 'subsystem == "dev.algobuddy.app"' --level debug
let log = Logger(subsystem: "dev.algobuddy.app", category: "app")

@MainActor
@Observable
final class AppModel {
    // Persisted settings. Views mutate these freely and call `apply()` on commit,
    // rather than restarting the poller on every keystroke.
    var addressText = ""

    /// Replaces the account's address and its ALGO figures with bullets in the
    /// panel and the menu bar, for screen sharing, screenshots, or simply not
    /// wanting a balance on display all day.
    ///
    /// This hides values from onlookers and nothing more. It is not a security
    /// control, and there is nothing here to secure: the address is public chain
    /// data and the app holds no keys.
    var valuesHidden = false
    var algodURLText = Defaults.algodURL
    var indexerURLText = Defaults.indexerURL
    var metrics: Set<MenuBarMetric> = [.round]
    var notificationsEnabled = true

    /// The latest update, failed or not. Read for failure state and the alerts
    /// evaluated this cycle.
    private(set) var update: ChainPoller.Update?
    /// The latest update that actually carried account data. A transient poll
    /// failure must not blank the panel and menu bar: the last good data stays
    /// on display, aging visibly via its `observedAt`, until data returns.
    private(set) var lastData: ChainPoller.Update?
    /// A problem with the configured chain data source URLs, rendered in the
    /// Settings section that owns those fields. Address-shape problems are the
    /// address field's own live validation, not this.
    private(set) var sourceError: String?
    private(set) var isRunning = false

    /// What the panel and menu bar render: the latest update when it has data,
    /// otherwise the last one that did.
    var display: ChainPoller.Update? { update?.hasData == true ? update : lastData }

    /// The watched account's share of the displayed update. One address is
    /// configured, so there is one entry.
    var displayEntry: AccountUpdate? { display?.entries.first }

    private var poller: ChainPoller?
    private var streamTask: Task<Void, Never>?

    /// The configuration the running poller was actually built from: one
    /// value, so the watched identity cannot smear across half-updated fields.
    /// Built from parsed values rather than raw edit buffers, so whitespace
    /// and other parse-level noise cannot masquerade as a change.
    private struct AppliedWatch {
        /// The canonical 58-character address, for the panel header.
        let address: String
        /// address|algod|indexer: what decides a poller rebuild.
        let identity: String
        /// address|algod: what the displayed data and cooldowns belong to. The
        /// indexer only backfills rewards, so changing it alone must not blank
        /// figures that are still valid for the unchanged account.
        let dataIdentity: String
        var historyKey: String { "alertHistory.\(dataIdentity)" }
        var severitiesKey: String { "alertSeverities.\(dataIdentity)" }
    }
    private var applied: AppliedWatch?

    /// The address the displayed data belongs to. The edit buffer is not it: a
    /// half-typed draft in Settings must not head another account's figures.
    var watchedAddress: String? { applied?.address }
    /// What was last written to UserDefaults, so the steady state (no new
    /// notifications, which is almost every poll) costs no write at all rather
    /// than a serialisation and cfprefsd round trip every 30 seconds.
    private var persistedHistory: [AlertKey: Date]?
    private var persistedSeverities: [AlertKey: AlertSeverity]?
    /// Keeps banners visible while the app itself is active; see the class.
    private let notificationPresenter = NotificationPresenter()

    // Uptime accounting for the hourly heartbeat below.
    private let launchedAt = Date()
    private var pollCount = 0
    private var failureCount = 0
    private var lastHeartbeatAt = Date()

    enum Defaults {
        /// A public provider, so a first run needs no node and no token.
        static let algodURL = "https://mainnet-api.algonode.cloud"
        static let indexerURL = "https://mainnet-idx.algonode.cloud"
    }

    // MARK: - Derived state

    /// Whether something is actually being watched, not whether the edit
    /// buffer currently parses: a valid address typed into Settings but never
    /// submitted has no poller behind it, and the panel must not pretend
    /// otherwise.
    var isConfigured: Bool { isRunning }

    /// Everything the panel's Attention card should list: the participation
    /// alerts of the data on display, plus the source-outage alert when the
    /// latest poll is failing. The same union `health` colours the icon with,
    /// so the panel can always explain the icon.
    var visibleAlerts: [HealthAlert] {
        guard let display else { return update?.alerts ?? [] }
        guard let update, !update.hasData else { return display.alerts }
        return (display.alerts + update.alerts).sorted { $0.severity > $1.severity }
    }

    var health: HealthLevel {
        // During a brief blip both the displayed data's alerts and the latest
        // update's are quiet and health stays put, which is the point: one
        // dropped request must not flick the icon to unknown. Quiet is healthy
        // only when there is data to be healthy about.
        HealthLevel(worstOf: visibleAlerts.map(\.severity), hasData: display?.hasData == true)
    }

    /// The menu bar text, in `allCases` order so it reads the same however the
    /// checkboxes were clicked. Empty when nothing is selected, which is how
    /// "icon only" is expressed.
    var menuBarSegments: [String] {
        guard let update = display, let entry = update.entries.first else { return [] }
        return MenuBarMetric.allCases.filter(metrics.contains).compactMap { metric in
            switch metric {
            case .round:
                // "#" marks it as an index rather than a quantity.
                return update.currentRound.map { "#" + Format.round($0) }
            case .absenceHeadroom:
                return entry.absence.map {
                    Format.duration($0.headroom(roundTime: update.roundTime))
                }
            case .keyExpiry:
                return entry.keyExpiry.map {
                    Format.duration($0.timeRemaining(roundTime: update.roundTime))
                }
            case .proposals24h:
                return entry.rewards.map { "\($0.proposals24h) blk" }
            case .earned24h:
                return entry.rewards.map {
                    // Masked rather than dropped: removing the segment would
                    // shrink the item and shove every icon to its left along.
                    valuesHidden
                        ? "\(Format.hidden(4)) \(MenuBar.algo)"
                        : "\(Format.algos($0.earned24h, decimals: 1)) \(MenuBar.algo)"
                }
            }
        }
    }

    var menuBarText: String? {
        let segments = menuBarSegments
        return segments.isEmpty ? nil : segments.joined(separator: MenuBar.separator)
    }

    /// A representative sample of the current selection, for the width readout
    /// in Settings. Uses live values when there are any, and plausible
    /// placeholders when the app has not polled yet.
    var menuBarWidthSample: String {
        let segments =
            menuBarSegments.isEmpty
            ? MenuBarMetric.allCases.filter(metrics.contains).map(Self.placeholder)
            : menuBarSegments
        return segments.joined(separator: MenuBar.separator)
    }

    private static func placeholder(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .round: "#64.06M"
        case .absenceHeadroom: "9.8d"
        case .keyExpiry: "277.6d"
        case .proposals24h: "13 blk"
        case .earned24h: "109.6 \(MenuBar.algo)"
        }
    }

    // MARK: - Launch at login

    /// Mirrors `SMAppService`, which is the source of truth, since the user can also
    /// revoke this from System Settings, so it is never cached in UserDefaults.
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?

    var launchesAtLogin: Bool { loginItemStatus == .enabled }

    /// The user approved it, but macOS is still waiting on confirmation in
    /// System Settings → General → Login Items.
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    /// `SMAppService` identifies a login item by its bundle, so this is
    /// meaningless for a bare binary under `swift run`.
    var canLaunchAtLogin: Bool { runsFromBundle }

    /// The registration records wherever the app currently is. Run it from a
    /// build directory and the login item breaks the moment that path changes.
    /// The system's own application directories are the reference, not a
    /// hardcoded path: `make install PREFIX="$HOME/Applications"` is a
    /// first-class install location too. Computed once: the bundle cannot move
    /// while the app runs, and SwiftUI re-reads this on every Settings render.
    let isInstalledInApplications: Bool = {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let domains: [FileManager.SearchPathDomainMask] = [.localDomainMask, .userDomainMask]
        return
            domains
            .flatMap { FileManager.default.urls(for: .applicationDirectory, in: $0) }
            .contains { $0.standardizedFileURL == parent }
    }()

    private var loginStatusQueryInFlight = false

    /// Off the launch path deliberately: `status` is a synchronous XPC round
    /// trip to the background-task daemon, and the value is only ever shown in
    /// Settings, so App.init must not wait on it before the menu bar appears.
    /// Coalesced, so repeated calls cannot pile up queries whose out-of-order
    /// completions would land a stale status last.
    func refreshLoginItemStatus() {
        guard canLaunchAtLogin, !loginStatusQueryInFlight else { return }
        loginStatusQueryInFlight = true
        // The task inherits main-actor isolation, so every touch of `self`
        // stays on the main actor and nothing is sent across an isolation
        // boundary; only the nonisolated query below hops off to do the XPC.
        Task { [weak self] in
            let status = await Self.queryLoginItemStatus()
            self?.loginItemStatus = status
            self?.loginStatusQueryInFlight = false
        }
    }

    /// Nonisolated so the synchronous XPC round trip runs on the concurrent
    /// executor rather than blocking the main actor.
    private nonisolated static func queryLoginItemStatus() async -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard canLaunchAtLogin else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
            log.info("launch at login set to \(enabled)")
        } catch {
            loginItemError = error.localizedDescription
            log.error("launch at login failed: \(error.localizedDescription)")
        }
        refreshLoginItemStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Lifecycle

    func load() {
        let defaults = UserDefaults.standard
        addressText = defaults.string(forKey: "address") ?? ""
        algodURLText = defaults.string(forKey: "algodURL") ?? Defaults.algodURL
        indexerURLText = defaults.string(forKey: "indexerURL") ?? Defaults.indexerURL
        if let stored = defaults.array(forKey: "metrics") as? [String] {
            metrics = Set(stored.compactMap(MenuBarMetric.init))
        } else {
            metrics = [.round]
        }
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        valuesHidden = defaults.bool(forKey: "valuesHidden")
        log.info(
            "load: bundle=\(Bundle.main.bundleIdentifier ?? "nil") address=\(self.addressText.isEmpty ? "empty" : String(self.addressText.prefix(8)))"
        )
        refreshLoginItemStatus()
        // Without a delegate, macOS silently discards any notification that
        // arrives while the app is active, and this app is active exactly when
        // the user has the panel open watching an incident. The dispatcher
        // would still record the drop as delivered and start its cooldown, so
        // the follow-up would be swallowed too.
        if canNotify {
            UNUserNotificationCenter.current().delegate = notificationPresenter
        }
        apply()
    }

    /// Persists the display-only preferences without disturbing the poller.
    ///
    /// The menu bar metrics, the notification toggle and the value mask take
    /// effect immediately, as macOS settings do. The watched identity (address
    /// and endpoint URLs) is deliberately **not** written here: it persists
    /// only in `apply()` once validated, so a half-typed URL abandoned in the
    /// edit buffer can never be saved by an unrelated checkbox and become the
    /// live configuration at the next launch.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(metrics.map(\.rawValue).sorted(), forKey: "metrics")
        defaults.set(notificationsEnabled, forKey: "notifications")
        defaults.set(valuesHidden, forKey: "valuesHidden")
    }

    /// Persists settings and rebuilds the poller. For changes that alter *what*
    /// is polled: the address, or a data source URL. A submit that changes
    /// nothing leaves the running poller alone.
    func apply() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Deliberate clearing is persisted; a stored address must not
            // resurrect at the next launch after the user removed it.
            UserDefaults.standard.set("", forKey: "address")
            stopWatching()
            sourceError = nil
            return
        }

        // An invalid draft never tears down a running watch. Focus can leave a
        // half-typed address or URL at any moment, and losing monitoring over
        // an edit in progress would silently disable the one job the app has.
        // The field's live validation and `sourceError` say why nothing
        // changed; the poller keeps watching the last valid configuration, and
        // what is persisted stays exactly what is running.
        guard let address = try? AlgorandAddress(trimmed) else {
            // The address field's own validation names the problem; a second
            // phrasing here would stack beneath it.
            return
        }
        let algodText = algodURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let algodURL = URL(string: algodText), algodURL.scheme != nil else {
            sourceError = "The algod URL is not valid."
            return
        }
        // The indexer is optional (an empty field just disables rewards), but a
        // non-empty value that does not parse is an error, said out loud. The
        // silent alternative is a mistyped URL quietly removing the Proposals
        // card, which reads as "no proposals" rather than "bad URL".
        let indexerText = indexerURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexerURL: URL?
        if indexerText.isEmpty {
            indexerURL = nil
        } else if let url = URL(string: indexerText), url.scheme != nil {
            indexerURL = url
        } else {
            sourceError = "The indexer URL is not valid."
            return
        }
        sourceError = nil

        let next = AppliedWatch(
            address: address.stringValue,
            identity:
                "\(address.stringValue)|\(algodURL.absoluteString)|\(indexerURL?.absoluteString ?? "")",
            dataIdentity: "\(address.stringValue)|\(algodURL.absoluteString)")
        // When nothing changed, the running poller is left in peace; a focus
        // change or an identical re-submit costs no writes and no teardown.
        if next.identity == applied?.identity, isRunning { return }

        // The watched identity persists only now, past validation, so what is
        // stored is always something a relaunch can actually poll, and always
        // exactly what is running.
        let defaults = UserDefaults.standard
        defaults.set(address.stringValue, forKey: "address")
        defaults.set(algodText, forKey: "algodURL")
        defaults.set(indexerText, forKey: "indexerURL")

        stop()
        // Data and cooldowns belong to address|algod. When that pair changes,
        // the old identity's data must not linger under the new address and the
        // new identity must not inherit the old one's cooldowns. An
        // indexer-only change rebuilds the poller but keeps the account data:
        // every displayed figure except rewards is still valid.
        if next.dataIdentity != applied?.dataIdentity {
            update = nil
            lastData = nil
            persistedHistory = nil
            persistedSeverities = nil
            pruneAlertHistory(keeping: next)
        }
        applied = next

        let poller = ChainPoller(
            config: ChainPollerConfig(address: address),
            algod: AlgodClient(baseURL: algodURL),
            indexer: indexerURL.map { IndexerClient(baseURL: $0) },
            // Restored so relaunching does not re-announce something the user
            // has already been told about.
            dispatcher: AlertDispatcher(
                lastNotified: loadAlertHistory(),
                lastSeverity: loadAlertSeverities()),
            notificationsWanted: notificationsEnabled)
        self.poller = poller

        streamTask = Task { [weak self] in
            log.info("stream: consuming")
            for await value in poller.updates {
                guard let self else { return }
                // A value already resumed from the old poller must not land
                // under the new identity: apply() cancels this task, but
                // cancellation cannot unschedule an iteration that has already
                // resumed past its await.
                guard self.poller === poller else { return }
                self.receive(value)
            }
        }
        Task {
            log.info("poller starting for \(address.stringValue.prefix(8))")
            await poller.start()
        }
        isRunning = true

        // Tied to a valid address rather than to startup. On a fresh install
        // nothing is configured yet, so this line is never reached and no prompt
        // arrives over an app that has nothing to notify about and no visible
        // reason to want the permission. Once someone has asked for an account
        // to be watched, the reason is self-evident. macOS answers from the
        // stored decision after the first time, so reaching this again on a
        // configured launch shows nothing.
        if notificationsEnabled { requestNotificationAuthorisation() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let poller {
            Task { await poller.stop() }
        }
        poller = nil
        isRunning = false
    }

    /// Stops polling and drops the watched identity with its data. For the
    /// paths where there is no longer a valid thing to watch; a menu bar still
    /// showing the previous account's health would be a quiet lie.
    private func stopWatching() {
        stop()
        update = nil
        lastData = nil
        applied = nil
        persistedHistory = nil
        persistedSeverities = nil
    }

    /// The notifications toggle. Distinct from `save()` because turning it on
    /// has two side effects: the system authorisation prompt, which must be
    /// requestable *now* rather than at the next address submit, and the
    /// poller's dispatcher gate, which must stop consuming cooldowns while
    /// notifications are off.
    func setNotifications(enabled: Bool) {
        notificationsEnabled = enabled
        save()
        if enabled { requestNotificationAuthorisation() }
        // Synchronous through the poller's gate: effective before this call
        // returns, so no in-flight poll can stamp a cooldown for a
        // notification that will never be shown.
        poller?.setNotificationsWanted(enabled)
    }

    private(set) var isRefreshing = false

    func refreshNow() {
        guard let poller, !isRefreshing else { return }
        isRefreshing = true
        Task {
            await poller.refresh()
            isRefreshing = false
        }
    }

    // MARK: - Notifications

    private func receive(_ value: ChainPoller.Update) {
        update = value
        if value.hasData { lastData = value }
        saveAlertHistory(value.alertHistory, severities: value.alertSeverities)
        if let failure = value.failure {
            failureCount += 1
            log.error("poll failed at \(failure.stage.rawValue): \(failure.message)")
        } else {
            pollCount += 1
            log.info("poll ok round=\(value.currentRound ?? 0) alerts=\(value.alerts.count)")
        }
        emitHeartbeatIfDue()
        guard notificationsEnabled else { return }
        for alert in value.notifications {
            post(alert)
        }
    }

    /// An hourly `.notice` line, so uptime is answerable after the fact.
    ///
    /// `.debug` and `.info` messages live in a memory ring buffer and are
    /// evicted within hours, so `log show` cannot reach an overnight run.
    /// `.notice` is persisted to disk. One line per hour reconstructs uptime
    /// without flooding the system log with a message every 30 seconds.
    private func emitHeartbeatIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatAt) >= 3600 else { return }
        lastHeartbeatAt = now

        let hours = now.timeIntervalSince(launchedAt) / 3600
        log.notice(
            """
            alive: up \(String(format: "%.1f", hours))h, \
            \(self.pollCount) polls, \(self.failureCount) failures
            """)
    }

    /// Notification cooldowns are persisted so that quitting and relaunching
    /// does not re-announce a condition the user has already seen. Without this,
    /// a warning that legitimately holds for days notifies on every launch.
    ///
    /// Keyed by the data identity (address|algod): a cooldown recorded for one address means
    /// nothing about another, and inheriting it would swallow the new account's
    /// first alert. Severities are persisted alongside so escalation detection
    /// survives a relaunch too.
    private var historyKey: String? { applied?.historyKey }
    private var severitiesKey: String? { applied?.severitiesKey }

    /// One identity is watched at a time, so history for any other is dead
    /// weight: pruned on switch rather than accumulating a pair of keys for
    /// every address ever watched.
    private func pruneAlertHistory(keeping next: AppliedWatch) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("alertHistory") || key.hasPrefix("alertSeverities") {
            if key != next.historyKey && key != next.severitiesKey {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func loadAlertHistory() -> [AlertKey: Date] {
        guard let historyKey,
            let stored = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double]
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            if let key = AlertKey(storageKey: entry.key) {
                result[key] = Date(timeIntervalSince1970: entry.value)
            }
        }
    }

    private func loadAlertSeverities() -> [AlertKey: AlertSeverity] {
        guard let severitiesKey,
            let stored = UserDefaults.standard.dictionary(forKey: severitiesKey) as? [String: Int]
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            if let key = AlertKey(storageKey: entry.key),
                let severity = AlertSeverity(rawValue: entry.value)
            {
                result[key] = severity
            }
        }
    }

    private func saveAlertHistory(
        _ history: [AlertKey: Date], severities: [AlertKey: AlertSeverity]
    ) {
        guard let historyKey, let severitiesKey else { return }
        guard history != persistedHistory || severities != persistedSeverities else { return }
        persistedHistory = history
        persistedSeverities = severities
        let dates = history.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.storageKey] = entry.value.timeIntervalSince1970
        }
        let levels = severities.reduce(into: [String: Int]()) { result, entry in
            result[entry.key.storageKey] = entry.value.rawValue
        }
        UserDefaults.standard.set(dates, forKey: historyKey)
        UserDefaults.standard.set(levels, forKey: severitiesKey)
    }

    /// The stamped bundle version: a tag number on release builds, a commit
    /// hash on development builds, nil under `swift run` where no bundle
    /// exists. Shown in Settings so a bug report can name the exact build.
    let appVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    // MARK: - Update check

    /// The result of the last check this launch, or nil before one is asked
    /// for. Deliberately not persisted: a stale answer from yesterday would be
    /// presented with the same confidence as one from a second ago.
    private(set) var updateStatus: UpdateStatus?
    private(set) var isCheckingForUpdates = false
    private let updateChecker = UpdateChecker()

    /// Contacts github.com, and only from here. The app is installed by
    /// building from source, so a new release is otherwise invisible to anyone
    /// who does not revisit the repository. Nothing is downloaded and nothing
    /// is run: the answer is a version number and a link.
    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        // Cleared first, so the previous answer cannot sit next to a spinner
        // looking like the current one.
        updateStatus = nil
        Task { [appVersion, updateChecker] in
            let status = await updateChecker.check(runningVersion: appVersion)
            updateStatus = status
            isCheckingForUpdates = false
            log.info("update check: \(String(describing: status))")
        }
    }

    /// Both notification posting and login-item registration need a real bundle
    /// identity, which a bare binary under `swift run` lacks. One predicate, so
    /// the two features can never disagree about what counts as bundled.
    private var runsFromBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// `UNUserNotificationCenter` traps when there is no bundle identifier.
    /// Guarding keeps the binary usable outside the .app wrapper for development.
    private var canNotify: Bool { runsFromBundle }

    private func requestNotificationAuthorisation() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
        }
    }

    private func post(_ alert: HealthAlert) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.severity == .critical ? .default : nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "\(alert.id.rawValue)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil))
    }
}

/// Presents notifications as banners even while the app is active.
///
/// Deliberately outside `AppModel`: notification-center callbacks arrive on an
/// arbitrary queue, so this must not inherit the model's main-actor isolation.
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
