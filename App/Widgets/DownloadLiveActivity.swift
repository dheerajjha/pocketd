import ActivityKit
import SwiftUI
import WidgetKit

/// The download's Live Activity, on the lock screen and in the Dynamic Island.
///
/// Everything here renders `ContentState` and nothing else. There is no path
/// from this file to the routines, a conversation, or anything read off the
/// device — a download knows two byte counts and whether it is paused.
///
/// It also deliberately does not say *which* brain. The attributes carry its
/// name, because that is how the app matches a running activity to its
/// transfer, but on a lock screen "Qwen3-1.7B-Q4_K_M" is a file name, and
/// somebody who finished the intro ten minutes ago knows exactly one thing
/// about it: Pocketd is getting ready. That is what the app says about the same
/// download on Today and under You › Brain, so it is what this says too.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(WidgetPalette.background)
                .activitySystemActionForegroundColor(WidgetPalette.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle" : "arrow.down.circle")
                        .foregroundStyle(context.state.isPaused ? WidgetPalette.caution : WidgetPalette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state)).font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(context.state))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        ProgressView(value: context.state.fraction)
                            .tint(context.state.isPaused ? WidgetPalette.caution : WidgetPalette.accent)
                        Text(subtitle(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "arrow.down")
            } compactTrailing: {
                Text(percent(context.state)).font(.caption2.monospacedDigit())
            } minimal: {
                // The minimal presentation is a circle roughly 16pt across, so
                // a percentage does not fit and a ring does. Anything with
                // digits in it here renders as unreadable smudge.
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
            }
        }
    }

    private func lockScreen(_ state: DownloadActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title(state), systemImage: state.isPaused ? "pause.circle" : "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetPalette.ink)
                Spacer()
                Text(percent(state))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(WidgetPalette.secondary)
            }
            ProgressView(value: state.fraction)
                .tint(state.isPaused ? WidgetPalette.caution : WidgetPalette.accent)
            Text(subtitle(state))
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
        }
        .padding()
    }

    // MARK: Words

    private func title(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.isPaused ? "Download paused" : "Getting Pocketd ready"
    }

    /// Whole percent, rounded down, like every other progress figure in the
    /// app: 99.6% is not finished, so it does not say 100.
    private func percent(_ state: DownloadActivityAttributes.ContentState) -> String {
        "\(Int((state.fraction * 100).rounded(.down)))%"
    }

    /// What is known and nothing more. Paused is either the person or a lost
    /// network, and the activity cannot tell which, so it says where the way
    /// on is — Resume, in the app — rather than guessing why.
    private func subtitle(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.isPaused { return "Open Pocketd to resume it." }
        guard state.totalBytes > 0 else { return "Starting…" }
        return "\(bytes(state.receivedBytes)) of \(bytes(state.totalBytes))"
    }

    /// The app's own spelling of a size (`pdBytes`): "412 MB", "1.1 GB".
    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
