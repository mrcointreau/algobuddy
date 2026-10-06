import AlgobuddyCore
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The content's own height, which the panel's window is kept at.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.isConfigured {
                OnboardingView(model: model)
            } else {
                content
            }
            Divider()
            footer
        }
        // Wide enough for a label and a right-aligned value at menu-font size
        // without either wrapping.
        .frame(width: 360)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            contentHeight = $0
        }
        // Pinned to the top while the window is taller than the content, so
        // the panel extends and retracts at its bottom edge, as a menu does,
        // instead of floating in the middle of its window.
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.valuesHidden, model.valuesHidden)
        .background(
            PanelWindowKeeper(contentHeight: contentHeight, animates: !reduceMotion) {
                model.selectedAccount = nil
            })
    }

    /// One account is today's single page. Past one, the panel is a list of
    /// the accounts, and each opens its own page, which is the single page
    /// with a way back.
    @ViewBuilder
    private var content: some View {
        if let update = model.display, update.hasData {
            if update.entries.count == 1, let entry = update.entries.first {
                // The applied address: a half-typed Settings draft must not head
                // another account's figures.
                header { AddressTitle(address: model.watchedAddress) }
                Divider()
                single(update, entry)
            } else if let entry = selectedEntry(in: update) {
                header {
                    backControl
                    AddressTitle(address: entry.address.stringValue)
                }
                Divider()
                detail(update, entry)
            } else {
                header { accountCountTitle }
                Divider()
                list(update)
            }
        } else {
            header {
                if model.accountCount > 1 {
                    accountCountTitle
                } else {
                    AddressTitle(address: model.watchedAddress)
                }
            }
            Divider()
            waiting
        }
    }

    // Unscrolled for the same reason as SettingsView. Content here does vary
    // (the alert list grows), so the window grows with it. A taller panel when
    // several alerts hold reads far better than a short one that always
    // scrolls. Spacing separates the groups. Dividers are reserved for the
    // structural split between the panel's chrome and its content.
    private func single(_ update: ChainPoller.Update, _ entry: AccountUpdate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            // The only account's failure is every account's, so the line
            // beneath the cards states it once, rather than this section as well.
            AccountSection(update: update, entry: entry, statesOwnFailure: false)
            // visibleAlerts, not this update's own list: during an outage
            // the displayed data is the last good poll, and the outage
            // alert colouring the menu bar icon lives on the latest failed
            // one. The card must be able to explain the icon.
            if !model.visibleAlerts.isEmpty {
                AlertsCard(alerts: model.visibleAlerts, namesAccounts: false)
            }
            sharedFailureLine
        }
        .padding(Spacing.edge)
    }

    private func detail(_ update: ChainPoller.Update, _ entry: AccountUpdate) -> some View {
        // Alerts about the watch itself, such as a source outage, hold for this
        // account too.
        let alerts = model.visibleAlerts.about(entry.address, includingWatchAlerts: true)
        return VStack(alignment: .leading, spacing: Spacing.group) {
            AccountSection(update: update, entry: entry, statesOwnFailure: true)
            if !alerts.isEmpty {
                AlertsCard(alerts: alerts, namesAccounts: false)
            }
            // Only a stage every account depends on. Another account's failure
            // is not this page's to state, and this account's own is stated by
            // its section above.
            if let failure = model.sharedFailure, failure.stage.isShared {
                FailureLine(failure: failure)
            }
        }
        .padding(Spacing.edge)
    }

    private func list(_ update: ChainPoller.Update) -> some View {
        ScreenCapped {
            VStack(alignment: .leading, spacing: Spacing.group) {
                // First, so a problem on any account is the first thing read,
                // and never below the rows of a long list.
                if !model.visibleAlerts.isEmpty {
                    AlertsCard(
                        alerts: model.visibleAlerts, namesAccounts: true, open: { show($0) })
                }
                PortfolioCard(summary: update.portfolio)
                AccountsCard(update: update, alerts: model.visibleAlerts, open: { show($0) })
                sharedFailureLine
            }
            .padding(Spacing.edge)
        }
    }

    // Degradation, stated rather than implied. Partial failures (supply,
    // challenge seed, rewards) ride on successful polls with a fresh header
    // age and no alert of their own, so this line is the only sign some
    // figures are stale or missing. A wholly failed poll leaves the cards
    // showing the last good data, aging in the header; this line names the
    // reason. One account's own failure is not here but beside its own facts.
    @ViewBuilder
    private var sharedFailureLine: some View {
        if let failure = model.sharedFailure {
            FailureLine(failure: failure)
        }
    }

    /// The selected account's entry, or nil for the list. A selection the data
    /// no longer contains falls back to the list rather than an empty page.
    private func selectedEntry(in update: ChainPoller.Update) -> AccountUpdate? {
        guard let selected = model.selectedAccount else { return nil }
        return update.entries.first { $0.address == selected }
    }

    /// Moves between the list and one account. The page swaps at once; the
    /// height change is animated by the window, so the content never animates
    /// inside a window of another size.
    private func show(_ address: AlgorandAddress?) {
        model.selectedAccount = address
    }

    // Every account is named on its own row, so the header states the size of
    // the portfolio rather than electing one address to stand for all of them.
    private var accountCountTitle: some View {
        Text(quantity(Double(model.accountCount), "account"))
            .font(Typography.primary)
    }

    /// Back to the list. HIG: use the standard Back symbol with no text
    /// label, at the far leading edge, followed by the view title. Command [
    /// goes back, as in Finder, Safari and System Settings; Escape keeps its
    /// own meaning and closes the panel.
    private var backControl: some View {
        Button {
            show(nil)
        } label: {
            Image(systemName: "chevron.left")
                .font(Typography.primary.weight(.semibold))
                // HIG: 28 points is the default control size on macOS, and the
                // symbol on its own is a much smaller target than that.
                .frame(width: 28, height: 28)
                .modifier(RowHighlight())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // The symbol lines up with the content below it and the header keeps
        // the list's height, while the target stays its full size.
        .padding(.leading, -8)
        .padding(.vertical, -6)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to all accounts")
        .accessibilityLabel("Back")
    }

    /// Identity and freshness only. The account's status belongs to the card
    /// below, stated once rather than repeated here as a second indicator.
    private func header<Identity: View>(
        @ViewBuilder identity: () -> Identity
    ) -> some View {
        HStack(spacing: 8) {
            identity()
            Spacer()
            // Ticks on its own. A plain Text would freeze at whatever the age
            // was when the last poll happened to re-render the view, which is
            // exactly the number you must not get wrong on a staleness readout.
            // The age of the *data* on display, not of the last poll attempt: a
            // failed attempt seconds ago must not dress stale figures as fresh.
            if let observed = model.display?.observedAt {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    let age = context.date.timeIntervalSince(observed)
                    Text(Format.relative(age))
                        .font(Typography.secondary)
                        .foregroundStyle(
                            age > 90 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = model.update?.failure {
                // Same title, weight and body size as an entry in the Attention
                // section, because that is what this is: the one alert that can
                // hold when there is no account data to draw a card from.
                Label("Chain data unavailable", systemImage: "wifi.exclamationmark")
                    .font(Typography.primary.weight(.medium))
                Text(failure.message)
                    .font(Typography.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Fetching…", systemImage: "clock")
                    .font(Typography.primary).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.edge)
    }

    /// Menu-item rows, not buttons.
    ///
    /// `.link` renders as a hyperlink and `.borderedProminent` shouts. Neither
    /// belongs in a menu bar panel, and mixing them reads as two different
    /// apps. AppKit menus are full-width rows with a hover highlight and a
    /// trailing shortcut, so that is what these are.
    private var footer: some View {
        VStack(spacing: 1) {
            // HIG: "If a menu bar item isn't actionable, disable the action
            // instead of hiding it from the menu." With no poller running there
            // is nothing to refresh, so the row dims rather than no-opping.
            MenuRow(
                title: model.isRefreshing ? "Refreshing…" : "Refresh",
                symbol: "arrow.clockwise", shortcut: "⌘R",
                isBusy: model.isRefreshing
            ) {
                model.refreshNow()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.isRunning || model.isRefreshing)

            // Two-state command in the AppKit manner: the title says what the
            // row will do next, not what the current state is. Sits beside
            // Refresh because both change what the app is showing right now,
            // while Settings opens a window elsewhere. The masking reaches the
            // menu bar's earned figure as well as the panel.
            MenuRow(
                title: model.valuesHidden ? "Show values" : "Hide values",
                symbol: model.valuesHidden ? "eye" : "eye.slash",
                shortcut: "⌘P"
            ) {
                model.valuesHidden.toggle()
                model.save()
            }
            .keyboardShortcut("p", modifiers: .command)

            // HIG: "When people choose the Settings item … your custom settings
            // window opens." SettingsLink opens the Settings scene, which is a
            // real window, so editing a URL does not happen inside a popover
            // that dismisses the moment it loses focus.
            SettingsLink {
                MenuRowLabel(title: "Settings…", symbol: "gearshape", shortcut: "⌘,")
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { SettingsWindow.bringToFront() })

            // HIG: group logically related items and separate them. Quit sits in
            // its own group at the bottom of every macOS app menu.
            Divider().padding(.vertical, 4)

            MenuRow(title: "Quit algobuddy", symbol: "power", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
    }
}

/// Drags the Settings window in front of everything else.
///
/// `SettingsLink` opens the Settings scene but does not activate the app, and an
/// `LSUIElement` agent is never the frontmost app, so the window opens *behind*
/// whatever the user was looking at, with no Dock icon to click and no way to
/// reach it short of minimising other windows.
///
/// The alternative, promoting the app to `.regular` while a window is open so it
/// gains a Dock icon, is deliberately not taken: Docker, the menu bar agent this
/// panel is modelled on, does not do that either. It ships a separate nested app
/// for its dashboard. An icon appearing and vanishing from the Dock and ⌘-Tab is
/// a persistent cost for a rare situation, and reopening Settings from the menu
/// already re-fronts the window.
///
/// `activate()` alone is not enough: the scene may not have materialised its
/// window yet when the tap is handled, and a non-active app's window needs
/// `orderFrontRegardless()` to cross in front of another app's. So after one
/// immediate attempt, the window is claimed the moment AppKit reports one
/// appearing, however long materialisation takes, rather than on a guessed
/// schedule of retries that can all fire too early on a slow launch.
@MainActor
enum SettingsWindow {
    private static var observers: [any NSObjectProtocol] = []
    /// Increments per attempt, so an expiry task can tell whether the
    /// observers it would remove still belong to its own attempt.
    private static var generation = 0

    static func bringToFront() {
        NSApp.activate()
        stopObserving()
        if front() { return }

        // Key status covers the normal appearance; occlusion covers a window
        // that materialises behind another app and therefore never becomes key.
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        if front() { stopObserving() }
                    }
                })
        }

        // If no window ever materialises, the observers must not outlive the
        // attempt and screen every window notification for the rest of the
        // process. Ten seconds is far beyond any real materialisation.
        generation += 1
        let attempt = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if generation == attempt { stopObserving() }
        }
    }

    /// Fronts the Settings window if it exists yet. True once claimed.
    private static func front() -> Bool {
        guard let window = settingsWindow() else { return false }
        // HIG: "Dim a settings window's minimize and maximize buttons …
        // there's no need to keep the window in the Dock, and … people
        // don't need to expand the window to see more."
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    private static func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible, window.canBecomeMain else { return false }
            let identifier = window.identifier?.rawValue ?? ""
            return identifier.localizedCaseInsensitiveContains("settings")
                || window.title.localizedCaseInsensitiveContains("settings")
        }
    }
}

