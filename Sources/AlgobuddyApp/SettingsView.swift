import AlgobuddyCore
import SwiftUI

/// First run, shown in the panel. The whole setup is one field.
///
/// algobuddy needs no node, no token and no account, which is the point: the app
/// should be useful before the user has been asked to trust it with anything.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: AddressDraft.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch a participation account")
                .font(Typography.primary.weight(.semibold))
            // "No keys", not "nothing stored": the address is saved to this
            // Mac's preferences, and claiming otherwise would be false.
            Text(
                "Paste an Algorand address. Everything below comes from public chain data. No node, no token, no keys to hold."
            )
            .font(Typography.primary).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // One field on first run, whatever the app can watch afterwards:
            // an account to start with is the whole of the setup, and the list
            // is edited in Settings once there is something to compare against.
            AddressField(
                draft: $model.addressDrafts[0], focus: $focused,
                isMasked: model.valuesHidden
            ) { model.apply() }

            // Without this, a bad stored URL would make Start a silent no-op:
            // the panel has no URL fields, so the reason, and the pane that
            // holds them, has to be said here.
            if let error = model.sourceError {
                Text("\(error) Fix it in Settings (⌘,), under Data Source.")
                    .font(Typography.secondary).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // A prominent default button is right here: this is a genuine
                // primary action on first run, and Return should trigger it.
                Button("Start") { model.apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.addressDrafts[0].text
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }
}

/// The Settings window's content: four panes, each a group of related
/// settings, chosen from the window's toolbar.
///
/// A `TabView` in a Settings scene is what gives the native settings window: a
/// toolbar of panes that always shows the active one, and a window titled
/// after that pane. Each pane is a `Form` with `.formStyle(.grouped)`, which is
/// what gives the native System Settings appearance: grouped sections and
/// correct control sizing. Where a pane sets text fields beside their labels,
/// a `Grid` holds the labels in one column, so the fields line up.
///
/// Changes take effect as they are made, as macOS settings do, rather than
/// behind an Apply button. Text fields commit on Return, on focus loss, on a
/// switch to another pane, and when the window closes, rather than on every
/// keystroke, which would restart the poller with each character of a URL.
struct SettingsView: View {
    @Bindable var model: AppModel
    /// HIG: "Restore the most recently viewed pane." Settings are often
    /// adjusted more than once, so the window opens where it was left.
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    /// The tallest a pane can be, which the window measures on its screen.
    @State private var paneHeightLimit = FitsScreenHeight.estimatedLimit

    var body: some View {
        TabView(selection: $pane) {
            GeneralPane(model: model)
                .modifier(PaneLayout(heightLimit: paneHeightLimit))
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)
            AccountsPane(model: model)
                .modifier(PaneLayout(heightLimit: paneHeightLimit))
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsPane.accounts)
            MenuBarPane(model: model)
                .modifier(PaneLayout(heightLimit: paneHeightLimit))
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsPane.menuBar)
            DataSourcePane(model: model)
                .modifier(PaneLayout(heightLimit: paneHeightLimit))
                .tabItem { Label("Data Source", systemImage: "server.rack") }
                .tag(SettingsPane.dataSource)
        }
        // A switch to another pane takes the field being typed in away
        // without moving focus out of it, so the edit is committed here, as it
        // would be on leaving the field.
        .onChange(of: pane) { model.apply() }
        .background(
            SettingsWindowKeeper(
                onHeightLimit: { paneHeightLimit = $0 },
                // Closing the window commits too. Dismissing the window does
                // not move focus out of the field being typed in, so without
                // this an address entered and then dismissed would sit in the
                // edit buffer, watched by nothing, until the window was next
                // opened.
                onClose: { model.apply() }))
    }
}

/// The panes, in toolbar order. Stored by raw value, and a stored value that
/// names no pane opens General.
private enum SettingsPane: String {
    case general, accounts, menuBar, dataSource
}

/// What belongs to the app itself rather than to what it watches: how it
/// starts, whether it notifies, and which build it is.
private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LaunchAtLoginRow(model: model)
                NotificationsRow(model: model)
            }
            VersionFooter(model: model)
        }
    }
}

