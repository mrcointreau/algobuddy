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
            // the panel has no URL fields, so the reason has to be said here.
            if let error = model.sourceError {
                Text("\(error) Fix it in Settings (⌘,).")
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

/// The Settings window's content.
///
/// A `Form` with `.formStyle(.grouped)`, which is what gives the native System
/// Settings appearance: right-aligned leading labels in a consistent column,
/// grouped sections, correct control sizing. Hand-rolling the layout gives
/// labels of differing widths and fields that do not line up.
///
/// Changes take effect as they are made, as macOS settings do, rather than
/// behind an Apply button. Text fields commit on Return, on focus loss, and
/// when the window closes, which avoids restarting the poller on every
/// keystroke of a URL while leaving no way to lose an edit.
struct SettingsView: View {
    @Bindable var model: AppModel

    private enum URLField {
        case algod, indexer
    }
    @FocusState private var focusedURL: URLField?

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginRow(model: model)
            }

            Section("Account") {
                AddressList(model: model)
            }

            Section("Menu bar") {
                MenuBarMetricPicker(model: model)
            }

            Section("Chain data source") {
                TextField("algod", text: $model.algodURLText)
                    .focused($focusedURL, equals: .algod)
                    .onSubmit { model.apply() }
                TextField("indexer", text: $model.indexerURLText)
                    .focused($focusedURL, equals: .indexer)
                    .onSubmit { model.apply() }

                // The error belongs to these fields, so it renders here rather
                // than under the address input in another section.
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

            Section("Notifications") {
                // Checkbox, not a switch: switches are the iOS idiom, and macOS
                // settings use checkboxes. Routed through the model so turning
                // it on can request system authorisation right now, not at the
                // next address submit.
                Toggle(
                    "Notify on alerts",
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotifications(enabled: $0) })
                )
                .toggleStyle(.checkbox)
            }

            VersionFooter(model: model)
        }
        // Leaving a field commits it, the same contract as AddressField: an
        // edit abandoned by clicking elsewhere must not sit in the bound text
        // diverging from what the poller runs. apply() ignores a commit that
        // changes nothing and never tears down a running watch over an invalid
        // draft, so focus movement is always safe.
        .onChange(of: focusedURL) { old, _ in
            if old != nil { model.apply() }
        }
        // Closing the window commits too. Dismissing the pane does not move
        // focus out of the field being typed in, so without this an address
        // entered and then dismissed would sit in the edit buffer, watched by
        // nothing, until the pane was next opened.
        .background(CommitOnClose { model.apply() })
        .formStyle(.grouped)
        // A grouped Form is a scroll view underneath, and a scroll view reports a
        // small ideal height, the same trap as the panel. Taking the content's
        // height instead lets `.windowResizability(.contentSize)` fit the window
        // exactly, so there is nothing left to scroll.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 480)
    }
}

/// Runs a commit when the window holding this view is about to close.
///
/// SwiftUI has no window lifecycle to hook from a Settings scene, so the
/// closing window is reached through an invisible AppKit view planted behind
/// the form. The observation is scoped to that one window, so the panel opening
/// and closing all day never triggers a commit.
private struct CommitOnClose: NSViewRepresentable {
    let commit: () -> Void

    func makeNSView(context: Context) -> CloseCommitView {
        let view = CloseCommitView()
        view.commit = commit
        return view
    }

    func updateNSView(_ view: CloseCommitView, context: Context) {
        view.commit = commit
    }
}

/// The planted view. It has no window until AppKit places it in a hierarchy,
/// which is why the observer is registered from `viewDidMoveToWindow` rather
/// than at construction, and removed there when the view leaves a window so no
/// observation outlives the pane.
private final class CloseCommitView: NSView {
    var commit: () -> Void = {}
    private var observer: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            // Posted on the main thread, where this view and the model live.
            MainActor.assumeIsolated { self?.commit() }
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

            // The same disclosure the chain data source section makes: the one
            // place this pane reaches a host the user did not configure.
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

/// The watched accounts, in the order every other surface presents them.
///
/// Uncapped, like the menu bar metrics, and for the same reason: every address
/// adds its fetches to each cycle, and that trade is the user's to make. The
/// cost is stated rather than prevented.
struct AddressList: View {
    @Bindable var model: AppModel
    /// Focus is owned here rather than by each row, so that a newly added row
    /// can be typed into straight away and so that leaving any row commits it.
    @FocusState private var focused: AddressDraft.ID?

    /// The rows that name an account an earlier row already names. Compared as
    /// addresses rather than as text, so a repeat pasted in another case is
    /// still caught. Silently watching such a row once and showing it twice
    /// here would leave the user with no way to tell why nothing happened.
    private var repeats: Set<AddressDraft.ID> {
        var seen = Set<AlgorandAddress>()
        var found = Set<AddressDraft.ID>()
        for draft in model.addressDrafts {
            guard let address = try? AlgorandAddress(draft.text) else { continue }
            if !seen.insert(address).inserted { found.insert(draft.id) }
        }
        return found
    }

    var body: some View {
        let repeats = self.repeats

        VStack(alignment: .leading, spacing: Spacing.row) {
            ForEach($model.addressDrafts) { $draft in
                HStack(spacing: 6) {
                    AddressField(
                        draft: $draft, focus: $focused, isMasked: model.valuesHidden,
                        isRepeat: repeats.contains(draft.id)
                    ) { model.apply() }

                    Button {
                        model.removeAddressRow(draft.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove this account")
                }
            }

            Button("Add Account", systemImage: "plus") {
                focused = model.addAddressRow()
            }

            // The consequence, said plainly, in place of a limit nobody asked
            // for. Nothing else about the app changes with the count: the same
            // two hosts are contacted whatever it is.
            Text("Every account adds a request to each poll, and a poll runs about every 30 s.")
                .font(Typography.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Leaving a row commits it, the same contract as the URL fields;
        // apply() never tears down a running watch over an invalid or empty
        // draft, so this is always safe.
        .onChange(of: focused) { old, _ in
            if old != nil { model.apply() }
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
            return ("xmark.circle.fill", .red, "Checksum does not match, likely a typo")
        } catch {
            return ("xmark.circle.fill", .red, "Not a valid address")
        }
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
                }
            }
            if let note = validity?.note {
                Text(note).font(Typography.secondary).foregroundStyle(.secondary)
            }
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
        // Measured once per render: estimatedWidth is a font lookup plus a text
        // measurement, and the readout, the threshold and the caption all want
        // the same number.
        let sample = model.menuBarWidthSample
        let width = MenuBar.estimatedWidth(sample)
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
                Image(systemName: model.health.symbol).foregroundStyle(model.health.tint)
                // Before the first poll there are no live values, so the
                // preview falls back to the representative sample.
                if let text = model.menuBarText ?? (model.metrics.isEmpty ? nil : sample) {
                    Text(text).font(Typography.menuRow).monospacedDigit()
                }
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