/// A row styled like an AppKit menu item: full width, leading symbol, trailing
/// shortcut, highlight on hover.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, symbol: symbol, shortcut: shortcut, isBusy: isBusy)
        }
        .buttonStyle(.plain)
    }
}

/// The row's appearance, split out from `MenuRow` so `SettingsLink`, which
/// brings its own button, can wear the same look.
struct MenuRowLabel: View {
    let title: String
    let symbol: String
    var shortcut: String?
    /// Swaps the leading symbol for a spinner. A network round trip is long
    /// enough to feel unacknowledged without one.
    var isBusy = false

    /// Picks up `.disabled(_:)` from the caller so a dimmed, inert row comes for
    /// free rather than each call site handling it.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14)
            } else {
                Image(systemName: symbol)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
            }
            Text(title)
            Spacer()
            if let shortcut {
                // `.tertiary` at 13 pt risks falling under the 4.5:1 contrast
                // minimum the HIG cites for text up to 17 pt.
                Text(shortcut).foregroundStyle(.secondary)
            }
        }
        // The real NSFont.menuFont, so rows match native menus exactly.
        .font(Typography.menuRow)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(RowHighlight())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Cards

/// What the watched accounts amount to together: how many are participating,
/// and the stake and the proposals, which genuinely add up across accounts.
///
/// No countdowns here. A closest deadline without its account is a number with
/// no owner, and each account's row in the list states its own. Every row here
/// is a plain fact: what any of them means is the Attention section's to say.
struct PortfolioCard: View {
    let summary: PortfolioSummary
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Portfolio").font(Typography.sectionHeader).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Spacing.row) {
                HStack(spacing: 6) {
                    Text(participationText).font(Typography.primary.weight(.medium))
                    Spacer()
                    Text(Format.algosLabel(summary.totalStake, hidden: isHidden))
                        .font(Typography.primary.monospacedDigit())
                }

