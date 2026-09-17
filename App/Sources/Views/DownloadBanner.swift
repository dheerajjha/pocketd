import SwiftUI
import PocketdKit

/// What is arriving on this phone, shown above whatever tab you are on.
///
/// Progress used to live only in the model's own row, which meant the feedback
/// existed exactly where nobody was looking: a model download runs for minutes,
/// and the reason you started one is usually to go and do something else. Once
/// you left the Models tab there was no way to tell whether the phone was still
/// working, how fast, or how much longer — so the honest options were to sit and
/// watch a row, or to guess.
///
/// It now follows the whole life of a transfer rather than only the middle of
/// it. Four of the six states it draws had no representation anywhere in the
/// app: the second or two before the first byte, the pause between Stop and
/// knowing whether anything was kept, the moment it finishes — and, for
/// anything downloaded from search, every state, because this view built its
/// list by walking the curated catalogue and a searched model is not in it.
/// See `ModelTransfer`.
struct DownloadBanner: View {
    @Environment(AppModel.self) private var model
    /// Tapping the banner goes to the row it is about. A status line that
    /// cannot be followed anywhere is a dead end for anyone wanting to cancel.
    var goTo: (AppTab) -> Void = { _ in }

    private var shown: [ModelTransfer] { model.visibleTransfers }

