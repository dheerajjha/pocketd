import ActivityKit
import SwiftUI
import WidgetKit

/// The download's Live Activity, on the lock screen and in the Dynamic Island.
///
/// Everything here renders `ContentState` and nothing else. There is no path
/// from this file to the schedule, a conversation, or anything read off the
/// device — a download knows a name, two byte counts and whether it is paused.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle" : "arrow.down.circle")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state)).font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.modelName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        ProgressView(value: context.state.fraction)
                            .tint(context.state.isPaused ? .orange : .accentColor)
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

    @ViewBuilder private func lockScreen(
        _ context: ActivityViewContext<DownloadActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Downloading", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(percent(context.state)).font(.caption.monospacedDigit())
            }
            Text(context.attributes.modelName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            ProgressView(value: context.state.fraction)
                .tint(context.state.isPaused ? .orange : .accentColor)
            Text(subtitle(context.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func percent(_ state: DownloadActivityAttributes.ContentState) -> String {
        "\(Int(state.fraction * 100))%"
    }

    private func subtitle(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.isPaused { return "Paused" }
        guard state.totalBytes > 0 else { return "Starting…" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: state.receivedBytes)) of \(formatter.string(fromByteCount: state.totalBytes))"
    }
}