                if summary.hasRewards {
                    ProposalsGrid(
                        proposals24h: summary.proposals24h, earned24h: summary.earned24h,
                        proposals7d: summary.proposals7d, earned7d: summary.earned7d)
                }
                if summary.isTruncated {
                    TruncationNote()
                }
            }
        }
    }

    /// How much of the portfolio is actually participating. An account whose
    /// fetch failed is in neither number, so this counts what is known now.
    private var participationText: String {
        "\(summary.onlineAccounts) of \(quantity(Double(summary.accountCount), "account")) online"
    }
}

/// One watched account's facts: its card and its proposals, or a quiet line
/// when this cycle learned nothing about it. The page it sits on names the
/// account in its header.
struct AccountSection: View {
    /// The cycle, for the round and round time every account shares.
    let update: ChainPoller.Update
    let entry: AccountUpdate
    /// Whether this account's own failure belongs here. False on the single
    /// account page, which states its only account's failure once beneath
    /// everything.
    let statesOwnFailure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let account = entry.account {
                AccountCard(update: update, entry: entry, account: account)
                if let rewards = entry.rewards {
                    RewardsCard(rewards: rewards)
                }
            }
            if statesOwnFailure, let failure = entry.failure {
                FailureLine(failure: failure)
            }
        }
    }
}

