import SwiftUI
import PocketdKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ServerConfiguration()
    @State private var portText = ""
    @FocusState private var isPortFocused: Bool
    @State private var showKeyWarning = false
    @State private var showingDataInspector = false
    @State private var copiedKey = false
    @State private var copyTick = 0
    @Environment(\.openURL) private var openURL

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
                        // A row that changes nothing on screen is a row the
                        // user taps twice and then checks the clipboard to see
                        // whether anything happened. `ServerView` has said so
                        // since V1; this one was writing to the pasteboard in
                        // total silence.
                        Button {
                            UIPasteboard.general.string = model.configuration.apiKey
                            copiedKey = true
                            copyTick += 1
                            Task {
                                try? await Task.sleep(for: .seconds(1.4))
                                copiedKey = false
                            }
                        } label: {
                            Label(
                                copiedKey ? "Copied" : "Copy key",
                                systemImage: copiedKey ? "checkmark" : "doc.on.doc"
                            )
                            .foregroundStyle(copiedKey ? Color.green : Color.accentColor)
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityLabel(copiedKey ? "Key copied" : "Copy key")
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
                    Toggle("Let the model think first", isOn: $draft.reasoningEnabled)
                } header: {
                    Text("Generation")
                } footer: {
                    Text("The KV cache grows with the context limit and competes with the weights for the same memory. More than one concurrent request makes every request slower on a single GPU.\n\nReasoning models write out their working before answering. It helps on hard questions and costs tens of seconds on a phone for easy ones. Turning it off asks the model to skip it; models that do not reason are unaffected either way.")
                }

                Section {
                    Toggle("Keep screen awake while serving", isOn: $draft.keepAwakeWhileServing)
                    // ServeCondition.battery tells the user to "lower the floor
                    // in Settings". Until now there was no such control
                    // anywhere, so the one remedy the app offered below 15%
                    // battery was unreachable.
                    Picker("Stop serving when hot", selection: $draft.thermalTolerance) {
                        ForEach(ThermalTolerance.allCases) { tolerance in
                            Text(tolerance.title).tag(tolerance)
                        }
                    }
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
                    Text("Generating drains the battery fast. Below this level the server keeps listening but answers 503 with a reason, so a client can wait rather than assume the phone has gone. Charging exempts it.\n\nRaising the heat limit does not make the phone faster — iOS throttles the processor itself once it is hot, so the server keeps answering, slowly. At the very hottest level iOS may close the app, and no setting here can stop that.")
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

                Section {
                    Button("See and delete everything Pocketd stores") {
                        showingDataInspector = true
                    }
                } footer: {
                    Text("Every model, conversation, setting and permission on this phone, with a real byte count and a real delete — and an accurate list of the only place anything ever goes.")
                }

                Section {
                    Button("Show the introduction again") {
                        model.replayOnboarding()
                    }
                } footer: {
                    Text("Replays the introduction a new install sees. Nothing is reset — your models, conversations and settings stay exactly as they are.")
                }

                Section("Assistant") {
                    TextField("System prompt", text: $model.systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                }

                // Alongside Memory rather than in the Apply group: this changes
                // what the app does, not what the server is configured with,
                // and it puts a permission prompt on screen — a switch that
                // asks iOS for your calendar and then waits for a second tap
                // before meaning anything reads as broken.
                Section {
                    // Two switches, not one. They shared a single boolean
                    // until the capability hub needed one status and one
                    // action per capability — and a user who wants the
                    // assistant to see their calendar but not their task list
                    // could not have it.
                    Toggle("Read calendar", isOn: $model.calendarToolsEnabled)
                    Toggle("Read reminders", isOn: $model.reminderToolsEnabled)
                    Toggle("Read health data", isOn: $model.healthToolsEnabled)
                    if model.healthToolsEnabled, let note = model.healthCapabilityNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if model.calendarToolsEnabled || model.reminderToolsEnabled {
                        // Above the permission warnings, because it outranks
                        // them: a model that will never call the tools makes
                        // the calendar permission beside the point. Shown even
                        // when the answer is yes, because "on" and "working"
                        // were the same word here until they were not, and the
                        // only way to make the switch mean what it looks like
                        // it means is to say which model is honouring it.
                        //
                        // One notice rather than a gate sentence and a budget
                        // sentence, because those two can disagree about the
                        // same registration and used to print both. See
                        // `CapabilityNotice`.
                        if let notice = model.capabilityNotice {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.summary)
                                    .font(.footnote)
                                    .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
                                // Under the summary, which says what was
                                // refused; each of these says what it would
                                // cost and which window would carry it, and
                                // that is the half a user can act on.
                                ForEach(notice.shortfalls, id: \.self) { line in
                                    Text(line)
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        ForEach(PersonalDataEntity.allCases, id: \.self) { entity in
                            if let status = model.personalDataAuthorization[entity], !status.canRead {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entity.noun.capitalized)
                                    // The sentence the tool itself would hand
                                    // the model, shown to the user instead. One
                                    // wording for one problem, and it already
                                    // names the exact screen.
                                    Text(status.explanation(for: entity))
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        if model.personalDataAuthorization.values.contains(where: { !$0.canRead }) {
                            // Opens the front door and no further: the calendar
                            // and reminder switches live under Privacy &
                            // Security, per entity, and no app can deep-link a
                            // user to them. The line above says which corridor.
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Personal data")
                } footer: {
                    // "Both tools" was true when calendar and reminders shared
                    // one switch. It is false the moment someone turns on one
                    // of them, and this is the sentence that justifies the
                    // cost of the switch — so it has to count what is actually
                    // registered rather than assume two.
                    Text("Off, the assistant answers from the conversation alone. On, it can say what is on today or what is overdue — and every other reply has less room, because each tool you enable is described to the model before it reads a word you typed, whether or not the answer needs it. On a small model with a 4K window that is a few hundred words of conversation gone per tool. Requests from other devices never reach this data either way.")
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

                // Deliberately the last thing on the screen, below every
                // control someone came here to change. On by default, and
                // findable by anyone who goes looking — which is the whole
                // bargain: most people will never scroll this far, and the
                // ones who care will.
                Section {
                    Toggle("Share usage events", isOn: Binding(
                        get: { model.analyticsConsent.permitsSending },
                        set: { model.setAnalyticsConsent($0 ? .granted : .refused) }
                    ))
                } header: {
                    Text("Usage")
                } footer: {
                    Text("Sent: which screens are opened, which models are downloaded and whether they load, how fast generation runs, and whether another device connected. Never sent: anything you type, anything the model says, anything read from Health, Calendar or Reminders, your files, your network addresses or your location. Turning this off stops it and discards anything queued but not yet sent.")
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
            .sensoryFeedback(.success, trigger: copyTick)
            .sheet(isPresented: $showingDataInspector) { DataInspectorView() }
            .onAppear {
                draft = model.configuration
                portText = String(model.configuration.port)
                // The only way a grant becomes a refusal is a trip to iOS
                // Settings, and nothing about coming back tells this process.
                model.refreshPersonalDataAuthorization()
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