/// The watched accounts, in the order every other surface presents them, and
/// the one pane that grows with use.
///
/// Uncapped, like the menu bar metrics, and for the same reason: every address
/// adds its fetches to each cycle, and that trade is the user's to make. The
/// cost is stated rather than prevented.
private struct AccountsPane: View {
    @Bindable var model: AppModel
    /// Focus is owned here rather than by each row, so that a newly added row
    /// can be typed into straight away and so that leaving any row commits it.
    @FocusState private var focused: AddressDraft.ID?
    /// The name fields' focus, kept apart from the address fields' because
    /// `AddressField` also serves onboarding, which asks for no name.
    @FocusState private var focusedName: AddressDraft.ID?

    /// The rows that name an account an earlier row already watches, by the
    /// rule the list is resolved by, so a row the watch drops is marked here
    /// too. Compared as addresses rather than as text, so a repeat pasted in
    /// another case is still caught. Silently watching such a row once and
    /// showing it twice here would leave the user with no way to tell why
    /// nothing happened.
    private var repeats: Set<AddressDraft.ID> {
        let drafts = model.addressDrafts
        let rows = drafts.map { WatchList.Row(text: $0.text, held: $0.held) }
        return Set(WatchList.repeats(rows).map { drafts[$0].id })
    }

    /// The only row, holding no text, no name and no account. It is where the
    /// next address is typed, and removing it would leave the same blank row.
    private func isLoneBlankRow(_ draft: AddressDraft) -> Bool {
        model.addressDrafts.count == 1 && draft.held == nil && draft.name.isEmpty
            && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let repeats = self.repeats

        Form {
            ForEach($model.addressDrafts) { $draft in
                // A box for each account keeps each name with its own address.
                Section {
                    // The labels in a column of their own and each field
                    // filling the rest, as in the Data Source pane, so the
                    // fields keep one width whatever is typed.
                    Grid(
                        alignment: .leadingFirstTextBaseline, horizontalSpacing: 8,
                        verticalSpacing: 4
                    ) {
                        GridRow {
                            FieldLabel("Address")
                            AddressField(
                                draft: $draft, focus: $focused, isMasked: model.valuesHidden,
                                isRepeat: repeats.contains(draft.id)
                            ) { model.apply() }
                            .labelsHidden()
                        }
                        GridRow {
                            FieldLabel("Name")
                            HStack(spacing: 8) {
                                // Never masked: a name is the user's own label,
                                // and what tells the accounts apart while
                                // values are hidden.
                                TextField(
                                    "Name", text: $draft.name, prompt: Text("Optional")
                                )
                                .labelsHidden()
                                .font(Typography.primary)
                                .focused($focusedName, equals: draft.id)
                                .onSubmit { model.apply() }
                                // Cut as it is typed, so the field never shows
                                // more than the name that is kept.
                                .onChange(of: draft.name) { _, name in
                                    if name.count > AccountNames.maxLength {
                                        draft.name = String(name.prefix(AccountNames.maxLength))
                                    }
                                }
                                // HIG: "match the size of a text field to the
                                // quantity of anticipated text." Wide enough
                                // for a typical name of the full length.
                                .frame(width: 220)

                                Spacer()

                                // In words rather than as a symbol, which on
                                // its own would leave the button's purpose to
                                // be guessed.
                                Button("Remove") { model.removeAddressRow(draft.id) }
                                    .disabled(isLoneBlankRow(draft))
                                    .accessibilityLabel("Remove this account")
                            }
                        }
                    }
                } footer: {
                    // Below the last account, where the next one is added.
                    if draft.id == model.addressDrafts.last?.id {
                        VStack(alignment: .leading, spacing: Spacing.row) {
                            Button("Add Account", systemImage: "plus") {
                                focused = model.addAddressRow()
                            }

                            // The consequence, said plainly, in place of a
                            // limit nobody asked for. Nothing else about the
                            // app changes with the count: the same two hosts
                            // are contacted whatever it is.
                            Text(
                                "Every account adds a request to each poll, and a poll runs about every 30 s."
                            )
                            .font(Typography.secondary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            // Hiding values masks addresses and amounts but
                            // not names, which would otherwise come as a
                            // surprise during a screen share.
                            Text(
                                "Names stay on this Mac, and stay visible while values are hidden."
                            )
                            .font(Typography.secondary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        // Leaving a row commits it, the same contract as the URL fields;
        // apply() never tears down a running watch over an invalid or empty
        // draft, so this is always safe.
        .onChange(of: focused) { old, _ in
            if old != nil { model.apply() }
        }
        .onChange(of: focusedName) { old, _ in
            if old != nil { model.apply() }
        }
    }
}

/// What the menu bar item shows.
private struct MenuBarPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                MenuBarMetricPicker(model: model)
            }
        }
    }
}

/// Where the chain data comes from, and what that choice reveals.
private struct DataSourcePane: View {
    @Bindable var model: AppModel

    private enum URLField {
        case algod, indexer
    }
    @FocusState private var focusedURL: URLField?

    var body: some View {
        Form {
            Section {
                // The labels in a column of their own, and each field filling
                // the rest of the row. In the form's own row, a bordered field
                // moves below its label once its text is longer than the
                // field, which changes the row's height as a long URL is typed.
                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8
                ) {
                    GridRow {
                        FieldLabel("algod")
                        TextField("algod", text: $model.algodURLText)
                            .labelsHidden()
                            .focused($focusedURL, equals: .algod)
                            .onSubmit { model.apply() }
                    }
                    GridRow {
                        FieldLabel("indexer")
                        TextField("indexer", text: $model.indexerURLText)
                            .labelsHidden()
                            .focused($focusedURL, equals: .indexer)
                            .onSubmit { model.apply() }
                    }
                }

                // The error belongs to these fields, so it renders here rather
                // than under the address input in another pane.
                if let error = model.sourceError {
                    Text(error).font(Typography.secondary).foregroundStyle(.red)
                }

                // Stated plainly rather than buried: this is the one privacy
                // trade the default configuration makes.
                Text(
                    "A public provider sees which address you watch and how often. Point these at your own node to avoid that."
                )
                .font(Typography.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Leaving a field commits it, the same contract as AddressField: an
        // edit abandoned by clicking elsewhere must not sit in the bound text
        // diverging from what the poller runs. apply() ignores a commit that
        // changes nothing and never tears down a running watch over an invalid
        // draft, so focus movement is always safe.
        .onChange(of: focusedURL) { old, _ in
            if old != nil { model.apply() }
        }
    }
}

/// What every pane shares.
private struct PaneLayout: ViewModifier {
    let heightLimit: CGFloat

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            // A grouped form otherwise draws a text field as plain text, which
            // reads as a label rather than as somewhere to type.
            .textFieldStyle(.roundedBorder)
            // The form takes one height whatever the window offers, so
            // `.windowResizability(.contentSize)` fits the window to it
            // exactly, and the form scrolls only when the screen is too short
            // for it. One width for every pane, so a switch changes only the
            // window's height.
            .modifier(FitsScreenHeight(limit: heightLimit))
            .frame(width: 480)
    }
}

/// A text field's label, set in a column of its own beside the field.
///
/// The field keeps its own label, hidden on screen, and that is the one
/// VoiceOver reads, so this one is hidden from VoiceOver rather than read twice.
private struct FieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).accessibilityHidden(true)
    }
}

/// Gives a pane its content's height, up to the height of the window's screen
/// less the window's title bar and toolbar. Every account adds a row, and a
/// window taller than the screen leaves its lower controls out of reach.
private struct FitsScreenHeight: ViewModifier {
    let limit: CGFloat