struct AccountCard: View {
    /// The cycle, for the round and the round time it shares with every
    /// account, and for the alerts it evaluated.
    let update: ChainPoller.Update
    /// This account's share of that cycle.
    let entry: AccountUpdate
    let account: AccountState
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            // Status and balance on one line. Online, eligibility and overall
            // health are one fact, stated once.
            HStack(spacing: 6) {
                Circle().fill(account.statusTint).frame(width: 8, height: 8)
                Text(account.statusText).font(Typography.primary.weight(.medium))
                Spacer()
                Text(Format.algosLabel(account.amount, hidden: isHidden))
                    .font(Typography.primary.monospacedDigit())
            }

            if let expiry = entry.keyExpiry {
                MeterRow(
                    title: "Participation keys",
                    detail: Format.duration(expiry.timeRemaining(roundTime: update.roundTime)),
                    // Raw; MeterRow clamps and guards non-finite values itself,
                    // so a zero-length window degrades to an empty bar.
                    fraction: Double(max(0, expiry.roundsRemaining)) / Double(expiry.totalRounds),
                    level: level(for: .keyExpiry))
            }

            ValueRow(title: "Last proposed", detail: lastProposedText)

            // Only once some of the allowance is actually spent. On a healthy
            // account the headroom runs to weeks and saying so every poll is
            // noise. The poller derives absence only for Online accounts, so no
            // status check is needed here.
            if let absence = entry.absence, absence.ratio > 0.25 {
                ValueRow(
                    title: "Absence headroom",
                    detail: Format.duration(absence.headroom(roundTime: update.roundTime)),
                    level: level(for: .absenceHeadroom))
            }

