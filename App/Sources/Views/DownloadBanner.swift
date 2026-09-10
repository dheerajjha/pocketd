import SwiftUI
import PocketdKit

/// A download in progress, shown above whatever tab you are on.
///
/// Progress used to live only in the model's own row, which meant the feedback
/// existed exactly where nobody was looking: a model download runs for minutes,
/// and the reason you started one is usually to go and do something else. Once
/// you left the Models tab there was no way to tell whether the phone was still
/// working, how fast, or how much longer — so the honest options were to sit and
/// watch a row, or to guess.
struct DownloadBanner: View {
    @Environment(AppModel.self) private var model

    private var active: [(record: ModelRecord, progress: DownloadProgress)] {
        model.catalog.compactMap { record in
            guard let progress = model.downloads[record.id],
                  !model.dismissedDownloads.contains(record.id) else { return nil }
            return (record, progress)
        }
    }

    var body: some View {
        if let first = active.first {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.record.displayName)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text(subtitle(for: first))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)

                    Button("Stop") { model.cancelDownload(first.record) }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button {
                        model.dismissDownloadBanner(first.record.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hide this download")
                    .accessibilityHint("The download keeps running.")
                }

                ProgressView(value: first.progress.fraction)
                    .progressViewStyle(.linear)

                if active.count > 1 {
                    HStack {
                        Text("+\(active.count - 1) more downloading")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Downloading \(first.record.displayName), \(Int(first.progress.fraction * 100)) percent")
        }
    }

    /// "412 MB of 1.1 GB · 2.4 MB/s · about 4 minutes left"
    ///
    /// The rate needs a moment of history before it means anything, so the
    /// tail of this line appears a second or two after the download starts
    /// rather than showing a wrong number immediately.
    private func subtitle(for item: (record: ModelRecord, progress: DownloadProgress)) -> String {
        var parts = [
            "\(format(item.progress.receivedBytes)) of \(format(item.progress.totalBytes))"
        ]
        if let pace = model.pace(for: item.record.id), pace.bytesPerSecond > 0 {
            parts.append("\(format(Int64(pace.bytesPerSecond)))/s")
            if let remaining = pace.secondsRemaining {
                parts.append(remainingText(remaining))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Deliberately coarse. A download measured in minutes does not benefit
    /// from a seconds figure that is wrong the moment the network hiccups, and
    /// "about" is doing honest work — this is an extrapolation, not a promise.
    private func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = Double(minutes) / 60
        return "about \(hours < 1.5 ? "1 hour" : "\(Int(hours.rounded())) hours") left"
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
