import PocketdKit
import SwiftUI
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
    @Environment(ToastCenter.self) private var toasts

    @State private var text = ""
    @State private var copied = false

    var body: some View {
        YouDetailScreen(
            title: "Diagnostics",
            subtitle: "What the app has been doing, in order. Copy it out if something is going wrong and you want to show somebody."
        ) {
            YouSection(
                "WHAT IS IN IT",
                footnote: "Brain loads, which tools the assistant was given and why, permission answers, tool calls and their outcomes, and failures. Never your calendar, your reminders, your health data, what you typed or what the assistant replied — there is no field in this log that can hold any of them."
            ) {
                HStack(spacing: PDSpacing.xs) {
                    PillButton(
                        title: copied ? "Copied" : "Copy the log",
                        symbol: copied ? "checkmark" : "doc.on.doc"
                    ) {
                        copy()
                    }
                    .disabled(text.isEmpty)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, PDSpacing.xs)

                RowDivider(inset: 0)

                NavRow(symbol: "trash", title: "Clear the log", detail: "Starts it again from empty") {
                    DiagnosticLog.clear()
                    refresh()
                    toasts.show("Log cleared")
                }
            }

            YouSection(
                "LOG",
                footnote: "Capped at \(DiagnosticLog.capacity) entries and \(DiagnosticLog.exportByteLimit / 1024)KB. When it is full the oldest go first, so whatever just happened is always still here."
            ) {
                if text.isEmpty {
                    Text("Nothing has been recorded yet.")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .padding(.vertical, PDSpacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Monospaced because the log is columns — a clock, an
                    // event, then numbers — and a proportional font turns
                    // scanning it into reading it.
                    MonoBlock(text: text, size: 11)
                        .padding(.vertical, PDSpacing.xs)
                }
            }
        }
        // Rebuilt on appearance rather than observed. The log is written from
        // actors, tool bodies and background wakes, and making it observable
        // would put a SwiftUI invalidation on paths whose whole job is to not
        // cost anything. A screen someone opened to copy a log does not need to
        // update while they look at it.
        .onAppear(perform: refresh)
    }

    private func copy() {
        UIPasteboard.general.string = text
        Haptics.success()
        copied = true
        toasts.show("Log copied")
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
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

// MARK: - Previews

#Preview("Diagnostics light") {
    NavigationStack { DiagnosticsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Diagnostics dark") {
    NavigationStack { DiagnosticsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