            if let challenge = entry.challenge {
                ChallengeRow(
                    challenge: challenge,
                    roundTime: update.roundTime,
                    level: level(for: .challengeFailing))
            }
        }
    }

    /// The account's own clock: how long since the chain last saw it propose.
    /// Compare against the expected interval: for a healthy node this should
    /// sit comfortably below it.
    private var lastProposedText: String {
        guard let proposed = account.lastProposed, proposed > 0,
            let current = update.currentRound, current >= proposed
        else { return "never" }
        let elapsed = Double(current - proposed) * update.roundTime
        return Format.relative(elapsed)
    }

    /// Meter severity is read back from the alerts the engine already produced,
    /// rather than re-deriving thresholds here. Hardcoding the ratios in SwiftUI
    /// would duplicate `AlertThresholds`, so a meter could disagree with its own
    /// notification. Matched on the account as well as the rule, so a meter can
    /// only ever be coloured by an alert about the account it belongs to.
    private func level(for id: AlertID) -> MeterLevel {
        MeterLevel(update.alerts.first { $0.id == id && $0.address == entry.address }?.severity)
    }
}

struct RewardsCard: View {
    let rewards: RewardsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Proposals").font(Typography.sectionHeader).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ProposalsGrid(
                proposals24h: rewards.proposals24h, earned24h: rewards.earned24h,
                proposals7d: rewards.proposals7d, earned7d: rewards.earned7d)

            if rewards.unpaidProposals > 0 {
                Text("\(quantity(Double(rewards.unpaidProposals), "proposal")) earned nothing")
                    .font(Typography.secondary).foregroundStyle(.orange)
            }
            if rewards.isTruncated {
                TruncationNote()
            }
        }
    }
}

