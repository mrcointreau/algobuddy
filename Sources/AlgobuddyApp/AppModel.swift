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

/// One row of the Account list, as the user is editing it.
///
/// Identified by a token rather than by its text: two rows hold the same
/// characters while one is being typed into, and rows identified by content
/// would collapse into each other or swap places mid-edit, taking the keyboard
/// focus with them.
struct AddressDraft: Identifiable {
    let id = UUID()
    var text = ""
    /// The account this row held when the list was last applied, which stays
    /// watched while the text is mid-edit. See `WatchList.Row`.
    var held: AlgorandAddress?
    /// The name field's text, as typed. See `AccountNames`.
    var name = ""
}

@MainActor
@Observable
final class AppModel {
    // Persisted settings. Views mutate these freely and call `apply()` on commit,
    // rather than restarting the poller on every keystroke.

    /// The watched addresses, in the order every surface presents them.
    ///
    /// Never empty: onboarding and Settings both need a row to type into, so
    /// removing the last one leaves a blank row rather than nothing. A blank
    /// row watches nothing, which is how "no account" is expressed.
    var addressDrafts = [AddressDraft()]

    /// Replaces the account's address and its ALGO figures with bullets in the
    /// panel and the menu bar, for screen sharing, screenshots, or simply not
    /// wanting a balance on display all day.
    ///
    /// This hides values from onlookers and nothing more. It is not a security
    /// control, and there is nothing here to secure: the address is public chain
    /// data and the app holds no keys.
    var valuesHidden = false
    /// What the panel and notifications call each account, keyed by address
    /// and applied with the list. Labels for the user's own eyes: stored on
    /// this Mac and never sent to any host.
    private(set) var accountNames = AccountNames()
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

    /// How many accounts the panel is about: the displayed data's, or, before
    /// any has arrived, how many are being watched. The panel becomes a list of
    /// accounts only past one, and the menu bar and notifications name accounts
    /// only past one, so this is the switch for all of them: with a single
    /// account every surface reads as it always has.
    ///
    /// The watched count stands in until data arrives, deliberately: a
    /// portfolio whose first poll is still in flight must not head its panel
    /// with whichever address happens to be first on the list.
    var accountCount: Int { display?.entries.count ?? applied?.addresses.count ?? 0 }

    /// The failure worth stating for the whole panel: a shared stage, which
    /// every account's figures depend on, or a failure that every watched
    /// account has, where repeating the same sentence per address would say
    /// nothing more. One account's own trouble is its own line instead, beside
    /// its own facts. With a single account watched, its failure is by
    /// definition every account's, so this reads exactly as it always has.
    var sharedFailure: PollFailure? {
        guard let update, let failure = update.failure else { return nil }
        guard failure.stage.isShared || update.entries.allSatisfy({ $0.failure != nil })
        else { return nil }
        return failure
    }

    /// Whether the watch has an indexer, which the proposal figures come from.
    /// Until its first answer, the panel holds their place.
    var expectsRewards: Bool { applied?.indexerURL != nil }

    /// The account whose detail the panel shows, or nil for the list of all of
    /// them. Held here rather than in the view, so the panel can drop it when it
    /// closes and `apply()` can drop it when the account leaves the watch.
    var selectedAccount: AlgorandAddress?

    private var poller: ChainPoller?
    private var streamTask: Task<Void, Never>?

    /// The configuration the running poller was actually built from: one
    /// value, so the watched identity cannot smear across half-updated fields.
    /// Built from parsed values rather than raw edit buffers, so whitespace
    /// and other parse-level noise cannot masquerade as a change.
    private struct AppliedWatch {
        /// The canonical 58-character addresses, in watch order.
        let addresses: [String]
        /// What the displayed figures and the notification cooldowns are
        /// answers about: the same address at another source can be another
        /// network's account entirely, while the indexer only backfills
        /// rewards, so changing it alone must not blank figures that are still
        /// valid.
        let algodURL: URL
        /// Nil when the field is empty, which turns rewards off.
        let indexerURL: URL?

        var source: String { algodURL.absoluteString }
        /// addresses|algod|indexer: what decides a poller rebuild.
        var identity: String {
            "\(addresses.joined(separator: ","))|\(source)|\(indexerURL?.absoluteString ?? "")"
        }

