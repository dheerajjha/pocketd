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
}