/// The 24-hour and 7-day proposal figures.
///
/// A `Grid`, so the counts and the amounts each form their own column and align
/// down the rows. HIG: "Align components with one another to make them easier to
/// scan." Shared by one account's card and the portfolio summary, so the same
/// two figures cannot be laid out or masked two different ways.
struct ProposalsGrid: View {
    let proposals24h: Int
    let earned24h: MicroAlgos
    let proposals7d: Int
    let earned7d: MicroAlgos
    /// Only the ALGO amounts are masked. Masking the block counts too would
    /// leave the rows with nothing to read, and a proposal count still tracks
    /// the account's share of online stake, so this is a screen-sharing
    /// convenience rather than concealment.
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: Spacing.row) {
            row("24h", proposals24h, earned24h)
            row("7d", proposals7d, earned7d)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ span: String, _ blocks: Int, _ earned: MicroAlgos) -> some View {
        GridRow {
            Text(span)
                .font(Typography.primary)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Singular matters: "1 blocks" reads as unfinished.
            Text(quantity(Double(blocks), "block"))
                .font(Typography.primary.monospacedDigit())
                .gridColumnAlignment(.trailing)

            Text(Format.algosLabel(earned, hidden: isHidden))
                .font(Typography.primary.monospacedDigit())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Says that the proposal figures above are a floor. Shared, so the caveat
/// cannot be worded one way for an account and another for the portfolio.
struct TruncationNote: View {
    var body: some View {
        Text("Recent proposals may be missing, so these totals are a minimum.")
            .font(Typography.secondary).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AlertsCard: View {
    let alerts: [HealthAlert]
    /// Whether an entry names the account it holds for. Only past one watched
    /// account: with a single one there is nothing to tell apart, and the
    /// address would be a label on the only thing it could be about.
    let namesAccounts: Bool
    /// Opens the account an entry holds for. When set, each entry about an
    /// account becomes a row that leads to it, the way the list's rows do.
    var open: ((AlgorandAddress) -> Void)?
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Attention").font(Typography.sectionHeader).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            // Alerts sit a row apart from each other, but only `heading` below
            // the title, so the title binds to the list rather than floating
            // between it and whatever is above. Rows that lead somewhere carry
            // their own padding for the highlight, so they sit closer.
            VStack(alignment: .leading, spacing: open == nil ? Spacing.row : 2) {
                // Keyed on rule *and* account: the same condition can hold for
                // several accounts at once, and a repeated identity would let
                // SwiftUI drop all but one of them.
                ForEach(alerts, id: \.key) { alert in
                    if let open, let address = alert.address {
                        Button {
                            open(address)
                        } label: {
                            entry(alert, leadsToAccount: true)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .modifier(RowHighlight())
                        }
                        .buttonStyle(.plain)
                    } else if open != nil {
                        // About the watch rather than an account, so it leads
                        // nowhere, but it lines up with the rows that do.
                        entry(alert, leadsToAccount: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    } else {
                        entry(alert, leadsToAccount: false)
                    }
                }
            }
            // A highlight wider than the text, as a menu item's is, while the
            // text stays aligned with the title above it.
            .padding(.horizontal, open == nil ? 0 : -8)
        }
    }

    private func entry(_ alert: HealthAlert, leadsToAccount: Bool) -> some View {
        let level = MeterLevel(alert.severity)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: level.alertSymbol)
                .foregroundStyle(level.tint)
                .font(Typography.primary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(alert.title).font(Typography.primary.weight(.medium))
                    if namesAccounts, let address = alert.address {
                        Text(
                            Format.addressLabel(
                                address.stringValue, hidden: isHidden)
                        )
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                    }
                    if leadsToAccount {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(Typography.secondary)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(alert.body)
                    .font(Typography.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every watched account, one row each, in Settings order, each leading to its
/// own page. The rows state facts; what any of them means is the Attention
/// section's to say, which is why the list opens with it.
struct AccountsCard: View {
    let update: ChainPoller.Update
    /// Everything the Attention section lists. Each row grades itself from the
    /// alerts about its own account.
    let alerts: [HealthAlert]
    let open: (AlgorandAddress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Accounts").font(Typography.sectionHeader).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 2) {
                ForEach(update.entries, id: \.address) { entry in
                    AccountRow(
                        update: update, entry: entry,
                        alerts: alerts.about(entry.address, includingWatchAlerts: false)
                    ) {
                        open(entry.address)
                    }
                }
            }
            // A highlight wider than the text, as a menu item's is, while the
            // text stays aligned with the title above it.
            .padding(.horizontal, -8)
        }
    }
}

/// One account at a glance: its grade, its status and key countdown, its stake.
///
/// The glyph carries the grade in shape as well as colour, the same shapes as
/// the menu bar icon, for anyone who cannot tell the colours apart. Elsewhere
/// colour marks only the fact an alert names, as on the account's card: the key
/// countdown takes the key alert's tint, and the status takes the grade's tint
/// only when the account is not online and something is wrong.
struct AccountRow: View {
    let update: ChainPoller.Update
    let entry: AccountUpdate
    /// This account's own alerts. An alert about the watch concerns every
    /// account alike, so it grades none of them.
    let alerts: [HealthAlert]
    let open: () -> Void
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: health.symbol)
                    .font(Typography.secondary)
                    .foregroundStyle(health.tint)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.addressLabel(entry.address.stringValue, hidden: isHidden))
                        .font(Typography.primary.weight(.medium))
                    facts.font(Typography.secondary)
                }

                Spacer()

                if let account = entry.account {
                    Text(Format.algosLabel(account.amount, hidden: isHidden))
                        .font(Typography.secondary.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(Typography.secondary)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .modifier(RowHighlight())
        }
        .buttonStyle(.plain)
        // One element read as a sentence, rather than five fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
    }

    private var health: HealthLevel {
        HealthLevel(worstOf: alerts.map(\.severity), hasData: entry.account != nil)
    }

    /// The status, then the key countdown, coloured fact by fact.
    private var facts: Text {
        guard let account = entry.account else {
            return Text(entry.failure?.message ?? "No data").foregroundColor(.secondary)
        }
        let statusColor: Color =
            account.status != .online && health > .ok ? health.tint : .secondary
        var text = Text(account.statusText).foregroundColor(statusColor)
        if let keysText {
            text =
                text + Text(" · ").foregroundColor(.secondary)
                + Text(keysText).foregroundColor(keysLevel.textTint ?? .secondary)
        }
        return text
    }

    private var keysText: String? {
        entry.keyExpiry.map {
            "keys \(Format.duration($0.timeRemaining(roundTime: update.roundTime)))"
        }
    }

    /// Read back from the alert the engine produced, as the card's meter is,
    /// so the row and the notification can never disagree.
    private var keysLevel: MeterLevel {
        MeterLevel(alerts.first { $0.id == .keyExpiry }?.severity)
    }

    private var spoken: String {
        var parts = [Format.addressLabel(entry.address.stringValue, hidden: isHidden)]
        if let account = entry.account {
            parts.append(account.statusText)
            if let keysText { parts.append(keysText) }
        } else {
            parts.append(entry.failure?.message ?? "No data")
        }
        if let grade = MeterLevel(alerts.map(\.severity).max()).spoken {
            parts.append(grade)
        }
        return parts.joined(separator: ", ")
    }
}

/// An account's short address as a title, with the full address one right
/// click away.
struct AddressTitle: View {
    let address: String
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        Text(Format.addressLabel(address, hidden: isHidden))
            .font(Typography.primary)
            .textSelection(.enabled)
            // Selecting the text only yields the abbreviated form, which no
            // explorer accepts, so the menu offers the full address.
            // Deliberately available while values are hidden: the mask guards
            // against onlookers, and the clipboard is not on screen.
            .contextMenu {
                Button("Copy Address") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(address, forType: .string)
                }
            }
    }
}

