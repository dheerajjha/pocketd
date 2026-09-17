import PocketdKit
import SwiftUI

/// The technical detail behind the brain, for anyone who came looking for it.
///
/// One of exactly two screens in this app where the vocabulary is allowed to be
/// the real one — quantisation, context window, tokens per second. Everywhere
/// else those words are a wall, and the rule that keeps them out of the other
/// screens only works if there is somewhere honest for them to go.
///
/// Read-only, deliberately. Everything here that can be changed is changed in
/// one place, and the row at the bottom goes there rather than offering a
/// second set of controls that could disagree with the first.
struct BrainAdvancedView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    var body: some View {
        YouDetailScreen(
            title: "Advanced",
            subtitle: "What is actually loaded, what it costs, and how fast it runs on this phone."
        ) {
            loaded
            speed
            memory
            sampling
        }
    }

    // MARK: - What is loaded

    @ViewBuilder
    private var loaded: some View {
        let record = model.loadedModelID.flatMap { id in model.catalog.first { $0.id == id } }

        YouSection(
            "LOADED",
            footnote: record == nil
                ? "Nothing is resident. These figures fill in once a brain is in memory."
                : "The identifier is what a paired client sends as its `model` field."
        ) {
            if let record {
                ValueRow(title: "Identifier", value: record.id)
                RowDivider(inset: 0)
                ValueRow(title: "Parameters", value: record.parameters)
                RowDivider(inset: 0)
                ValueRow(title: "Quantisation", value: record.quantization)
                RowDivider(inset: 0)
                ValueRow(title: "Weights on disk", value: pdBytes(record.sizeBytes))
                if record.projectorSizeBytes > 0 {
                    RowDivider(inset: 0)
                    ValueRow(title: "Image projector", value: pdBytes(record.projectorSizeBytes))
                }
                RowDivider(inset: 0)
                ValueRow(title: "Estimated resident", value: pdBytes(record.estimatedResidentBytes))
                RowDivider(inset: 0)
                ValueRow(title: "Context window", value: "\(model.configuration.maxContextTokens) tokens")
                RowDivider(inset: 0)
                ValueRow(
                    title: "Tool calling",
                    value: record.toolSupport.isYes ? "Yes" : "No"
                )
            } else {
                Text("No brain is in memory right now.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .padding(.vertical, PDSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Speed

    /// Tokens per second, from the request log rather than from a benchmark.
    ///
    /// The log is the only place this number is ever measured on real work, so
    /// it is the only place worth reading it from. It is empty until something
    /// has actually been generated, and the copy says so rather than printing a
    /// zero that reads like a failure.
    @ViewBuilder
    private var speed: some View {
        let rates = model.log.compactMap(\.tokensPerSecond)

        YouSection(
            "SPEED",
            footnote: "Measured on requests this phone has actually answered this session, not on a benchmark. It drops as the phone warms up and as the conversation grows."
        ) {
            if rates.isEmpty {
                Text("Nothing has been generated yet this session.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .padding(.vertical, PDSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ValueRow(title: "Most recent", value: String(format: "%.1f tok/s", rates[0]))
                RowDivider(inset: 0)
                ValueRow(
                    title: "Best this session",
                    value: String(format: "%.1f tok/s", rates.max() ?? 0)
                )
                RowDivider(inset: 0)
                ValueRow(title: "Requests measured", value: "\(rates.count)")
            }
        }
    }

    // MARK: - Memory

    private var memory: some View {
        YouSection(
            "MEMORY",
            footnote: model.budget.hasIncreasedMemoryLimit
                ? "This build carries the increased memory limit entitlement, so iOS allows it more than the default share of this phone's RAM."
                : "Without the increased memory limit entitlement iOS caps this app well below the phone's total RAM."
        ) {
            ValueRow(title: "Usable by this app", value: pdBytes(model.budget.usableBytes))
            RowDivider(inset: 0)
            ValueRow(title: "Physical RAM", value: pdBytes(model.budget.physicalMemoryBytes))
            RowDivider(inset: 0)
            ValueRow(
                title: "Ceiling",
                value: model.budget.isCalibrated ? "Measured on this device" : "Estimated"
            )
        }
    }

    // MARK: - Sampling

    private var sampling: some View {
        let parameters = model.configuration.sampling

        return YouSection(
            "SAMPLING DEFAULTS",
            footnote: "What a request inherits when it does not say. A paired client that sends its own temperature or seed still wins — these are the defaults, not a ceiling."
        ) {
            ValueRow(title: "Temperature", value: String(format: "%.2f", parameters.temperature))
            RowDivider(inset: 0)
            ValueRow(title: "Top-p", value: String(format: "%.2f", parameters.topP))
            RowDivider(inset: 0)
            ValueRow(title: "Top-k", value: "\(parameters.topK)")
            RowDivider(inset: 0)
            ValueRow(title: "Repeat penalty", value: String(format: "%.2f", parameters.repeatPenalty))
            RowDivider(inset: 0)
            ValueRow(
                title: "Seed",
                value: parameters.seed.map(String.init) ?? "Random"
            )
            RowDivider(inset: 0)
            ValueRow(
                title: "Thinks first",
                value: model.configuration.reasoningEnabled ? "Yes" : "No"
            )
            RowDivider(inset: 0)
            NavRow(
                symbol: "slider.horizontal.3",
                title: "Change these",
                detail: "Sampling, context and the server's own settings"
            ) {
                navigator.push(.settings)
            }
        }
    }
}

// MARK: - Previews

#Preview("Brain advanced light") {
    NavigationStack { BrainAdvancedView() }
        .environment(AppModel())
        .environment(Navigator())
}

#Preview("Brain advanced dark") {
    NavigationStack { BrainAdvancedView() }
        .environment(AppModel())
        .environment(Navigator())
        .preferredColorScheme(.dark)
}