        /// Cooldowns are recorded per account inside these, since an `AlertKey`
        /// carries the address it holds for. Keying the bucket on the source
        /// alone is what lets a changed list keep the cooldowns of the accounts
        /// that stayed on it, instead of re-announcing everything the moment
        /// another address is added.
        var historyKey: String { "alertHistory.\(source)" }
        var severitiesKey: String { "alertSeverities.\(source)" }
    }
    private var applied: AppliedWatch?

    /// The addresses the displayed data belongs to. The edit buffers are not
    /// them: a half-typed draft in Settings must not head another account's
    /// figures.
    var watchedAddresses: [String] { applied?.addresses ?? [] }

    /// The address the panel names when it is about a single account. Falls
    /// back to the row being typed, which is all there is before a watch has
    /// been applied.
    var watchedAddress: String { watchedAddresses.first ?? addressDrafts.first?.text ?? "" }
    /// What was last written to UserDefaults, so the steady state (no new
    /// notifications, which is almost every poll) costs no write at all rather
    /// than a serialisation and cfprefsd round trip every 30 seconds.
    private var persistedHistory: [AlertKey: Date]?
    private var persistedSeverities: [AlertKey: AlertSeverity]?
    /// The names as last written, so an apply that renames nothing writes
    /// nothing. Nil until the first apply, which therefore always writes, and
    /// so drops any name the store kept for an address no longer listed.
    private var persistedNames: [String: String]?
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

