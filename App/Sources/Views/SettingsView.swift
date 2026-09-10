import SwiftUI
import PocketdKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ServerConfiguration()
    @State private var portText = ""
    @FocusState private var isPortFocused: Bool
    @State private var showKeyWarning = false

    /// nil when the field is a usable port.
    private var portProblem: String? {
        guard !portText.isEmpty else { return "Enter a port." }
        guard let value = Int(portText) else { return "Ports are numbers." }
        guard (1...65535).contains(value) else { return "Port must be between 1 and 65535." }
        return nil
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    // .menu keeps the selected value on its own line instead
                    // of squeezing it beside the label, where it truncated to
                    // "Local…twork" and the user could not read their own setting.
                    Picker("Reachable from", selection: $draft.binding) {
                        ForEach(ServerConfiguration.Binding.allCases) { binding in
                            Text(binding.title).tag(binding)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("Port") {
                        TextField("11434", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isPortFocused)
                    }
                    if let problem = portProblem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Port 11434 is Ollama's default, so existing Ollama clients only need their host changed. Changing it disconnects anything already paired.")
                }

                Section {
                    Toggle("Require an API key", isOn: $draft.requiresAuth)
                    if draft.requiresAuth {
                        // Labelled so nobody copies a key that returns 401.
                        // Settings edits a draft while the Server tab shows the
                        // live value, so the two tabs could show different keys
                        // at once with nothing saying which one worked.
                        LabeledContent(draft.apiKey == model.configuration.apiKey ? "Key" : "Key (not applied yet)") {
                            Text(draft.apiKey)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .foregroundStyle(draft.apiKey == model.configuration.apiKey ? Color.primary : Color.orange)
                        }
                        Button("Copy key") { UIPasteboard.general.string = model.configuration.apiKey }
                        Button("Generate a new key") { showKeyWarning = true }
                    }
                    Toggle("Allow browser requests (CORS)", isOn: $draft.allowCORS)
                } header: {
                    Text("Access")
                } footer: {
                    Text("Turning the key off leaves the model open to everyone on the network. Do not do this on a network you do not control.")
                }

                Section {
                    Stepper("Context limit: \(draft.maxContextTokens) tokens",
                            value: $draft.maxContextTokens, in: 512...32_768, step: 512)
                    Stepper("Concurrent requests: \(draft.maxConcurrentRequests)",
                            value: $draft.maxConcurrentRequests, in: 1...4)
                } header: {
                    Text("Generation")
                } footer: {
                    Text("The KV cache grows with the context limit and competes with the weights for the same memory. More than one concurrent request makes every request slower on a single GPU.")
                }

                Section {
                    Toggle("Keep screen awake while serving", isOn: $draft.keepAwakeWhileServing)
                    // ServeCondition.battery tells the user to "lower the floor
                    // in Settings". Until now there was no such control
                    // anywhere, so the one remedy the app offered below 15%
                    // battery was unreachable.
                    Stepper(
                        draft.pauseBelowBatteryLevel <= 0
                            ? "Stop serving below: never"
                            : "Stop serving below: \(Int(draft.pauseBelowBatteryLevel * 100))% battery",
                        value: $draft.pauseBelowBatteryLevel,
                        in: 0...0.5,
                        step: 0.05
                    )
                } header: {
                    Text("Device")
                } footer: {
                    Text("Generating drains the battery fast. Below this level the server keeps listening but answers 503 with a reason, so a client can wait rather than assume the phone has gone. Charging exempts it.")
                }

                Section {
                    slider("Temperature", value: $draft.sampling.temperature, in: 0...2, step: 0.05)
                    slider("Top-p", value: $draft.sampling.topP, in: 0...1, step: 0.01)
                    Stepper("Top-k: \(draft.sampling.topK)", value: $draft.sampling.topK, in: 0...200)
                    slider("Repeat penalty", value: $draft.sampling.repeatPenalty, in: 1...2, step: 0.01)
                    Toggle("Fixed seed", isOn: Binding(
                        get: { draft.sampling.seed != nil },
                        set: { draft.sampling.seed = $0 ? 0 : nil }
                    ))
                    if draft.sampling.seed != nil {
                        LabeledContent("Seed") {
                            TextField("0", value: Binding(
                                get: { draft.sampling.seed ?? 0 },
                                set: { draft.sampling.seed = $0 }
                            ), format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                        }
                    }
                    Button("Reset to llama.cpp defaults") {
                        draft.sampling = .default
                    }
                    .disabled(draft.sampling == .default)
                } header: {
                    Text("Sampling")
                } footer: {
                    Text("What a request inherits when it does not say. A client that sends its own temperature or seed still wins — these are the defaults, not a ceiling. Changing them reloads the model on its next use, because llama.cpp binds sampling when the context is created.")
                }

                // Deliberately outside the Apply group below: these change app
                // behaviour, not the server's configuration, and a memory
                // setting that needs a second tap to take effect reads as
                // broken.
                Section {
                    Toggle("Offload when backgrounded", isOn: $model.autoOffloadInBackground)
                    Picker("Offload after idle", selection: $model.idleOffloadSeconds) {
                        Text("Never").tag(0)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                } header: {
                    Text("Memory")
                } footer: {
                    Text("A loaded model holds its weights in memory the whole time. Backgrounding closes the socket anyway, so releasing it there costs nothing and stops iOS killing the app while it is away. Idle offload is this phone's keep_alive: the next request loads the model again, which takes a few seconds.")
                }

                Section("Assistant") {
                    TextField("System prompt", text: $model.systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button("Apply") {
                        // Guarded by portProblem, so the silent fallback that
                        // used to make Apply a permanent no-op cannot happen:
                        // an out-of-range port left the button enabled forever
                        // with nothing changing and no message.
                        guard let port = UInt16(portText) else { return }
                        draft.port = port
                        Task { await model.applyConfiguration(draft) }
                    }
                    .disabled(portProblem != nil || (draft == model.configuration && portText == String(model.configuration.port)))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // The number pad has no Return key at all, so without this the
                // keyboard covers the tab bar with no way to dismiss it and the
                // user cannot leave Settings.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isPortFocused = false }
                }
            }
            .navigationTitle("Settings")
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
    }

    /// Label and current value on one line, track beneath.
    ///
    /// `LabeledContent` puts the slider and its readout in the trailing slot,
    /// which at this width wraps them under one another and leaves the label
    /// floating beside a two-line stack. The number belongs next to the name
    /// it qualifies.
    @ViewBuilder
    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 2)
    }
}
