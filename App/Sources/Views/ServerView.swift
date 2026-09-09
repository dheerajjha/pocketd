import SwiftUI
import PocketdKit

struct ServerView: View {
    @Environment(AppModel.self) private var model
    var goTo: (AppTab) -> Void = { _ in }
    @State private var copied: String?
    @State private var copyTick = 0
    @State private var snippetIndex = 0
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if model.serverState.isRunning {
                    // Gated on an open code, not on whether pairing has ever
                    // happened: asking for a second code has to show it, and a
                    // card that only ever appears once cannot do that.
                    if model.pairing.isOpen || !model.pairing.hasPaired {
                        pairingSection
                    }
                    if model.pairing.hasPaired {
                        connectSection
                    }
                }
                if let error = model.lastServerError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                logSection
            }
            .navigationTitle("Server")
            .toolbar {
                if !model.log.isEmpty {
                    Button("Clear") { Task { await model.clearLog() } }
                }
            }
            .sensoryFeedback(.success, trigger: copyTick)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            if case let .running(host, port) = model.serverState {
                // The address is the whole product, so it is the hero and it is
                // one large tap target. Tapping copies it; on a Mac signed into
                // the same Apple ID, Universal Clipboard means the next stop is
                // Cmd-V in an editor.
                Button {
                    copy(model.serverURL?.absoluteString ?? host, as: "address")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copied == "address" ? "COPIED" : "SERVING")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(copied == "address" ? Color.green : .secondary)
                        Text(host)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(":\(String(port))")
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textSelection(.enabled)
                .accessibilityLabel("Server address \(host) port \(port). Double tap to copy.")
            } else {
                HStack {
                    Circle()
                        .fill(model.serverState.isRunning ? .green : .secondary)
                        .frame(width: 10, height: 10)
                    Text(statusText).font(.headline)
                }
            }

            HStack {
                Text(model.serverState.isRunning
                     ? "Anyone on this network can reach it."
                     : "Start it to serve this model to other devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.serverState.isRunning {
                    Button {
                        model.deskMode = true
                    } label: {
                        Label("Desk", systemImage: "moon.stars")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Desk mode — dim the screen while serving")
                }
                Button(model.serverState.isRunning ? "Stop" : "Start") {
                    Task {
                        if model.serverState.isRunning {
                            await model.stopServer()
                        } else {
                            await model.startServer()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startStopDisabled)
            }

            if model.loadedModelID == nil {
                if model.serverState.isRunning {
                    // Previously this read "SERVING" and "Load a model before
                    // starting." at the same time, while every request 404'd.
                    Label("Running, but no model is loaded — every request will fail.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    // A disabled button beside grey text is not guidance.
                    Button {
                        goTo(.models)
                    } label: {
                        Label("Load a model to start", systemImage: "shippingbox")
                            .font(.footnote)
                    }
                }
            }

            if !model.condition.isServing {
                Label(model.condition.message, systemImage: model.condition == .thermal ? "thermometer.high" : "battery.25")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("iOS closes the connection when this app is in the background. Keep Pocketd on screen while other devices are using it.")
        }
    }

    private var startStopDisabled: Bool {
        if case .starting = model.serverState { return true }
        return model.loadedModelID == nil && !model.serverState.isRunning
    }

    // MARK: - Pairing

    private var pairingSection: some View {
        Section("Connect a laptop") {
            if let setup = model.setupURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open this on your laptop")
                        .font(.subheadline.weight(.medium))
                    Text(setup.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let code = model.pairing.code {
                VStack(alignment: .leading, spacing: 4) {
                    Text(code)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .kerning(6)
                        .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                    if let expires = model.pairing.expires {
                        // SwiftUI's .relative style renders a past date as a
                        // bare magnitude with no "ago", so an expired code read
                        // as "Expires 57 sec" — indistinguishable from time
                        // remaining, while the server was already refusing it.
                        if expires > .now {
                            Text("Expires \(expires, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Expired — tap New code")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Button("New code") { Task { await model.newPairingCode() } }
            } else {
                // Same label as the one the expiry warning tells you to tap.
                Button("New code") { Task { await model.newPairingCode() } }
            }

            if model.pairing.failureCount >= PairingSession.maxAttempts,
               let address = model.pairing.lastFailureAddress {
                Label(
                    "\(model.pairing.failureCount) wrong codes from \(address). That code is dead — tap New code.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Connected

    private var connectSection: some View {
        Section("Connected") {
            let snippets = ClientSnippets.all(
                baseURL: model.serverURL ?? URL(string: "http://127.0.0.1")!,
                apiKey: model.configuration.requiresAuth ? model.configuration.apiKey : nil,
                model: model.loadedModelID ?? "your-model"
            )

            if model.configuration.requiresAuth {
                HStack {
                    Text("API key").foregroundStyle(.secondary)
                    Spacer()
                    Text(showKey ? model.configuration.apiKey : "••••••••••••")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        .font(.caption)
                }
                Button {
                    copy(model.configuration.apiKey, as: "key")
                } label: {
                    Label(copied == "key" ? "Copied" : "Copy API key", systemImage: "key")
                }
            }

            Picker("Client", selection: $snippetIndex) {
                ForEach(Array(snippets.enumerated()), id: \.offset) { index, snippet in
                    Text(snippet.title).tag(index)
                }
            }
            .pickerStyle(.menu)

            if let snippet = snippets[safe: snippetIndex] {
                Text(snippet.body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = snippet.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    copy(snippet.body, as: "snippet")
                } label: {
                    Label(copied == "snippet" ? "Copied" : "Copy for \(snippet.title)", systemImage: "doc.on.doc")
                }
                ShareLink(item: snippet.body) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Button("Show a new pairing code") { Task { await model.newPairingCode() } }
                .font(.footnote)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Requests") {
            if model.log.isEmpty {
                Text("No requests yet.").foregroundStyle(.secondary)
            }
            ForEach(model.log) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(entry.method) \(entry.path)")
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text("\(entry.statusCode)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(entry.statusCode == 200 ? .green : .orange)
                    }
                    HStack(spacing: 8) {
                        if let client = entry.clientAddress { Text(client) }
                        if let rate = entry.tokensPerSecond { Text(String(format: "%.1f tok/s", rate)) }
                        if let tokens = entry.completionTokens { Text("\(tokens) tok") }
                        if entry.streamed { Text("stream") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch model.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case let .running(host, port): "Listening on \(host):\(port)"
        case .failed: "Failed"
        }
    }

    private func copy(_ value: String, as kind: String) {
        UIPasteboard.general.string = value
        copied = kind
        copyTick += 1
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copied == kind { copied = nil }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