/// A failure, stated quietly beside the figures it affects.
struct FailureLine: View {
    let failure: PollFailure

    var body: some View {
        Label(failure.message, systemImage: "wifi.exclamationmark")
            .font(Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps the list within the screen. Past the visible height, the content
/// scrolls between the header and the footer, instead of pushing the bottom of
/// the panel, and with it Settings and Quit, off the screen.
private struct ScreenCapped<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        CappedHeight(limit: Self.limit) {
            // Measured, never drawn: a scroll view reports a small ideal height,
            // so the content's own height has to come from a copy of it.
            content.hidden()
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The visible screen height, less room for the header, the footer and a
    /// margin below the menu bar.
    private static var limit: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 220
    }
}

/// Takes its first subview's natural height, up to a limit, and gives that
/// whole space to its second subview.
///
/// Measured within the same layout pass, so the height is right from the first
/// layout, rather than corrected by a state change one update later.
private struct CappedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, limit))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Keeps the panel's window at its content's height, hanging from the menu
/// bar, and runs an action when the panel closes.
///
/// A menu bar panel keeps its window height when its content changes height
/// while it is open, and SwiftUI centres the content in the space, leaving
/// bands above and below it. So the window is resized here instead. AppKit
/// resizes a window about its bottom edge, so the origin moves with the height
/// to keep the top edge where it is, under the menu bar.
///
/// SwiftUI exposes no window for a menu bar panel, so the window is reached
/// through an invisible AppKit view planted behind the content, and only that
/// one window is observed.
private struct PanelWindowKeeper: NSViewRepresentable {
    let contentHeight: CGFloat
    /// HIG: animate a popover's size change "to avoid giving the impression
    /// that a new popover replaced the old one". Off under Reduce Motion.
    let animates: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.onClose = onClose
        view.fit(to: contentHeight, animated: animates)
    }

    final class KeeperView: NSView {
        var onClose: () -> Void = {}
        private var observer: (any NSObjectProtocol)?
        /// Whether the window has been fitted since the panel last opened. The
        /// first fit of each opening is immediate: there is no earlier size
        /// on screen for an animation to start from.
        private var hasFitted = false

        // The view has no window at construction, so the observation starts
        // once it is placed in one, and moves with it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            // The panel resigns key as it closes.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                // Posted on the main thread, where this view and the model live.
                MainActor.assumeIsolated {
                    self?.hasFitted = false
                    self?.onClose()
                }
            }
        }

        /// Sizes the window so the space SwiftUI gives the panel matches the
        /// content. This view sits behind a frame that fills that space, so its
        /// own height is the space, whatever the window wraps around it.
        func fit(to height: CGFloat, animated: Bool) {
            guard height > 0, bounds.height > 0, let window else { return }
            let change = height - bounds.height
            guard abs(change) > 0.5 else { return }
            var frame = window.frame
            let top = frame.maxY
            frame.size.height += change
            frame.origin.y = top - frame.size.height
            if animated, hasFitted, window.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    window.animator().setFrame(frame, display: true)
                }
            } else {
                window.setFrame(frame, display: true)
            }
            hasFitted = true
        }
    }
}