    func body(content: Content) -> some View {
        Fit(limit: limit) { content }
    }

    /// Asked for its size with no height proposed, a grouped form answers with
    /// its content's height, so it is measured there and placed at no more
    /// than the limit, where it scrolls. Unlike the panel's scroll view, the
    /// form needs no hidden copy to be measured.
    private struct Fit: Layout {
        let limit: CGFloat

        func sizeThatFits(
            proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) -> CGSize {
            let natural = subviews[0].sizeThatFits(
                ProposedViewSize(width: proposal.width, height: nil))
            // Rounded up to a whole point. The window's frame is in whole
            // points and rounds a fraction either way, depending on the pane
            // shown before, so the same pane would otherwise open a point
            // taller one time than another.
            return CGSize(
                width: proposal.width ?? natural.width,
                height: min(natural.height.rounded(.up), limit))
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    /// The main screen less a title bar, until the window has measured its
    /// own screen, title bar and toolbar.
    static var estimatedLimit: CGFloat {
        let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
        return (NSScreen.main?.visibleFrame.height ?? 800) - titleBar
    }
}

/// Keeps the Settings window whole on its screen as it resizes, tells the
/// panes how tall they can be there, and runs a commit when the window is
/// about to close.
///
/// SwiftUI has no window lifecycle to hook from a Settings scene, so the
/// window is reached through an invisible AppKit view planted behind the
/// panes. The commit observes that one window only, so the panel opening and
/// closing all day never triggers it.
private struct SettingsWindowKeeper: NSViewRepresentable {
    /// Receives the tallest a pane can be on the window's screen.
    let onHeightLimit: (CGFloat) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.onHeightLimit = onHeightLimit
        view.onClose = onClose
    }

