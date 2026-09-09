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
    @State private var showHint = true

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The dot must answer "is anyone being served", which is the listener
    /// first and the device's physical limits second. Keying it on `condition`
    /// alone showed a green SERVING while the socket was dead and every client
    /// got connection refused.
    private var statusColour: Color {
        guard model.serverState.isRunning else { return .red }
        return model.condition.isServing ? .green : .orange
    }

    private var statusWord: String {
        guard model.serverState.isRunning else {
            if case .failed = model.serverState { return "FAILED" }
            return "STOPPED"
        }
        return model.condition.isServing ? "SERVING" : model.condition.rawValue.uppercased()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColour)
                        .frame(width: 7, height: 7)
                    Text(statusWord)
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

                if let error = model.lastServerError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                // Without this the screen has no exit anyone can see: no tab
                // bar, no status bar, and the home indicator fades too. It
                // stays until first touched rather than timing out, because a
                // hint nobody was looking at is the same as no hint.
                if showHint {
                    Text("Tap anywhere to exit")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 22)
                        .transition(.opacity)
                }
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
