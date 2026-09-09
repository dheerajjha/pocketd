import SwiftUI
import PocketdKit

struct ServerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let url = model.serverURL {
                    connectSection(url: url)
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
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(model.serverState.isRunning ? .green : .secondary)
                    .frame(width: 10, height: 10)
                Text(statusText).font(.headline)
                Spacer()
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
                .disabled(model.loadedModelID == nil && !model.serverState.isRunning)
            }

            if model.loadedModelID == nil {
                Label("Load a model before starting.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("iOS closes the connection when this app is in the background. Keep Pocketd on screen while other devices are using it.")
        }
    }

    private func connectSection(url: URL) -> some View {
        Section("Connect") {
            LabeledContent("Base URL") {
                Text(url.absoluteString).font(.system(.body, design: .monospaced))
            }
            if model.configuration.requiresAuth {
                LabeledContent("API key") {
                    Text(model.configuration.apiKey)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ShareLink(item: curlSnippet(url: url)) {
                Label("Share curl command", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = curlSnippet(url: url)
            } label: {
                Label("Copy curl command", systemImage: "doc.on.doc")
            }
        }
    }

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
                        if let client = entry.clientAddress {
                            Text(client)
                        }
                        if let rate = entry.tokensPerSecond {
                            Text(String(format: "%.1f tok/s", rate))
                        }
                        if let tokens = entry.completionTokens {
                            Text("\(tokens) tok")
                        }
                        if entry.streamed {
                            Text("stream")
                        }
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

    private func curlSnippet(url: URL) -> String {
        let auth = model.configuration.requiresAuth
            ? "  -H \"Authorization: Bearer \(model.configuration.apiKey)\" \\\n"
            : ""
        return """
        curl \(url.absoluteString)/v1/chat/completions \\
          -H "Content-Type: application/json" \\
        \(auth)  -d '{"model":"\(model.loadedModelID ?? "")","messages":[{"role":"user","content":"hello"}]}'
        """
    }
}