    var body: some View {
        if let first = shown.first {
            // Two rows, not one. Putting the controls beside a two-line block
            // squeezed the status line into the width left over, so a normal
            // sentence — "32.2 MB of 270.9 MB · 6.3 MB/s · under a minute
            // left" — wrapped and orphaned "a minute left" under the bar.
            // Giving that line the whole width costs nothing and it fits.
            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                HStack(spacing: PDSpacing.s) {
                    icon(for: first)
                        .frame(width: 20)

                    Button { goTo(.you) } label: {
                        Text(first.record.displayName)
                            .font(Font.pd.secondary.weight(.semibold))
                            .foregroundStyle(Color.pd.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PDPressStyle())
                    .accessibilityHint("Opens the You tab.")

                    // The number people actually look for, and it was nowhere
                    // on this screen: the bar said roughly-a-third and the text
                    // said megabytes, and neither says 34%.
                    if case .running = first.state {
                        Text(percent(first.fraction))
                            .font(Font.pd.monoValue)
                            .foregroundStyle(Color.pd.inkSecondary)
                    }

                    actions(for: first)
                }

                Text(subtitle(for: first))
                    .font(Font.pd.caption)
                    .foregroundStyle(tint(for: first) ?? Color.pd.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)

                bar(for: first)

                if shown.count > 1 {
                    Text(queueLine)
                        .font(Font.pd.caption)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, PDSpacing.m)
            .padding(.vertical, PDSpacing.m)
            .background(Color.pd.floatSurface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.pd.divider).frame(height: 1)
            }
            .animation(PDMotion.gentle, value: first.state)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel(for: first))
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func icon(for transfer: ModelTransfer) -> some View {
        switch transfer.state {
        case .waiting, .stopping:
            ProgressView().controlSize(.small)
        case .running:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.pd.accent)
        case .finished:
            // The one moment the app has to say the thing worked. It said
            // nothing at all before: the bar vanished and the model appeared in
            // a section that may well have been collapsed or scrolled past.
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.pd.positive)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(Color.pd.caution)
        case .failed:
            // Amber, not red. A download that did not finish is not a fault in
            // the app and is not a thing to be alarmed by — this palette keeps
            // red for a transport failure and uses amber for "your turn".
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.pd.caution)
        }
    }

    @ViewBuilder
    private func bar(for transfer: ModelTransfer) -> some View {
        switch transfer.state {
        case .waiting:
            // Indeterminate on purpose. There is no total yet — the server has
            // not answered — and a determinate bar at zero claims a number
            // nobody has.
            ProgressStripe(fraction: 0, isIndeterminate: true)
        case .running, .stopping:
            ProgressStripe(fraction: transfer.fraction)
        case .finished:
            ProgressStripe(fraction: 1)
        case .paused:
            ProgressStripe(fraction: transfer.fraction)
        case .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(for transfer: ModelTransfer) -> some View {
        switch transfer.state {
        case .waiting, .running:
            LinkPill(title: "Stop", symbol: "stop.fill") {
                model.cancelDownload(transfer.record)
            }
            closeButton("Hide this download", hint: "The download keeps running.") {
                model.dismissDownloadBanner(transfer.id)
            }
        case .stopping:
            // No Resume yet, on purpose: this state exists precisely because
            // we do not know what Resume would do.
            EmptyView()
        case .paused, .failed:
            LinkPill(title: "Resume", symbol: "arrow.clockwise") {
                model.download(transfer.record)
            }
            closeButton("Dismiss") { model.clearTransfer(transfer.id) }
        case .finished:
            closeButton("Dismiss") { model.clearTransfer(transfer.id) }
        }
    }

    private func closeButton(
        _ label: String,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.pd.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }

    // MARK: Words

    /// The second line, which is a different sentence in every state.
    private func subtitle(for transfer: ModelTransfer) -> String {
        switch transfer.state {
        case .waiting:
            return "Starting · \(format(transfer.record.totalDownloadBytes)) to fetch"
        case .stopping:
            return "Stopping · checking what can be kept"
        case let .running(progress):
            var parts = ["\(format(progress.receivedBytes)) of \(format(progress.totalBytes))"]
            if let pace = model.pace(for: transfer.id), pace.bytesPerSecond > 0 {
                parts.append("\(format(Int64(pace.bytesPerSecond)))/s")
                if let remaining = pace.secondsRemaining {
                    parts.append(remainingText(remaining))
                }
            }
            return parts.joined(separator: " · ")
        case .finished:
            // Which of the two it is matters: a model that is downloaded is
            // still thirty seconds from answering anything, and saying "ready"
            // while it loads is the kind of small lie that gets someone
            // tapping Chat and finding nothing there.
            if model.loadingModelID == transfer.id {
                return "Downloaded · loading it now"
            }
            if model.loadedModelID == transfer.id {
                return "Downloaded and loaded · ready to use"
            }
            // Not "the Models tab": there has not been one since v2, and an
            // instruction naming a screen the app does not have is worse than
            // no instruction. The name above this line is the button.
            return "Downloaded · \(format(transfer.record.totalDownloadBytes)) · tap the name to load it"
        case let .paused(message):
            return message
        case let .failed(message):
            return message
        }
    }

    private func tint(for transfer: ModelTransfer) -> Color? {
        switch transfer.state {
        case .paused, .failed: .pd.caution
        case .finished: .pd.positive
        case .waiting, .running, .stopping: nil
        }
    }

    private var queueLine: String {
        let others = shown.dropFirst()
        let active = others.filter(\.isActive).count
        if active == others.count {
            return "+\(others.count) more downloading"
        }
        return "+\(others.count) more"
    }

    private func accessibilityLabel(for transfer: ModelTransfer) -> String {
        switch transfer.state {
        case .waiting:
            "Starting download of \(transfer.record.displayName)"
        case .stopping:
            "Stopping \(transfer.record.displayName)"
        case .running:
            "Downloading \(transfer.record.displayName), \(percent(transfer.fraction))"
        case .finished:
            "\(transfer.record.displayName) downloaded"
        case let .paused(message):
            "\(transfer.record.displayName) paused. \(message)"
        case let .failed(message):
            "\(transfer.record.displayName) failed. \(message)"
        }
    }

    /// Deliberately coarse. A download measured in minutes does not benefit
    /// from a seconds figure that is wrong the moment the network hiccups, and
    /// "about" is doing honest work — this is an extrapolation, not a promise.
    private func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = Double(minutes) / 60
        return "about \(hours < 1.5 ? "1 hour" : "\(Int(hours.rounded())) hours") left"
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Previews

#if DEBUG
private func previewRecord(_ name: String, size: Int64) -> ModelRecord {
    var record = ModelCatalog.all[1]
    record.id = name.lowercased()
    record.displayName = name
    record.sizeBytes = size
    record.projectorSizeBytes = 0
    return record
}

@MainActor
private func banner(_ transfers: [ModelTransfer]) -> some View {
    let model = AppModel()
    model.previewSeed(transfers)
    return VStack(spacing: 0) {
        DownloadBanner()
        Spacer()
    }
    .environment(model)
}

#Preview("Starting") {
    banner([ModelTransfer(
        record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
        state: .waiting
    )])
}

#Preview("Downloading") {
    banner([ModelTransfer(
        record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
        state: .running(DownloadProgress(
            modelID: "qwen3-1.7b-q4_k_m",
            receivedBytes: 412_000_000,
            totalBytes: 1_117_000_000
        ))
    )])
}

#Preview("Finished") {
    banner([ModelTransfer(
        record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
        state: .finished(at: Date())
    )])
}

#Preview("Paused") {
    banner([ModelTransfer(
        record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
        state: .paused("Paused — 393 MB kept. Resume picks up where it stopped."),
        lastProgress: DownloadProgress(
            modelID: "qwen3-1.7b-q4_k_m",
            receivedBytes: 412_000_000,
            totalBytes: 1_117_000_000
        )
    )])
}

#Preview("Failed") {
    banner([ModelTransfer(
        record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
        state: .failed("This iPhone is offline. The bytes already fetched are kept.")
    )])
}

#Preview("Two at once") {
    banner([
        ModelTransfer(
            record: previewRecord("Qwen3-1.7B-Q4_K_M", size: 1_117_000_000),
            state: .running(DownloadProgress(
                modelID: "qwen3-1.7b-q4_k_m",
                receivedBytes: 412_000_000,
                totalBytes: 1_117_000_000
            ))
        ),
        ModelTransfer(
            record: previewRecord("SmolLM2-360M-Q8_0", size: 386_000_000),
            state: .waiting
        )
    ])
}
#endif