    /// The planted view. It has no window until AppKit places it in a
    /// hierarchy, which is why the observers are registered from
    /// `viewDidMoveToWindow` rather than at construction, and removed there
    /// when the view leaves a window so no observation outlives the window.
    final class KeeperView: NSView {
        var onHeightLimit: (CGFloat) -> Void = { _ in }
        var onClose: () -> Void = {}
        private var observers: [any NSObjectProtocol] = []
        private var reportedLimit: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            // Each is posted on the main thread, where this view and the model
            // live.
            observers = [
                center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                },
                center.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fit() }
                },
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fit() }
                },
                // A change to the displays, such as another resolution, moves
                // the screen's edges without resizing the window.
                center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fit() }
                },
            ]
            // Measured as the view joins the window, and again after every
            // resize and every change of screen.
            fit()
        }

        private func fit() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let chrome = window.frame.height - window.contentLayoutRect.height
            let limit = visible.height - chrome
            if limit != reportedLimit {
                reportedLimit = limit
                // Set after the current update: the limit is SwiftUI state,
                // and a resize can be reported while SwiftUI is updating.
                DispatchQueue.main.async { [weak self] in self?.onHeightLimit(limit) }
            }
            // The window takes each pane's height from its top edge, so a
            // taller pane, or another account, can take its bottom below the
            // screen's. It moves up just far enough to stay whole.
            let frame = window.frame
            if frame.minY < visible.minY {
                window.setFrameOrigin(
                    NSPoint(x: frame.minX, y: min(visible.minY, visible.maxY - frame.height)))
            }
        }
    }
}

/// The stamped build identity and a manual update check.
///
/// The app is installed by building from source, so nobody learns that a newer
/// release exists unless they revisit the repository. The check is manual and
/// says so: one request, when the button is clicked, and never otherwise.
struct VersionFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            // A version number on releases, a commit hash on development
            // builds, so a bug report can name the exact build. Absent under
            // `swift run`, where no bundle exists; the check still works there
            // and reports that it cannot compare.
            if let version = model.appVersion {
                Text("algobuddy \(version)")
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Check for Updates") { model.checkForUpdates() }
                    .disabled(model.isCheckingForUpdates)
                if model.isCheckingForUpdates {
                    // A spinner beside the control it belongs to, and unlabelled:
                    // on macOS the indicator itself says that work is in flight,
                    // and a word next to it repeats what the dimmed button has
                    // already said. The accessibility label is not shown, and
                    // exists because a bare indicator otherwise announces
                    // nothing about what is being waited on.
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for updates.")
                } else if let status = model.updateStatus {
                    UpdateResult(status: status)
                }
            }

            // The same disclosure the Data Source pane makes: the one place
            // this pane reaches a host the user did not configure.
            Text("The check contacts github.com, and only when you click.")
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One line of text beside the button. Never an alert and never a
/// notification: the user asked a question and is standing right here for the
/// answer.
private struct UpdateResult: View {
    let status: UpdateStatus

