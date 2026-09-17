import PocketdKit
import SwiftUI
import UIKit

/// The settings that have nowhere plainer to live.
///
/// Everything a person who has never heard the word "model" needs is on the You
/// screen itself. What is left here is the server's own configuration and what
/// a generation inherits — ports, keys, context windows, samplers — and this is
/// one of the two screens in the app where that vocabulary is allowed out. It
/// is reached from Other devices and from Brain → Advanced, which are the two
/// places somebody arrives already wanting it.
///
/// Changes are staged and applied together, because half of them restart the
/// listener and applying each keystroke would tear the socket down under a
/// paired laptop mid-request. The two that change app behaviour rather than the
/// server's — background and idle unloading — are not here at all; they are on
/// You, where they take effect immediately.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts

    @State private var draft = ServerConfiguration()
    @State private var portText = ""
    @State private var showKeyWarning = false
    @FocusState private var portFocused: Bool

    /// nil when the field is a usable port.
    private var portProblem: String? {
        guard !portText.isEmpty else { return "Enter a port." }
        guard let value = Int(portText) else { return "Ports are numbers." }
        guard (1...65535).contains(value) else { return "Port must be between 1 and 65535." }
        return nil
    }

    private var isUnchanged: Bool {
        draft == model.configuration && portText == String(model.configuration.port)
    }

    var body: some View {
        YouDetailScreen(
            title: "Advanced",
            subtitle: "How the server answers, and what a request inherits when it does not say. Nothing here changes until you apply it."
        ) {
            network
            access
            generation
            device
            sampling
            apply
        }
        .onAppear {
            draft = model.configuration
            portText = String(model.configuration.port)
        }
        .confirmationDialog(
            "Generate a new API key?",
            isPresented: $showKeyWarning,
            titleVisibility: .visible
        ) {
            Button("Generate", role: .destructive) {
                draft.apiKey = ServerConfiguration.generateAPIKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device already paired will stop working and has to pair again. The old key cannot be recovered.")
        }
    }

    // MARK: - Network

    private var network: some View {
        YouSection(
            "NETWORK",
            footnote: "Port 11434 is the one existing clients already expect, so most of them only need their host changed. Changing it disconnects anything already paired."
        ) {
            MenuRow(
                title: "Reachable from",
                selection: $draft.binding,
                options: ServerConfiguration.Binding.allCases.map { ($0, $0.title) }
            )
            RowDivider(inset: 0)
            RowShell(title: "Port", detail: nil) {
                TextField("11434", text: $portText)
                    .font(Font.pd.monoValue)
                    .foregroundStyle(Color.pd.ink)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 84)
                    .focused($portFocused)
                    // The number pad has no Return key, so without somewhere to
                    // tap the keyboard covers the screen with no way out.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { portFocused = false }
                        }
                    }
            }
            if let problem = portProblem {
                Text(problem)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.caution)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, PDSpacing.xs)
            }
        }
    }

    // MARK: - Access

    private var access: some View {
        YouSection(
            "ACCESS",
            footnote: "Turning the key off leaves the brain open to everyone on the network. Do not do that on a network you do not control."
        ) {
            ToggleRow(title: "Require an API key", detail: nil, isOn: $draft.requiresAuth)
            if draft.requiresAuth {
                RowDivider(inset: 0)
                // Labelled so nobody copies a key that returns 401: this screen
                // edits a draft while Other devices shows the live value, so the
                // two could show different keys at once with nothing saying
                // which one works.
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    Text(draft.apiKey == model.configuration.apiKey ? "Key" : "Key (not applied yet)")
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(draft.apiKey == model.configuration.apiKey ? Color.pd.ink : Color.pd.caution)
                    MonoBlock(text: breakableIdentifier(draft.apiKey))
                }
                .padding(.vertical, PDSpacing.s)
                NavRow(symbol: "doc.on.doc", title: "Copy the live key", detail: nil) {
                    UIPasteboard.general.string = model.configuration.apiKey
                    toasts.show("Key copied")
                }
                RowDivider()
                NavRow(symbol: "key", title: "Generate a new key", detail: "Everything paired has to pair again") {
                    showKeyWarning = true
                }
            }
            RowDivider(inset: 0)
            ToggleRow(title: "Allow browser requests (CORS)", detail: nil, isOn: $draft.allowCORS)
        }
    }

    // MARK: - Generation

    private var generation: some View {
        YouSection(
            "GENERATION",
            footnote: "The KV cache grows with the context limit and competes with the weights for the same memory. More than one concurrent request makes every request slower on a single GPU.\n\nModels that reason write out their working before answering. It helps on hard questions and costs tens of seconds on a phone for easy ones; models that do not reason are unaffected either way."
        ) {
            StepperRow(
                title: "Context limit",
                value: $draft.maxContextTokens,
                range: 512...32_768,
                step: 512,
                display: { "\($0) tokens" }
            )
            RowDivider(inset: 0)
            StepperRow(
                title: "Concurrent requests",
                value: $draft.maxConcurrentRequests,
                range: 1...4,
                step: 1,
                display: { "\($0)" }
            )
            RowDivider(inset: 0)
            ToggleRow(title: "Let the model think first", detail: nil, isOn: $draft.reasoningEnabled)
        }
    }

    // MARK: - Device

    private var device: some View {
        YouSection(
            "DEVICE",
            footnote: "Generating drains the battery fast. Below the floor the server keeps listening but answers with a reason, so a client can wait rather than assume the phone has gone. Charging exempts it.\n\nRaising the heat limit does not make the phone faster — iOS throttles the processor itself once it is hot, so the server keeps answering, slowly. At the very hottest level iOS may close the app, and no setting here can stop that."
        ) {
            ToggleRow(title: "Keep the screen awake while serving", detail: nil, isOn: $draft.keepAwakeWhileServing)
            RowDivider(inset: 0)
            MenuRow(
                title: "Stop serving when hot",
                selection: $draft.thermalTolerance,
                options: ThermalTolerance.allCases.map { ($0, $0.title) }
            )
            RowDivider(inset: 0)
            RowShell(
                title: "Stop serving below",
                detail: nil
            ) {
                Stepper(
                    value: $draft.pauseBelowBatteryLevel,
                    in: 0...0.5,
                    step: 0.05
                ) {
                    Text(draft.pauseBelowBatteryLevel <= 0
                         ? "never"
                         : "\(Int(draft.pauseBelowBatteryLevel * 100))%")
                        .font(Font.pd.monoValue)
                        .foregroundStyle(Color.pd.ink)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Stop serving below battery level")
            }
            ValueRow(
                title: "Currently",
                value: draft.pauseBelowBatteryLevel <= 0
                    ? "never"
                    : "\(Int(draft.pauseBelowBatteryLevel * 100))% battery",
                valueTint: .pd.inkSecondary
            )
        }
    }

    // MARK: - Sampling

    private var sampling: some View {
        YouSection(
            "SAMPLING",
            footnote: "What a request inherits when it does not say. A client that sends its own temperature or seed still wins — these are the defaults, not a ceiling. Changing them reloads the brain on its next use, because sampling is bound when the context is created."
        ) {
            SliderRow(title: "Temperature", value: $draft.sampling.temperature, range: 0...2, step: 0.05)
            RowDivider(inset: 0)
            SliderRow(title: "Top-p", value: $draft.sampling.topP, range: 0...1, step: 0.01)
            RowDivider(inset: 0)
            StepperRow(title: "Top-k", value: $draft.sampling.topK, range: 0...200, step: 1, display: { "\($0)" })
            RowDivider(inset: 0)
            SliderRow(title: "Repeat penalty", value: $draft.sampling.repeatPenalty, range: 1...2, step: 0.01)
            RowDivider(inset: 0)
            ToggleRow(
                title: "Fixed seed",
                detail: nil,
                isOn: Binding(
                    get: { draft.sampling.seed != nil },
                    set: { draft.sampling.seed = $0 ? 0 : nil }
                )
            )
            if draft.sampling.seed != nil {
                RowShell(title: "Seed", detail: nil) {
                    TextField("0", value: Binding(
                        get: { draft.sampling.seed ?? 0 },
                        set: { draft.sampling.seed = $0 }
                    ), format: .number)
                        .font(Font.pd.monoValue)
                        .foregroundStyle(Color.pd.ink)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }
            }
            RowDivider(inset: 0)
            NavRow(symbol: "arrow.uturn.backward", title: "Put the defaults back", detail: nil) {
                draft.sampling = .default
            }
            .disabled(draft.sampling == .default)
        }
    }

    // MARK: - Apply

    private var apply: some View {
        VStack(spacing: PDSpacing.s) {
            PrimaryButton(
                title: "Apply",
                arrow: false,
                isEnabled: portProblem == nil && !isUnchanged
            ) {
                // Guarded by `portProblem`, so the silent fallback that used to
                // make Apply a permanent no-op cannot happen: an out-of-range
                // port left the button enabled forever with nothing changing
                // and no message.
                guard let port = UInt16(portText) else { return }
                draft.port = port
                Task {
                    await model.applyConfiguration(draft)
                    toasts.show("Applied")
                }
            }
            if isUnchanged {
                Text("Nothing to apply.")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkTertiary)
            }
        }
        .padding(.top, PDSpacing.xs)
    }
}

// MARK: - Controls

/// Label, value, and a track underneath.
///
/// The number belongs next to the name it qualifies. Putting the slider and its
/// readout in a trailing slot wraps them under one another at this width and
/// leaves the label floating beside a two-line stack.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            HStack {
                Text(title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: PDSpacing.xs)
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(Font.pd.monoValue)
                    .foregroundStyle(Color.pd.inkSecondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.pd.accent)
                .accessibilityLabel(title)
        }
        .padding(.vertical, PDSpacing.s)
    }
}

/// A whole number with two buttons, in the row shape the rest of the card uses.
private struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let display: (Int) -> String

    var body: some View {
        RowShell(title: title, detail: nil) {
            HStack(spacing: PDSpacing.xs) {
                Text(display(value))
                    .font(Font.pd.monoValue)
                    .foregroundStyle(Color.pd.ink)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(display(value))
    }
}

// MARK: - Previews

#Preview("Settings light") {
    NavigationStack { SettingsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Settings dark") {
    NavigationStack { SettingsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