// MARK: - Pieces

/// A label and a value, no gauge, for quantities that have no meaningful
/// "full", like time since the last proposal.
struct ValueRow: View {
    let title: String
    let detail: String
    /// Severity of the alert that names this row, if any. Colours the value and
    /// is spoken after it.
    var level: MeterLevel = .normal

    var body: some View {
        HStack {
            Text(title).font(Typography.primary)
            Spacer()
            Text(detail)
                .font(Typography.primary.monospacedDigit())
                .foregroundStyle(level.valueStyle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(level.spokenValue(for: detail))
    }
}

/// Where the account stands with the current heartbeat challenge.
///
/// A challenge is issued every 1000 rounds and answered by the node's own
/// heartbeat, so most of the time this row reports a routine fact. Four short
/// values, one per state, keep it a value like any other; what any of them
/// means for the account is the Attention section's job to say.
struct ChallengeRow: View {
    let challenge: ChallengeState
    let roundTime: TimeInterval
    /// Read back from the alert the engine produced, so the row and the
    /// notification can never disagree about how serious this is.
    let level: MeterLevel

    var body: some View {
        ValueRow(title: "Challenge", detail: detail, level: level)
    }

    private var detail: String {
        guard challenge.isChallenged else { return "not selected" }
        guard challenge.isFailing else { return "answered" }
        // Past the grace period `Format.duration` reads "overdue" on its own.
        return challenge.phase == .enforcing
            ? "overdue"
            : "\(Format.duration(challenge.timeUntilDeadline(roundTime: roundTime))) to answer"
    }
}

/// A capacity gauge, deliberately not a `ProgressView`.
///
/// HIG: "All progress indicators are transient, appearing only while an
/// operation is ongoing and disappearing after it completes." Key validity and
/// absence headroom are standing state, not tasks, so a progress bar is the
/// wrong component. A gauge in the capacity style is the right one: "a fill that
/// stops at the value's location on the path."
struct MeterRow: View {
    let title: String
    let detail: String
    let fraction: Double
    let level: MeterLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title).font(Typography.primary)
                Spacer()
                Text(detail)
                    .font(Typography.primary.monospacedDigit())
                    .foregroundStyle(level.valueStyle)
            }
            // An empty label, not `.labelsHidden()`: that modifier does not
            // suppress a Gauge's label in the capacity style, which would draw
            // the title a second time above the bar.
            Gauge(value: fraction.isFinite ? min(max(fraction, 0), 1) : 0) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(level.tint)
        }
        // Collapse to one element so VoiceOver reads "Participation keys, 66
        // days" rather than spelling out the bar's raw fraction.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(level.spokenValue(for: detail))
    }
}
