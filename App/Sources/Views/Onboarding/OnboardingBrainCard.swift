import PocketdKit
import SwiftUI

/// The download, on the screen that started it.
///
/// v1's intro finished by telling the reader there was a progress bar at the
/// top of every screen — true the moment they left, and not true there, because
/// the banner lives above the tab bar and the tab bar is not on screen during
/// the intro. So the one place a first download is almost always started was
/// the one place that could not show it.
///
/// The numbers are the honest ones and they never move backward: percent, what
/// has actually arrived against what was asked for, and the measured pace. Past
/// the finish it says "Loading…" and then "Ready", because a bar that reaches
/// 100% and then sits there for nine seconds while the weights are mapped is a
/// bar that has lied about what "done" means.
struct OnboardingBrainCard: View {
    @Environment(AppModel.self) private var model

    /// The transfer this screen is watching, if the brain step started one.
    private var transfer: ModelTransfer? {
        model.transfers.values
            .sorted { $0.record.displayName < $1.record.displayName }
            .first
    }

    private var isReady: Bool { model.loadedModelID != nil }

    /// What the reader cancelled, if they did.
    ///
    /// Held here rather than inferred from the absent transfer, because "no
    /// download" and "a download you stopped thirty seconds ago" want different
    /// sentences: the first is a phone that never started one, the second is a
    /// promise that the bytes are still gettable.
    @State private var cancelled: ModelRecord?

    var body: some View {
        PDCard(warm: true) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("Brain")

                if isReady {
                    ready
                } else if let cancelled, transfer?.isActive != true {
                    // Ahead of the transfer branch, because a cancel leaves a
                    // `.stopping` and then a `.paused` transfer behind it and
                    // "Try again" is not what somebody who just tapped Cancel
                    // asked to be offered.
                    downloadLater(cancelled)
                } else if let transfer {
                    running(transfer)
                } else if !model.installed.isEmpty {
                    line(symbol: "checkmark.circle", tint: .pd.positive,
                         title: model.installed[0].displayName,
                         detail: "On this phone, ready to use.")
                } else {
                    line(symbol: "circle.dashed", tint: .pd.inkTertiary,
                         title: "No brain yet",
                         detail: "You can choose one any time from You.")
                }
            }
        }
        .onChange(of: isReady) { was, now in
            guard !was, now else { return }
            Haptics.success()
        }
    }

    // MARK: - States

    private var ready: some View {
        HStack(spacing: PDSpacing.m) {
            ReadyBurst(size: 44, announcement: "The brain is ready")
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                Text(model.installed.first(where: { $0.id == model.loadedModelID })?.displayName ?? "Ready")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Text("Ready")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.positive)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func running(_ transfer: ModelTransfer) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            line(
                symbol: symbol(for: transfer),
                tint: tint(for: transfer),
                title: transfer.record.displayName,
                detail: detail(for: transfer)
            )

            switch transfer.state {
            case .waiting, .stopping:
                ProgressStripe(fraction: 0, isIndeterminate: true)
            case .running, .paused:
                ProgressStripe(fraction: transfer.fraction)
            case .finished, .failed:
                EmptyView()
            }

            switch transfer.state {
            case .failed, .paused:
                pill("Try again") { model.download(transfer.record) }
            case .running, .waiting:
                // A download with no way out is how twenty-six minutes on a
                // slow link becomes somebody force-quitting the app. The bytes
                // already on disk are kept, so this is a pause with an honest
                // name rather than a discard.
                Button {
                    Haptics.tap()
                    cancelled = transfer.record
                    model.cancelDownload(transfer.record)
                } label: {
                    Text("Cancel")
                        .font(Font.pd.secondary.weight(.medium))
                        .foregroundStyle(Color.pd.inkSecondaryWarm)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PDPressStyle())
            case .stopping, .finished:
                EmptyView()
            }
        }
    }

    /// After Cancel. The card keeps its place and changes what it offers,
    /// rather than vanishing and leaving the reader wondering whether the
    /// gigabyte they already fetched went with it.
    private func downloadLater(_ record: ModelRecord) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            line(
                symbol: "clock",
                tint: .pd.inkSecondaryWarm,
                title: "Download later",
                detail: "Stopped. You can pick it up any time from You › Brain."
            )
            pill("Download now") {
                cancelled = nil
                model.download(record)
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(Font.pd.secondary.weight(.semibold))
                .foregroundStyle(Color.pd.ink)
                .padding(.horizontal, PDSpacing.m)
                .frame(height: PDMetric.pillHeight)
                .background(Color.pd.fillPill, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.pd.cardStrokeWarm, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PDPressStyle())
    }

    private func line(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: PDSpacing.m) {
            IconTile.small(symbol, fill: .pd.fillWarm, tint: tint)
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                Text(title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - The words

    private func detail(for transfer: ModelTransfer) -> String {
        switch transfer.state {
        case .waiting:
            return "Starting · \(OnboardingDownloadWords.size(transfer.record.totalDownloadBytes)) to fetch"
        case .stopping:
            return "Stopping · checking what can be kept"
        case let .running(progress):
            let percent = Int((transfer.fraction * 100).rounded(.down))
            var line = "\(percent)%"
            // The estimate sits beside the percentage rather than under the
            // byte counts, because "how long" is the question and the megabytes
            // are only the evidence for it.
            if let left = OnboardingDownloadWords.remaining(model.pace(for: transfer.id)) {
                line += " · \(left)"
            }
            line += "\n\(OnboardingDownloadWords.size(progress.receivedBytes))"
            line += " of \(OnboardingDownloadWords.size(progress.totalBytes))"
            if let pace = model.pace(for: transfer.id), pace.bytesPerSecond > 0 {
                line += " · \(OnboardingDownloadWords.size(Int64(pace.bytesPerSecond)))/s"
            }
            return line
        case .finished:
            return model.loadingModelID == transfer.id ? "Loading…" : "Downloaded · ready to use"
        case let .paused(message):
            return message
        case let .failed(message):
            return message
        }
    }

    private func symbol(for transfer: ModelTransfer) -> String {
        switch transfer.state {
        case .waiting, .stopping: "arrow.down.circle"
        case .running: "arrow.down.circle"
        case .finished: "checkmark.circle"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func tint(for transfer: ModelTransfer) -> Color {
        switch transfer.state {
        case .waiting, .stopping, .running: .pd.accentWarm
        case .finished: .pd.positive
        case .paused: .pd.caution
        case .failed: .pd.caution
        }
    }
}

#Preview("Brain card light") {
    OnboardingBrainCard()
        .padding(PDSpacing.heroGutter)
        .frame(maxHeight: .infinity)
        .background(Color.pd.canvasWarm.ignoresSafeArea())
        .environment(AppModel())
}

#Preview("Brain card dark") {
    OnboardingBrainCard()
        .padding(PDSpacing.heroGutter)
        .frame(maxHeight: .infinity)
        .background(Color.pd.canvasWarm.ignoresSafeArea())
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
