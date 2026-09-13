import SwiftUI
import PocketdKit
import UIKit

/// The copyable log, and a plain statement of what is in it.
///
/// The sentence at the top is doing real work rather than reassuring: this
/// screen exists to be copied into a conversation with somebody else, and a
/// person deciding whether to paste it is entitled to know what they are
/// pasting without reading two hundred lines first. The claim it makes is
/// enforced by `DiagnosticEvent` being a closed enum with nowhere to put a
/// title, a prompt or an answer — not by this view filtering anything.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text(text)
                    // Monospaced because the log is columns — a clock, an
                    // event, then numbers — and a proportional font turns
                    // scanning it into reading it.
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Log")
            } footer: {
                Text("Model loads, which tools the assistant was given and why, permission answers, tool calls and their outcomes, and failures. Never your calendar, your reminders, your health data, what you typed or what the model replied — there is no field in this log that can hold any of them.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? "Copied" : "Copy the log",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                }
                .disabled(text.isEmpty)

                Button("Clear the log", role: .destructive) {
                    DiagnosticLog.clear()
                    refresh()
                }
            } footer: {
                Text("Capped at \(DiagnosticLog.capacity) entries and \(DiagnosticLog.exportByteLimit / 1024)KB. When it is full the oldest entries go first, so whatever just happened is always still here.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        // Rebuilt on appearance rather than observed. The log is written from
        // actors, tool bodies and background wakes, and making it observable
        // would put a SwiftUI invalidation on paths whose whole job is to not
        // cost anything. A screen someone opened to copy a log does not need
        // to update while they look at it.
        .onAppear(perform: refresh)
    }

    private func refresh() {
        text = DiagnosticLog.export(
            environment: DiagnosticEnvironment.current(
                modelID: model.loadedModelID,
                contextTokens: model.configuration.maxContextTokens
            )
        )
    }
}
