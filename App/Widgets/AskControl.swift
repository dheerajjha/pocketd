import AppIntents
import SwiftUI
import WidgetKit

/// The "Ask Pocketd" control, offered to the Control Center gallery and
/// assignable to the Lock Screen's bottom buttons and the Action Button.
///
/// A button, not a toggle: there is no ongoing state to read back — nothing
/// here is on or off — so there is no need for the value provider a
/// `ControlWidgetToggle` would ask for. A tap just runs `OpenAskIntent`. See
/// that file for what it leaves behind and why.
struct AskPocketdControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.pocketd.control.ask") {
            ControlWidgetButton(action: OpenAskIntent()) {
                Label("Ask Pocketd", systemImage: "sparkles")
            }
        }
        .displayName("Ask Pocketd")
        .description("Ask your on-device assistant from anywhere.")
    }
}
