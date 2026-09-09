import SwiftUI
import PocketdKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ServerConfiguration()
    @State private var portText = ""

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Picker("Reachable from", selection: $draft.binding) {
                        ForEach(ServerConfiguration.Binding.allCases) { binding in
                            Text(binding.title).tag(binding)
                        }
                    }
                    LabeledContent("Port") {
                        TextField("11434", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Port 11434 is Ollama's default, so existing Ollama clients only need their host changed.")
                }

                Section {
                    Toggle("Require an API key", isOn: $draft.requiresAuth)
                    if draft.requiresAuth {
                        LabeledContent("Key") {
                            Text(draft.apiKey)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button("Generate a new key") {
                            draft.apiKey = ServerConfiguration.generateAPIKey()
                        }
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

                Section("Device") {
                    Toggle("Keep screen awake while serving", isOn: $draft.keepAwakeWhileServing)
                }

                Section("Assistant") {
                    TextField("System prompt", text: $model.systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button("Apply") {
                        draft.port = UInt16(portText) ?? draft.port
                        Task { await model.applyConfiguration(draft) }
                    }
                    .disabled(draft == model.configuration && portText == String(model.configuration.port))
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                draft = model.configuration
                portText = String(model.configuration.port)
            }
        }
    }
}
