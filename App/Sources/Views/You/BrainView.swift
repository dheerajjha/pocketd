import PocketdKit
import SwiftUI

/// The brain: what this phone thinks with.
///
/// v1 called it Models and the screen read like a package manager — eight rows
/// of "Qwen3-1.7B · Q4_K_M · 1.06 GB" with a green "Fits" badge and no
/// indication of what any of it bought you. The words are the change: a person
/// who has never heard "model" can still pick between a fast one and a clever
/// one, and the manufacturer's name goes underneath so they can tell two apart.
///
/// Three lists in the order somebody actually needs them. What to get if you
/// have nothing, what you already have, and then everything else — which is
/// where a catalogue belongs when you are not shopping.
struct BrainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    @State private var oversized: ModelRecord?
    @State private var deleting: ModelRecord?

    var body: some View {
        YouDetailScreen(
            title: "Brain",
            subtitle: "The brain is a file on this phone. It does the thinking, it works with no signal, and nothing you ask it goes anywhere."
        ) {
            if let notice = model.offloadNotice {
                Callout(symbol: "memorychip", text: notice, tint: .pd.positive, fill: .pd.positiveSoft) {
                    HStack {
                        Spacer(minLength: 0)
                        SecondaryLink("OK") { model.dismissOffloadNotice() }
                    }
                }
            }

            if !recommended.isEmpty { recommendedSection }
            if !installed.isEmpty { installedSection }
            if !more.isEmpty { moreSection }
            addSection
        }
        .confirmationDialog(
            "This one is larger than this phone can hold",
            isPresented: Binding(get: { oversized != nil }, set: { if !$0 { oversized = nil } }),
            titleVisibility: .visible,
            presenting: oversized
        ) { record in
            Button("Download anyway", role: .destructive) {
                model.download(record, allowingOversized: true)
                oversized = nil
            }
            Button("Cancel", role: .cancel) { oversized = nil }
        } message: { record in
            // Both numbers, because "too large" without them is a verdict
            // nobody can check.
            Text("\(record.displayName) needs about \(pdBytes(record.estimatedResidentBytes)) of memory and iOS allows this app roughly \(pdBytes(model.budget.usableBytes)). It will most likely be stopped while loading.")
        }
        .confirmationDialog(
            "Remove this brain?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { record in
            Button("Remove", role: .destructive) {
                Task { await model.delete(record) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { record in
            Text(model.loadedModelID == record.id
                 ? "\(record.displayName) is in use right now. Removing it frees \(pdBytes(record.totalDownloadBytes)), which has to be downloaded again."
                 : "Frees \(pdBytes(record.totalDownloadBytes)). It has to be downloaded again to use it.")
        }
    }

    // MARK: - The three lists

    /// Up to three that span what this phone can hold, named for what you get
    /// rather than for how many parameters they have.
    private var recommended: [(tier: String, record: ModelRecord)] {
        let starters = model.starterModels
        let names = starters.count >= 3
            ? ["Quick", "Balanced", "Smart"]
            : (starters.count == 2 ? ["Quick", "Smart"] : ["Recommended"])
        return Array(zip(names, starters)).map { (tier: $0.0, record: $0.1) }
    }

    private var installed: [ModelRecord] {
        model.catalog.filter { model.isInstalled($0) }
    }

    private var more: [ModelRecord] {
        let shown = Set(recommended.map(\.record.id)).union(installed.map(\.id))
        return model.catalog.filter { !shown.contains($0.id) }
    }

    private var recommendedSection: some View {
        YouSection(
            "RECOMMENDED",
            footnote: "Bigger ones write better and answer slower. Every one of these has been checked against what this phone can hold."
        ) {
            ForEach(Array(recommended.enumerated()), id: \.element.record.id) { index, entry in
                if index > 0 { RowDivider(inset: 0) }
                row(for: entry.record, tier: entry.tier)
            }
        }
    }

    private var installedSection: some View {
        YouSection(
            "ON THIS PHONE",
            footnote: "Only one is in memory at a time. The others sit on disk costing nothing but space."
        ) {
            ForEach(Array(installed.enumerated()), id: \.element.id) { index, record in
                if index > 0 { RowDivider(inset: 0) }
                row(for: record, tier: nil)
            }
        }
    }

    private var moreSection: some View {
        YouSection(
            "MORE",
            footnote: "These are known to load on a phone. Anything else on Hugging Face is one screen further down."
        ) {
            ForEach(Array(more.enumerated()), id: \.element.id) { index, record in
                if index > 0 { RowDivider(inset: 0) }
                row(for: record, tier: nil)
            }
        }
    }

    private var addSection: some View {
        YouSection("ANYTHING ELSE") {
            NavRow(
                symbol: "magnifyingglass",
                title: "Add a brain",
                detail: "Search for one that is not on this list"
            ) {
                navigator.push(.addBrain)
            }
            RowDivider()
            NavRow(
                symbol: "gearshape.2",
                title: "Advanced",
                detail: "The technical details, for anyone who wants them"
            ) {
                navigator.push(.brainAdvanced)
            }
        }
    }

    // MARK: - One brain

    @ViewBuilder
    private func row(for record: ModelRecord, tier: String?) -> some View {
        let fit = model.fit(for: record)
        let transfer = model.transfer(for: record.id)
        let isInstalled = model.isInstalled(record)
        let isLoaded = model.loadedModelID == record.id

        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack(alignment: .top, spacing: PDSpacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: PDSpacing.xs) {
                        Text(tier ?? record.displayName)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                        if isLoaded { LoadedDot(label: "In use") }
                    }
                    if tier != nil {
                        Text(record.displayName)
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                    }
                    Text(isInstalled
                         ? "\(pdFitWords(fit)) · \(pdBytes(record.totalDownloadBytes))"
                         : pdDownloadLine(record.totalDownloadBytes))
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkTertiary)
                }
                Spacer(minLength: PDSpacing.xs)
                control(for: record, fit: fit, transfer: transfer, isInstalled: isInstalled, isLoaded: isLoaded)
            }

            fitNote(fit, isInstalled: isInstalled)

            if let transfer, transfer.isActive {
                inFlight(transfer, record: record)
            } else if let transfer {
                settled(transfer, record: record)
            }

            if let error = model.loadErrors[record.id] {
                // A brain that downloaded perfectly and then would not load. A
                // different failure with a different fix, and v1 wrote it into
                // the same slot as "the download failed".
                Text(error)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isInstalled {
                Button {
                    Haptics.warning()
                    deleting = record
                } label: {
                    Text("Remove")
                        .font(Font.pd.secondary.weight(.semibold))
                        .foregroundStyle(Color.pd.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(record.displayName)")
            }
        }
        .padding(.vertical, PDSpacing.s)
    }

    @ViewBuilder
    private func control(
        for record: ModelRecord,
        fit: DeviceBudget.Fit,
        transfer: ModelTransfer?,
        isInstalled: Bool,
        isLoaded: Bool
    ) -> some View {
        if let transfer, transfer.isActive {
            StatusPill(.neutral, "Getting it")
        } else if model.loadingModelID == record.id {
            StatusPill(.neutral, "Loading…")
        } else if isLoaded {
            PillButton(title: "Unload", symbol: "eject") {
                Task { await model.offloadModel() }
            }
            .accessibilityHint("Frees the memory it is using. The file stays on this phone.")
        } else if isInstalled {
            PillButton(title: "Use", symbol: "bolt") {
                Task { await model.loadModel(record) }
            }
            .disabled(model.isLoadingModel)
        } else if case .paused = transfer?.state {
            PillButton(title: "Resume", symbol: "arrow.down") { start(record, fit: fit) }
        } else {
            PillButton(title: "Get", symbol: "arrow.down") { start(record, fit: fit) }
        }
    }

    /// The consequence of the fit, in words, and only where there is one.
    ///
    /// A one-word badge saying "Tight" says which bucket it landed in and
    /// nothing about what happens next, which is the only part anybody needs at
    /// the moment of deciding whether to spend a gigabyte on it.
    @ViewBuilder
    private func fitNote(_ fit: DeviceBudget.Fit, isInstalled: Bool) -> some View {
        switch fit {
        case .comfortable:
            EmptyView()
        case .tight:
            Text("It loads, but leaves little room for a long conversation.")
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.caution)
                .fixedSize(horizontal: false, vertical: true)
        case .willNotFit:
            Text("Larger than this phone can hold. iOS would stop the app while loading it.")
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The estimate is a heuristic, so it warns rather than forbids — but it
    /// makes the consequence explicit first.
    private func start(_ record: ModelRecord, fit: DeviceBudget.Fit) {
        if fit.allowsDownload {
            model.download(record)
        } else {
            oversized = record
        }
    }

    // MARK: - Bytes moving

    @ViewBuilder
    private func inFlight(_ transfer: ModelTransfer, record: ModelRecord) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            if case .waiting = transfer.state {
                ProgressStripe(fraction: 0, isIndeterminate: true)
                Text("Starting…")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
            } else {
                ProgressStripe(fraction: transfer.fraction)
                HStack {
                    Text("\(Int((transfer.fraction * 100).rounded(.down)))%")
                        .font(Font.pd.footnote.monospaced().weight(.semibold))
                        .foregroundStyle(Color.pd.ink)
                    Spacer(minLength: PDSpacing.xs)
                    Text(pace(transfer))
                        .font(Font.pd.footnote.monospaced())
                        .foregroundStyle(Color.pd.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            SecondaryLink("Cancel") { model.cancelDownload(record) }
        }
        .padding(.top, PDSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    /// Finished, paused, failed or stopping — the four ends a transfer comes to.
    @ViewBuilder
    private func settled(_ transfer: ModelTransfer, record: ModelRecord) -> some View {
        switch transfer.state {
        case .finished:
            EmptyView()
        case let .paused(message):
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                Text(message)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.caution)
                    .fixedSize(horizontal: false, vertical: true)
                SecondaryLink("Throw away what arrived") {
                    Task { await model.discardPartialDownload(record) }
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                Text(message)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.danger)
                    .fixedSize(horizontal: false, vertical: true)
                SecondaryLink("Dismiss") { model.clearTransfer(transfer.id) }
            }
        case .stopping:
            Text("Stopping — checking what can be kept…")
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.inkSecondary)
        case .waiting, .running:
            EmptyView()
        }
    }

    private func pace(_ transfer: ModelTransfer) -> String {
        guard let progress = transfer.bytesSoFar else { return "" }
        var line = "\(pdBytes(progress.receivedBytes)) of \(pdBytes(progress.totalBytes))"
        if let pace = model.pace(for: transfer.id), pace.bytesPerSecond > 0 {
            line += " · \(pdBytes(Int64(pace.bytesPerSecond)))/s"
        }
        return line
    }
}

// MARK: - Previews

#Preview("Brain light") {
    NavigationStack { BrainView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Brain dark") {
    NavigationStack { BrainView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