    /// Where a store can hold a single watched address instead of the list.
    /// Read on load and cleared on the first save, so the watch it names
    /// carries over exactly once and the address does not outlive the list.
    private let singleAddressKey = "address"
    private let accountNamesKey = "accountNames"

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
    ///
    /// Read from the portfolio rather than from one account: the round is
    /// shared by the cycle, the two countdowns show whichever account runs out
    /// first, and the proposal figures are sums. With one account watched every
    /// one of those is that account's own value.
    var menuBarSegments: [String] {
        guard let update = display else { return [] }
        let portfolio = update.portfolio
        // Silent unless every account's proposals are current, so neither a
        // pending fetch nor a failed one can pass for the total, least of all
        // as "no blocks today". The panel still shows the figures, and says
        // why they are partial.
        let showsRewards = portfolio.hasRewards && !portfolio.isPartial
        return MenuBarMetric.allCases.filter(metrics.contains).compactMap { metric in
            switch metric {
            case .round:
                // "#" marks it as an index rather than a quantity.
                return update.currentRound.map { "#" + Format.round($0) }
            case .absenceHeadroom:
                return portfolio.closestAbsenceHeadroom.map(Format.duration)
            case .keyExpiry:
                return portfolio.closestKeyExpiry.map(Format.duration)
            case .proposals24h:
                return showsRewards ? "\(portfolio.proposals24h) blk" : nil
            case .earned24h:
                guard showsRewards else { return nil }
                // Masked rather than dropped: removing the segment would
                // shrink the item and shove every icon to its left along.
                return valuesHidden
                    ? "\(Format.hidden(4)) \(MenuBar.algo)"
                    : "\(Format.algos(portfolio.earned24h, decimals: 1)) \(MenuBar.algo)"
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

    // MARK: - Notification permission

    /// Mirrors the system's notification permission, which is the source of
    /// truth, since the user can change it in System Settings at any time.
    /// Nil until first read.
    private(set) var notificationAuthorization: UNAuthorizationStatus?

    /// The user wants notifications and macOS refuses them. Settings says so,
    /// since nothing else would: a refused banner leaves no trace.
    var notificationsBlocked: Bool {
        notificationsEnabled && notificationAuthorization == .denied
    }

    /// Whether alerts are dispatched at all: wanted, and allowed. A permission
    /// not yet read counts as refused, because every dispatch stamps a
    /// cooldown, and one stamped for a banner the system drops holds back the
    /// real one after the permission is granted.
    private var deliversNotifications: Bool {
        notificationsEnabled
            && (notificationAuthorization == .authorized
                || notificationAuthorization == .provisional)
    }

    private var notificationQueries = 0
    private var activationObserver: (any NSObjectProtocol)?

    /// Reads the permission and opens or closes the poller's gate to match.
    /// Only the latest of overlapping reads lands, so a slow one cannot leave
    /// a stale status behind.
    private func refreshNotificationAuthorization() {
        guard canNotify else { return }
        notificationQueries += 1
        let query = notificationQueries
        // As in `refreshLoginItemStatus()`, the task inherits main-actor
        // isolation and only the nonisolated query hops off.
        Task { [weak self] in
            let status = await Self.queryNotificationAuthorization()
            guard let self, query == self.notificationQueries else { return }
            self.notificationAuthorization = status
            self.poller?.setNotificationsWanted(self.deliversNotifications)
        }
    }

    private nonisolated static func queryNotificationAuthorization() async
        -> UNAuthorizationStatus
    {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    func load() {
        // Every request goes through the private session, so nothing in the
        // shared URL cache or the shared cookie store is needed, and a response
        // cached there would be keyed by a URL that names a watched address.
        // Both are emptied.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let defaults = UserDefaults.standard
        // A store that holds one address rather than a list still names one
        // watched account, and comes through as that account with nothing asked
        // of the user. See `WatchList.restore(list:single:)`.
        let stored = WatchList.restore(
            list: defaults.array(forKey: "addresses") as? [String],
            single: defaults.string(forKey: singleAddressKey))
        let names = AccountNames(
            stored: (defaults.dictionary(forKey: accountNamesKey) ?? [:])
                .compactMapValues { $0 as? String })
        addressDrafts =
            stored.isEmpty
            ? [AddressDraft()]
            : stored.map { AddressDraft(text: $0, name: names.stored[$0] ?? "") }
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
            "load: bundle=\(Bundle.main.bundleIdentifier ?? "nil") addresses=\(stored.count)"
        )
        refreshLoginItemStatus()
        // Without a delegate, macOS silently discards any notification that
        // arrives while the app is active, and this app is active exactly when
        // the user has the panel open watching an incident. The dispatcher
        // would still record the drop as delivered and start its cooldown, so
        // the follow-up would be swallowed too.
        if canNotify {
            UNUserNotificationCenter.current().delegate = notificationPresenter
            // The permission can change in System Settings while the app runs,
            // and coming back to the panel or to Settings activates the app,
            // so that is where a change is read straight away.
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNotificationAuthorization() }
            }
        }
        // Read before the first poll can dispatch, which it almost always
        // trails: a local query against a network round trip. Should the poll
        // win, its alerts wait for the next one rather than stamp a cooldown.
        refreshNotificationAuthorization()
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
        // A field mid-edit never tears down what it watches, and never holds
        // back the fields beside it. Focus can leave a half-typed address or
        // URL at any moment, and losing monitoring over an edit in progress
        // would silently disable the one job the app has, so such a row keeps
        // the account it held and such a URL the one last applied, while a
        // removal or an edit made beside them still applies. The row's own
        // note and `sourceError` say what is not yet in effect, and what is
        // persisted stays exactly what is running.
        let rows = addressDrafts.map { WatchList.Row(text: $0.text, held: $0.held) }
        let addresses = WatchList.resolve(rows)
        // A row's name belongs to the account the row watches, so it follows
        // that address and leaves the list with it.
        let names = AccountNames(
            zip(rows, addressDrafts).map { (account: $0.watched, name: $1.name) })

        guard !addresses.isEmpty else {
            // Deliberate clearing is persisted; a stored address must not
            // resurrect at the next launch after the user removed it.
            UserDefaults.standard.set([String](), forKey: "addresses")
            UserDefaults.standard.removeObject(forKey: singleAddressKey)
            stopWatching()
            sourceError = nil
            hold(rows)
            keep(names)
            return
        }
        let typedAlgod = SourceURL.parse(algodURLText)
        let indexerText = indexerURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedIndexer = SourceURL.parse(indexerText)
        // The indexer is optional (an empty field just disables rewards), but a
        // non-empty value that is not a URL to poll is an error, said out loud.
        // The silent alternative is a mistyped URL quietly removing the
        // Proposals card, which reads as "no proposals" rather than "bad URL".
        let indexerIsValid = indexerText.isEmpty || typedIndexer != nil
        if typedAlgod == nil {
            sourceError = "The algod URL is not valid. It needs http:// or https:// and a host."
        } else if !indexerIsValid {
            sourceError =
                "The indexer URL is not valid. It needs http:// or https:// and a host, or it can be left empty."
        } else {
            sourceError = nil
        }
        // Before anything has been applied there is no URL to keep, so nothing
        // is watched until both are valid.
        guard let algodURL = typedAlgod ?? applied?.algodURL, indexerIsValid || applied != nil
        else { return }
        let indexerURL = indexerIsValid ? typedIndexer : applied?.indexerURL

        let watched = addresses.map(\.stringValue)
        let next = AppliedWatch(addresses: watched, algodURL: algodURL, indexerURL: indexerURL)
        hold(rows)
        // Ahead of the check below, because a name changes nothing that is
        // polled: a rename alone shows at once and leaves the poller running.
        keep(names)
        // When nothing changed, the running poller is left in peace; a focus
        // change or an identical re-submit costs no writes and no teardown.
        if next.identity == applied?.identity, isRunning { return }

        // The watched identity persists only now, past validation, so what is
        // stored is always something a relaunch can actually poll, and always
        // exactly what is running. Canonical, so a pasted address stored in
        // another case cannot read back as a different account.
        let defaults = UserDefaults.standard
        defaults.set(watched, forKey: "addresses")
        // The list is the whole of what is watched, so a lone stored address is
        // cleared as it is taken up into it. Left behind, it would outlive the
        // moment the user takes that account off the list.
        defaults.removeObject(forKey: singleAddressKey)
        defaults.set(algodURL.absoluteString, forKey: "algodURL")
        defaults.set(indexerURL?.absoluteString ?? "", forKey: "indexerURL")

        stop()
        // The displayed figures are answers about the accounts on the list, at
        // this source. Adding an address leaves every one of them true and
        // still watched, so the panel keeps them until the first poll of the
        // new list lands. Anything else, a removal or another source, means the
        // data on display no longer describes the watch, and a figure headed by
        // an address nobody is watching any more is a quiet lie. An
        // indexer-only change keeps the data either way: every displayed figure
        // except rewards is still valid.
        let stillDescribesTheWatch =
            next.source == applied?.source
            && Set(applied?.addresses ?? []).isSubset(of: Set(watched))
        if !stillDescribesTheWatch {
            update = nil
            lastData = nil
        }
        // Rewritten below whatever happened above, since pruning may have
        // changed what is stored under these keys.
        persistedHistory = nil
        persistedSeverities = nil
        pruneAlertHistory(keeping: next)
        applied = next
        // A detail about an account that is no longer watched has nothing left
        // to show, so the panel returns to the list.
        if let selected = selectedAccount, !watched.contains(selected.stringValue) {
            selectedAccount = nil
        }

        let poller = ChainPoller(
            config: ChainPollerConfig(addresses: addresses),
            algod: AlgodClient(baseURL: algodURL),
            indexer: indexerURL.map { IndexerClient(baseURL: $0) },
            // Restored so relaunching does not re-announce something the user
            // has already been told about.
            dispatcher: AlertDispatcher(
                lastNotified: loadAlertHistory(),
                lastSeverity: loadAlertSeverities()),
            notificationsWanted: deliversNotifications)
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
            log.info("poller starting for \(watched.count) account(s)")
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
        selectedAccount = nil
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
        poller?.setNotificationsWanted(deliversNotifications)
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
        // A cycle's update comes again, with the same observation time, when
        // its rewards query answers. That is no further poll, so the counts
        // the heartbeat reports leave it out.
        let isPoll = value.observedAt != update?.observedAt
        update = value
        if value.hasData { lastData = value }
        saveAlertHistory(value.alertHistory, severities: value.alertSeverities)
        if !isPoll {
            if let failure = value.entries.compactMap(\.failure).first(where: {
                $0.stage == .rewards
            }) {
                log.error("rewards failed: \(failure.message)")
            } else {
                log.info("rewards answered")
            }
        } else if let failure = value.failure {
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
        // A permission changed in System Settings while the app is in the
        // background, granted or withdrawn, would otherwise wait for the next
        // activation, so it is read with every poll as well: one local query,
        // which keeps the gate within a poll of the truth.
        refreshNotificationAuthorization()
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
    /// Bucketed by the chain data source, and keyed within it by account and
    /// rule: a cooldown recorded for one address means nothing about another,
    /// and inheriting it would swallow the new account's first alert.
    /// Severities are persisted alongside so escalation detection survives a
    /// relaunch too.
    private var historyKey: String? { applied?.historyKey }
    private var severitiesKey: String? { applied?.severitiesKey }

    /// One source is watched at a time, so history for any other is dead
    /// weight: pruned on switch rather than accumulating a pair of keys for
    /// every URL ever configured.
    ///
    /// Inside the surviving pair, the accounts that stayed on the list keep
    /// their cooldowns and the ones taken off it lose theirs. That is what
    /// makes editing the list cheap: adding an address must not re-announce
    /// every condition already holding on the others.
    private func pruneAlertHistory(keeping next: AppliedWatch) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("alertHistory") || key.hasPrefix("alertSeverities") {
            if key != next.historyKey && key != next.severitiesKey {
                defaults.removeObject(forKey: key)
            }
        }
        let watched = Set(next.addresses)
        prune(key: next.historyKey, watched: watched)
        prune(key: next.severitiesKey, watched: watched)
    }

    /// Drops the entries of one stored cooldown dictionary that belong to no
    /// watched account. An entry that cannot be read is dropped too, which at
    /// worst re-announces a condition that still holds.
    private func prune(key: String, watched: Set<String>) {
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: key) else { return }
        let kept = stored.filter { entry, _ in
            guard let alertKey = AlertKey(storageKey: entry) else { return false }
            // An alert about the watch itself, such as the source being
            // unreachable, belongs to no account and stays.
            guard let address = alertKey.address else { return true }
            return watched.contains(address.stringValue)
        }
        if kept.count != stored.count { defaults.set(kept, forKey: key) }
    }

    // MARK: - Editing the list

    /// Shows the names the rows give, and stores them when they differ from
    /// what was last stored.
    private func keep(_ names: AccountNames) {
        if names != accountNames { accountNames = names }
        guard names.stored != persistedNames else { return }
        UserDefaults.standard.set(names.stored, forKey: accountNamesKey)
        persistedNames = names.stored
    }

    /// Records the account each row watches now. A row keeps it through a
    /// later edit, until its text names another account or is cleared.
    private func hold(_ rows: [WatchList.Row]) {
        for (index, row) in zip(addressDrafts.indices, rows) {
            addressDrafts[index].held = row.watched
        }
    }

    /// Appends a row and reports it, so the caller can put the cursor in it.
    /// Nothing is applied: an empty row watches nothing, and the poller has no
    /// reason to be disturbed before it is typed into.
    @discardableResult
    func addAddressRow() -> AddressDraft.ID {
        let draft = AddressDraft()
        addressDrafts.append(draft)
        return draft.id
    }

    /// Removes a row and applies the shorter list at once: a removal is a
    /// finished decision, where a text edit is not, so it does not wait for
    /// focus to leave some other field.
    func removeAddressRow(_ id: AddressDraft.ID) {
        addressDrafts.removeAll { $0.id == id }
        // Removing the last row is how the watch is cleared, and the blank row
        // left behind is what the user types the next address into.
        if addressDrafts.isEmpty { addressDrafts = [AddressDraft()] }
        apply()
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

    /// The gate opens once the answer is read back, so nothing is dispatched
    /// while the prompt is still on screen.
    private func requestNotificationAuthorisation() {
        guard canNotify else { return }
        Task { [weak self] in
            await Self.askForNotificationPermission()
            self?.refreshNotificationAuthorization()
        }
    }

    /// Shows the system prompt the first time, and answers from the stored
    /// decision after that.
    private nonisolated static func askForNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func post(_ alert: HealthAlert) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // Which account this holds for. Only past one watched account: with a
        // single one the banner would name the only thing it could be about.
        // Named and masked like every other surface, because a banner is on
        // screen during exactly the screen share the mask is for.
        if accountCount > 1, let address = alert.address {
            content.subtitle = Format.accountLabel(
                address, names: accountNames, hidden: valuesHidden)
        }
        content.sound = alert.severity == .critical ? .default : nil

        // One identifier per account and rule, so a reminder or an escalation
        // replaces the banner it follows instead of stacking up beside it.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: alert.key.notificationIdentifier,
                content: content,
                trigger: nil)
        ) { error in
            // A refusal most likely means the permission was withdrawn since
            // it was last read. The read that follows every poll's posts
            // closes the gate, so this only has to leave a trace.
            if let error { log.error("notification not posted: \(error.localizedDescription)") }
        }
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
