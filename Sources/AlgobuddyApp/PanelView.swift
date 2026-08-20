import AlgobuddyCore
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel

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
        .environment(\.valuesHidden, model.valuesHidden)
    }

    @ViewBuilder
    private var content: some View {
        header
        Divider()

        if let update = model.display, let account = update.account {
            // Unscrolled for the same reason as SettingsView. Content here does
            // vary (the alert list grows), so the window grows with it. A taller
            // panel when several alerts hold reads far better than a short one
            // that always scrolls, and it keeps the common case scrollbar-free.
            // Spacing separates the groups. Dividers are reserved for the
            // structural split between the panel's chrome and its content.
            VStack(alignment: .leading, spacing: Spacing.group) {
                AccountCard(update: update, account: account)
                if let rewards = update.rewards {
                    RewardsCard(rewards: rewards)
                }
                // visibleAlerts, not this update's own list: during an outage
                // the displayed data is the last good poll, and the outage
                // alert colouring the menu bar icon lives on the latest failed
                // one. The card must be able to explain the icon.
                if !model.visibleAlerts.isEmpty {
                    AlertsCard(alerts: model.visibleAlerts)
                }
                // Degradation, stated rather than implied. Partial failures
                // (supply, challenge seed, rewards) ride on successful polls
                // with a fresh header age and no alert of their own, so this
                // line is the only sign some figures are stale or missing. A
                // wholly failed poll leaves the cards above showing the last
                // good data, aging in the header; this line names the reason.
                if let failure = model.update?.failure {
                    Label(failure.message, systemImage: "wifi.exclamationmark")
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.edge)
        } else {
            waiting
        }
    }

    /// Identity and freshness only. The account's status belongs to the card
    /// below, stated once rather than repeated here as a second indicator.
    private var header: some View {
        HStack(spacing: 8) {
            // The applied address: a half-typed Settings draft must not head
            // another account's figures. The edit buffer stands in only when
            // nothing has been applied, which cannot happen while the header
            // shows, because a running watch always has an applied address.
            Text(
                model.valuesHidden
                    ? Format.hidden() : Format.address(model.watchedAddress ?? model.addressText)
            )
            .font(Typography.primary)
            .textSelection(.enabled)
            // Selecting the header text only yields the abbreviated form,
            // which no explorer accepts, so the menu offers the full address.
            // Deliberately available while values are hidden: the mask guards
            // against onlookers, and the clipboard is not on screen.
            .contextMenu {
                Button("Copy Address") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        model.watchedAddress ?? model.addressText, forType: .string)
                }
            }
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

    @State private var isHovering = false
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
        // Without this the row only responds where there is ink.
        .contentShape(Rectangle())
        // `.quaternary` rather than a hand-picked `Color.primary.opacity(0.09)`:
        // the hierarchical styles have vibrant variants and respond to Increase
        // Contrast and Reduce Transparency. A fixed alpha over a material does
        // neither, and the panel sits on a material.
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Cards

struct AccountCard: View {
    let update: ChainPoller.Update
    let account: AccountState
    @Environment(\.valuesHidden) private var isHidden

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            // Status and balance on one line. Online, eligibility and overall
            // health are one fact, stated once.
            HStack(spacing: 6) {
                Circle().fill(statusTint).frame(width: 8, height: 8)
                Text(statusText).font(Typography.primary.weight(.medium))
                Spacer()
                Text(Format.algosLabel(account.amount, hidden: isHidden))
                    .font(Typography.primary.monospacedDigit())
            }

            if let expiry = update.keyExpiry {
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
            if let absence = update.absence, absence.ratio > 0.25 {
                ValueRow(
                    title: "Absence headroom",
                    detail: Format.duration(absence.headroom(roundTime: update.roundTime)),
                    level: level(for: .absenceHeadroom))
            }

            if let challenge = update.challenge {
                ChallengeRow(
                    challenge: challenge,
                    roundTime: update.roundTime,
                    level: level(for: .challengeFailing))
            }
        }
    }

    private var statusText: String {
        switch account.status {
        case .online:
            return account.incentiveEligible == true ? "Online and earning" : "Online, not earning"
        case .offline: return "Offline"
        case .notParticipating: return "Not participating"
        }
    }

    private var statusTint: Color {
        switch account.status {
        case .online: return account.incentiveEligible == true ? .green : .orange
        case .offline: return .red
        case .notParticipating: return .secondary
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
    /// notification.
    private func level(for id: AlertID) -> MeterLevel {
        MeterLevel(update.alerts.first(where: { $0.id == id })?.severity)
    }
}

struct RewardsCard: View {
    let rewards: RewardsSummary
    /// Only the ALGO amounts are masked. Masking the block counts too would
    /// leave the card with nothing to read, and a proposal count still tracks
    /// the account's share of online stake, so this is a screen-sharing
    /// convenience rather than concealment.
    @Environment(\.valuesHidden) private var isHidden

    /// A `Grid`, so the counts and the amounts each form their own column and
    /// align down the rows. HIG: "Align components with one another to make them
    /// easier to scan."
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Proposals").font(Typography.sectionHeader).foregroundStyle(.secondary)

            Grid(horizontalSpacing: 10, verticalSpacing: Spacing.row) {
                row("24h", rewards.proposals24h, rewards.earned24h)
                row("7d", rewards.proposals7d, rewards.earned7d)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if rewards.unpaidProposals > 0 {
                Text("\(quantity(Double(rewards.unpaidProposals), "proposal")) earned nothing")
                    .font(Typography.secondary).foregroundStyle(.orange)
            }
            if rewards.isTruncated {
                Text("Recent proposals may be missing, so these totals are a minimum.")
                    .font(Typography.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

struct AlertsCard: View {
    let alerts: [HealthAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text("Attention").font(Typography.sectionHeader).foregroundStyle(.secondary)

            // Alerts sit a row apart from each other, but only `heading` below
            // the title, so the title binds to the list rather than floating
            // between it and whatever is above.
            VStack(alignment: .leading, spacing: Spacing.row) {
                ForEach(alerts, id: \.id) { alert in
                    let level = MeterLevel(alert.severity)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: level.alertSymbol)
                            .foregroundStyle(level.tint)
                            .font(Typography.primary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title).font(Typography.primary.weight(.medium))
                            Text(alert.body)
                                .font(Typography.secondary).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
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
