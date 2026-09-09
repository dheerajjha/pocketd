import SwiftUI
import PocketdKit

/// A dim screen for a phone left serving on a desk.
///
/// The app's own advice is to keep it on screen, which today means an iPhone at
/// full brightness for hours. That burns the battery, risks burn-in on an OLED,
/// and — the part nobody connects — the display draws from the same thermal
/// budget as the GPU, so a bright screen costs tokens per second on a device
/// already close to throttling.
///
/// The content drifts slowly so no pixel holds the same colour for long.
struct DeskModeView: View {
    @Environment(AppModel.self) private var model
    @State private var drift = CGSize.zero

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.condition.isServing ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.condition.isServing ? "SERVING" : model.condition.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .kerning(1.5)
                }
                .foregroundStyle(.secondary)

                if case let .running(host, port) = model.serverState {
                    Text(host)
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(":\(String(port))")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let id = model.loadedModelID {
                    Text(id).font(.footnote).foregroundStyle(.secondary)
                }

                if let recent = model.log.first, let rate = recent.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", rate))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("\(model.log.count) requests")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.white.opacity(0.65))
            .offset(drift)
            .animation(.easeInOut(duration: 8), value: drift)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.deskMode = false }
        .onReceive(timer) { _ in
            // A slow wander, bounded well inside the safe area.
            drift = CGSize(
                width: .random(in: -26...26),
                height: .random(in: -46...46)
            )
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityLabel("Desk mode. Double tap to exit.")
    }
}
