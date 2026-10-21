import PocketdKit
import SwiftUI

/// More brains › Technical details: the real vocabulary, for anyone who came
/// looking for it.
///
/// One of the two places in Pocketd where the words are allowed to be the
/// engineering ones — quantisation, context window, tokens a second. The rule
/// that keeps them off every other screen only works if there is somewhere
/// honest for them to go, and this is two levels below the choice anyone
/// actually makes.
///
/// Read-only. What can be changed is changed in Server settings, and the row
/// at the bottom goes there rather than offering a second set of controls that
/// could disagree with the first.
struct BrainAdvancedView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    var body: some View {
        YouDetailScreen(
            title: "Technical details",
            subtitle: "What runs Pocketd on this iPhone, and how fast."
        ) {
            inUse
            speed
            memory
            defaults
        }
    }

    // MARK: - In use

    @ViewBuilder
    private var inUse: some View {
        if model.isUsingBuiltInBrain {
            YouSection("In use") {
                ValueRow(title: "Brain", value: BuiltInBrainOffer.title)
                RowDivider(inset: 0)
                ValueRow(title: "Made by", value: BuiltInBrainOffer.provider)
                RowDivider(inset: 0)
                ValueRow(title: "Context window", value: "\(Format.count(ModelRecord.builtIn.contextLength)) tokens")
                RowDivider(inset: 0)
                ValueRow(title: "Other devices use", value: servedName ?? "A download, when one asks")
            }
        } else if let record = residentDownload {
            YouSection("In use", footnote: "Other devices ask for this brain by its identifier.") {
                ValueRow(title: "Brain", value: record.displayName)
                RowDivider(inset: 0)
                ValueRow(title: "Identifier", value: record.id)
                if record.parameters != "—", !record.parameters.isEmpty {
                    RowDivider(inset: 0)
                    ValueRow(title: "Parameters", value: record.parameters)
                }
                RowDivider(inset: 0)
                ValueRow(title: "Quantisation", value: record.quantization)
                RowDivider(inset: 0)
                ValueRow(title: "File size", value: pdBytes(record.sizeBytes))
                if record.projectorSizeBytes > 0 {
                    RowDivider(inset: 0)
                    ValueRow(title: "Picture part", value: pdBytes(record.projectorSizeBytes))
                }
                RowDivider(inset: 0)
                ValueRow(title: "Memory in use", value: pdBytes(record.estimatedResidentBytes))
                RowDivider(inset: 0)
                ValueRow(title: "Context window", value: "\(Format.count(model.configuration.maxContextTokens)) tokens")
                RowDivider(inset: 0)
                ValueRow(
                    title: "Reads your day",
                    value: record.dayAccess(resident: model.personalDataToolGate).readsYourDay ? "Yes" : "No"
                )
            }
        } else {
            YouSection("In use") {
                Text("Nothing is in memory right now. Pocketd loads its brain when something needs it.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, PDSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The download in memory for the phone, from the catalogue.
    private var residentDownload: ModelRecord? {
        guard let id = model.loadedModelID, id != ModelRecord.builtInID else { return nil }
        return model.catalog.first { $0.id == id }
    }

    /// The download the server holds while the phone uses Apple's model.
    private var servedName: String? {
        guard let id = model.downloadedResidentID else { return nil }
        return model.catalog.first { $0.id == id }?.displayName
    }

    // MARK: - Speed

    /// Tokens a second, from the request log rather than from a benchmark.
    ///
    /// The log is the only place this number is measured on real work, so it
    /// is the only place worth reading it from. Empty until something has been
    /// answered, and the copy says so rather than printing a zero that reads
    /// like a failure.
    @ViewBuilder
    private var speed: some View {
        let rates = model.log.compactMap(\.tokensPerSecond)

        YouSection("Speed", footnote: rates.isEmpty ? nil : "Measured on real answers. It drops as the phone warms up.") {
            if rates.isEmpty {
                Text("Nothing measured yet this session.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .padding(.vertical, PDSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ValueRow(title: "Most recent", value: tokensPerSecond(rates[0]))
                RowDivider(inset: 0)
                ValueRow(title: "Best this session", value: tokensPerSecond(rates.max() ?? 0))
                RowDivider(inset: 0)
                ValueRow(title: "Answers measured", value: Format.count(rates.count))
            }
        }
    }

    private func tokensPerSecond(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(1)))) tokens/s"
    }

    // MARK: - Memory

    private var memory: some View {
        YouSection("Memory", footnote: model.budget.environmentNote) {
            ValueRow(title: "Pocketd may use", value: pdBytes(model.budget.usableBytes))
            RowDivider(inset: 0)
            // The phone the verdicts are judged as: this one, or on the
            // simulator the 8 GB iPhone it stands in for (the footnote says so).
            ValueRow(title: "This iPhone has", value: pdBytes(model.budget.verdictMemoryBytes))
            RowDivider(inset: 0)
            ValueRow(
                title: "Ceiling",
                // "Proven" is not a synonym for "estimated": it means a brain
                // of that size has actually loaded here, which is the only
                // measurement this app ever gets.
                value: model.budget.isProven ? "Proven by a real load" : "Estimated"
            )
        }
    }

    // MARK: - Defaults

    private var defaults: some View {
        let parameters = model.configuration.sampling

        return YouSection("Answer settings for other devices") {
            ValueRow(title: "Temperature", value: parameters.temperature.formatted(.number.precision(.fractionLength(2))))
            RowDivider(inset: 0)
            ValueRow(title: "Top-p", value: parameters.topP.formatted(.number.precision(.fractionLength(2))))
            RowDivider(inset: 0)
            ValueRow(title: "Top-k", value: "\(parameters.topK)")
            RowDivider(inset: 0)
            ValueRow(title: "Repeat penalty", value: parameters.repeatPenalty.formatted(.number.precision(.fractionLength(2))))
            RowDivider(inset: 0)
            ValueRow(title: "Seed", value: parameters.seed.map(String.init) ?? "Random")
            RowDivider(inset: 0)
            ValueRow(title: "Thinks first", value: model.configuration.reasoningEnabled ? "Yes" : "No")
            RowDivider(inset: 0)
            NavRow(symbol: "slider.horizontal.3", title: "Change these", detail: "In Server settings") {
                navigator.push(.settings)
            }
        }
    }
}

// MARK: - Previews

#Preview("Technical details light") {
    NavigationStack { BrainAdvancedView() }
        .environment(AppModel())
        .environment(Navigator())
}

#Preview("Technical details dark") {
    NavigationStack { BrainAdvancedView() }
        .environment(AppModel())
        .environment(Navigator())
        .preferredColorScheme(.dark)
}