    var body: some View {
        switch status {
        case .upToDate:
            Text("Up to date.")
                .font(Typography.secondary).foregroundStyle(.secondary)
        case .updateAvailable(let version, let url):
            // The link opens the release page in the browser. Downloading and
            // installing stays a deliberate `git pull && make install`, which
            // is what keeps the app something that never fetches code.
            LinkedResult(
                leading: "Version", linkTitle: version, trailing: "is available.", url: url,
                spoken: "Version \(version) is available.")
        case .cannotCompare(let latest, let url):
            // Never "up to date" without evidence: this build carries no
            // version to compare, so the latest release is named and the user
            // decides.
            LinkedResult(
                leading: "Latest release is", linkTitle: latest, url: url,
                spoken: "Latest release is \(latest).")
        case .failed(let message):
            // Red, the same convention the login item error uses, so this pane
            // marks a failure one way. The message is a whole sentence and
            // carries the outcome by itself, because a colour is not readable
            // to everyone and is not a message.
            Text(message).font(Typography.secondary).foregroundStyle(.red)
        }
    }
}

/// A result line built around the release link.
///
/// VoiceOver treats a row of text views as separate elements, so the line is
/// otherwise read out as fragments. The words around the link are hidden from
/// it and the sentence they form becomes the link's own label, which leaves one
/// element that reads the whole line and can still be focused and opened.
private struct LinkedResult: View {
    let leading: String
    let linkTitle: String
    var trailing: String?
    let url: URL
    /// The line as one sentence, for VoiceOver.
    let spoken: String

    var body: some View {
        HStack(spacing: 4) {
            Text(leading)
                .font(Typography.secondary).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Link(linkTitle, destination: url)
                .font(Typography.secondary)
                .accessibilityLabel(spoken)
            if let trailing {
                Text(trailing)
                    .font(Typography.secondary).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// On by default, and routed through the model so turning it on can request
/// system authorisation right now, not at the next address submit.
struct NotificationsRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Checkbox, not a switch: switches are the iOS idiom, and macOS
            // settings use checkboxes.
            Toggle(
                "Notify on alerts",
                isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotifications(enabled: $0) })
            )
            .toggleStyle(.checkbox)

            // The toggle states what the user wants, not what macOS allows, so
            // a refusal is said beside it.
            if model.notificationsBlocked {
                HStack(spacing: 6) {
                    Text("Notifications for algobuddy are off in System Settings.")
                        .font(Typography.secondary).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notifications") { model.openNotificationSettings() }
                        .buttonStyle(.link).font(Typography.secondary)
                }
            }
        }
    }
}

/// Opt-in, off by default. Nothing should add itself to a person's login items
/// without being asked.
///
/// `SMAppService` is the source of truth rather than a stored preference: the
/// user can revoke this from System Settings at any time, and a cached boolean
/// would then be a lie.
struct LaunchAtLoginRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) })
            )
            .toggleStyle(.checkbox)
            .disabled(!model.canLaunchAtLogin)

            if model.loginItemNeedsApproval {
                HStack(spacing: 6) {
                    Text("Waiting for approval in System Settings.")
                        .font(Typography.secondary).foregroundStyle(.orange)
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                        .buttonStyle(.link).font(Typography.secondary)
                }
            }

            if let error = model.loginItemError {
                Text(error).font(Typography.secondary).foregroundStyle(.red)
            }

            // The registration points at wherever the app currently sits, so a
            // copy running from a build directory quietly breaks the next time
            // that path changes.
            if model.canLaunchAtLogin && !model.isInstalledInApplications {
                Text(
                    "algobuddy isn't in an Applications folder. Login items record the app's current location, so move it there with `make install` before relying on this."
                )
                .font(Typography.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Validates as you type, using the same checksum the protocol uses.
///
/// A transposed character produces a well-formed address for an account that
/// isn't yours, which would otherwise show a permanently healthy panel while
/// the real account went unwatched.
struct AddressField: View {
    @Binding var draft: AddressDraft
    var focus: FocusState<AddressDraft.ID?>.Binding
    /// Masked while values are hidden, since this is the one surface that
    /// shows an address in full.
    var isMasked = false
    /// Whether an earlier row already names this account.
    var isRepeat = false
    let onCommit: () -> Void

    private var validity: (symbol: String, tint: Color, note: String?)? {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try AlgorandAddress(trimmed)
            if isRepeat {
                return ("exclamationmark.circle.fill", .orange, "Already in the list")
            }
            return ("checkmark.circle.fill", .green, nil)
        } catch AlgorandAddress.AddressError.badLength(let count) {
            return ("circle.dotted", .secondary, "\(count)/58 characters")
        } catch AlgorandAddress.AddressError.checksumMismatch {
            return ("xmark.circle.fill", .red, "Checksum does not match")
        } catch {
            return ("xmark.circle.fill", .red, "Not a valid address")
        }
    }

    /// What a text that names no account means for the watch, which the row
    /// would not otherwise show: it keeps the account it held, or adds none.
    private var consequence: String? {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? AlgorandAddress(trimmed)) == nil else { return nil }
        return draft.held == nil ? "not watched until valid" : "still watching the previous address"
    }

    /// Both on one line beneath the field, such as "6/58 characters · not
    /// watched until valid". The line is always there and blank when there is
    /// nothing to say, so the form, and the onboarding panel, keep their height
    /// while an address is typed. Short enough to fit either on one line.
    private var note: String {
        [validity?.note, consequence].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // A secure field is the mask here rather than plain bullets in
                // a label, because an address that cannot be edited while
                // values are hidden gives no hint why. The count and the
                // checksum symbol still report on what is typed.
                if isMasked {
                    SecureField("Address", text: $draft.text)
                        .modifier(AddressFieldStyle(id: draft.id, focus: focus, onCommit: onCommit))
                } else {
                    TextField("Address", text: $draft.text)
                        .modifier(AddressFieldStyle(id: draft.id, focus: focus, onCommit: onCommit))
                }
                if let validity {
                    Image(systemName: validity.symbol).foregroundStyle(validity.tint)
                } else {
                    // Its place is kept while there is nothing to report, so
                    // the field keeps one width as the first character is
                    // typed.
                    Image(systemName: "circle").hidden()
                }
            }
            Text(note.isEmpty ? " " : note)
                .font(Typography.secondary).foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(note.isEmpty)
        }
    }
}

