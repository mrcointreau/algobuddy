import AlgobuddyCore
import SwiftUI

@main
struct AlgobuddyApp: App {
    @State private var model: AppModel

    /// Loading here rather than from a `.task` on the menu bar label matters:
    /// SwiftUI renders that label into the status item and does not reliably
    /// run view tasks attached to it until the panel is first opened. Polling
    /// has to start when the app launches, not when the user gets curious.
    init() {
        let model = AppModel()
        model.load()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // HIG: "When people choose the Settings item … your custom settings
        // window opens." The Settings scene supplies the standard ⌘, binding,
        // and the panes' TabView titles the window after the visible pane.
        Settings {
            SettingsView(model: model)
        }
        // HIG: "a settings window accommodates the size of the current pane, [so]
        // people don't need to expand the window to see more." Sizing to
        // content gives the window each pane's size, and keeps a scrollbar out
        // of a pane unless the screen is too short for it.
        .windowResizability(.contentSize)
    }
}

/// The compact menu bar surface.
///
/// Budget is `MenuBar.comfortableWidth`. On a notched MacBook a wide item is
/// simply hidden, so this stays deliberately terse and, above all, fixed-width.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.health.symbol)
                .foregroundStyle(model.health.tint)
            if let text = model.menuBarText {
                Text(text)
                    // Asks for digits of one width, so the label keeps its
                    // width as figures change. The menu bar has been seen to
                    // draw the label as plain text in its own font regardless,
                    // where a 1 is narrower than an 8, which is why the
                    // stand-ins in AppModel allow for a few points.
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("algobuddy: \(model.health.label)")
    }
}
