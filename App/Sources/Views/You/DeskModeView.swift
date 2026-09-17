import PocketdKit
import SwiftUI

/// A dim screen for a phone left serving on a desk.
///
/// The app's own advice is to keep it on screen, which otherwise means an
/// iPhone at full brightness for hours. That burns the battery, risks burn-in
/// on an OLED, and — the part nobody connects — the display draws from the same
/// thermal budget as the GPU, so a bright screen costs speed on a device
/// already close to throttling.
///
/// The content drifts slowly so no pixel holds the same colour for long, and
/// the palette is the app's own rather than raw system greys: mono for every
/// readout, one accent for the status word, and black behind all of it because
/// black is what an OLED does not light.
struct DeskModeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = CGSize.zero
    @State private var showHint = true

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The dot must answer "is anyone being served", which is the listener
    /// first and the device's physical limits second. Keying it on `condition`
    /// alone showed a green SERVING while the socket was dead and every client
    /// got connection refused.
    private var statusTint: Color {
        guard model.serverState.isRunning else { return .pd.danger }
        return model.condition.isServing ? .pd.positive : .pd.caution
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

            VStack(spacing: PDSpacing.s) {
                HStack(spacing: PDSpacing.xs) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 7, height: 7)
                    Text(statusWord)
                        .font(Font.pd.label)
                        .tracking(1.4)
                        .foregroundStyle(statusTint)
                }

                if case let .running(host, port) = model.serverState {
                    Text(host)
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(":\(String(port))")
                        .font(Font.pd.monoValue)
                        .foregroundStyle(.white.opacity(0.42))
                }

                if let id = model.loadedModelID {
                    Text(id)
                        .font(Font.pd.footnote)
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, PDSpacing.xl)
                }

                if let recent = model.log.first, let rate = recent.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", rate))
                        .font(Font.pd.footnote.monospaced())
                        .foregroundStyle(.white.opacity(0.42))
                }

                Text("\(model.log.count) requests")
                    .font(Font.pd.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.28))

                if let error = model.lastServerError {
                    Text(error)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.caution)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, PDSpacing.xxl)
                }

                // Without this the screen has no exit anyone can see: no tab
                // bar, no status bar, and the home indicator fades too. It stays
                // until first touched rather than timing out, because a hint
                // nobody was looking at is the same as no hint.
                if showHint {
                    Text("Tap anywhere to exit")
                        .font(Font.pd.footnote)
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.top, PDSpacing.xl)
                        .transition(.opacity)
                }
            }
            .offset(drift)
            .animation(.easeInOut(duration: 8), value: drift)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showHint = false
            model.deskMode = false
        }
        .onReceive(timer) { _ in
            // A slow wander, bounded well inside the safe area. Reduce Motion
            // means what it says: the whole point of the drift is burn-in, and
            // somebody who cannot tolerate movement gets a static screen and
            // the dimming instead.
            guard !reduceMotion else { return }
            drift = CGSize(width: .random(in: -26...26), height: .random(in: -46...46))
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityLabel("Desk mode. \(statusWord). Double tap to exit.")
    }
}

// MARK: - Previews

#Preview("Desk mode") {
    DeskModeView()
        .environment(AppModel())
}