/// What the plain and masked fields share, so the two cannot drift into
/// looking or behaving like different controls.
private struct AddressFieldStyle: ViewModifier {
    let id: AddressDraft.ID
    var focus: FocusState<AddressDraft.ID?>.Binding
    let onCommit: () -> Void

    func body(content: Content) -> some View {
        content
            .font(Typography.primary.monospaced())
            .focused(focus, equals: id)
            .onSubmit(onCommit)
    }
}

/// Any combination of metrics, with no cap.
///
/// The selection is deliberately unlimited, so the consequence is shown instead
/// of prevented: a live width estimate, and a warning once the item grows past
/// the point where a crowded menu bar starts hiding things. A hidden item gives
/// no indication of why it vanished, so the number is worth showing.
struct MenuBarMetricPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        // Drawn once per render: the preview shows the image, and the readout,
        // the threshold and the caption all measure it.
        let name = MenuBar.spokenName(health: model.health, text: model.menuBarFigures)
        let item = MenuBarImage.render(
            symbol: model.health.symbol, text: model.menuBarText, description: name)
        let width = MenuBar.width(of: item)
        let isWide = width > MenuBar.comfortableWidth

        VStack(alignment: .leading, spacing: 6) {
            ForEach(MenuBarMetric.allCases) { metric in
                Toggle(
                    metric.title,
                    isOn: Binding(
                        get: { model.metrics.contains(metric) },
                        set: { on in
                            if on {
                                model.metrics.insert(metric)
                            } else {
                                model.metrics.remove(metric)
                            }
                            model.save()
                        })
                )
                .toggleStyle(.checkbox)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 6) {
                Text("Preview")
                    .font(Typography.secondary).foregroundStyle(.secondary)
                // The menu bar's own image, so the preview is the item exactly.
                // Before the first poll it shows the stand-ins the menu bar
                // shows, which are about as wide as the figures to come.
                Image(nsImage: item)
                    .accessibilityLabel(name)
                Spacer()
                Text("≈\(Int(width)) pt")
                    .font(Typography.secondary).monospacedDigit()
                    .foregroundStyle(isWide ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }

            Text(
                isWide
                    ? "That is wide for a menu bar. On a notched display a wide item is not shortened, it is hidden entirely, with nothing to show why."
                    : "The health icon is always shown. Selecting none leaves just the icon."
            )
            .font(Typography.secondary)
            .foregroundStyle(isWide ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
