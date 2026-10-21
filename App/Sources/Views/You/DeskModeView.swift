import Combine
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

    /// Plain words in the small caps label. Never the condition's raw value:
    /// "THERMAL" is an enum case, not something a person reads off a desk.
    private var statusWord: String {
        guard model.serverState.isRunning else {
            if case .failed = model.serverState { return "Couldn't start" }
            return "Stopped"
        }
        return model.condition.statusWord
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: PDSpacing.s) {
                HStack(spacing: PDSpacing.xs) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 7, height: 7)
                    Text(statusWord.uppercased())
                        .font(Font.pd.label)
                        .tracking(1.4)
                        .foregroundStyle(statusTint)
                }

                if case let .running(host, port) = model.serverState {
                    // A text style, so the one thing this screen exists to
                    // show grows with the reader's text size like everything
                    // else; the scale factor only keeps a long address on one
                    // line on a narrow phone.
                    Text(host)
                        .font(.system(.largeTitle, design: .monospaced, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(":\(String(port))")
                        .font(Font.pd.monoValue)
                        .foregroundStyle(.white.opacity(0.55))
                }

                // The brain other devices are answered by, by its name — or
                // nothing. A raw id ("smollm2-360m") is what a client types,
                // not what the phone calls it.
                if let name = model.servedBrainName {
                    Text(name)
                        .font(Font.pd.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.horizontal, PDSpacing.xl)
                }

                Text(Format.counted(model.log.count, "request"))
                    .font(Font.pd.footnote)
                    .foregroundStyle(.white.opacity(0.55))

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
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, PDSpacing.xl)
                        .transition(.opacity)
                }
            }
            .offset(drift)
            .animation(.easeInOut(duration: 8), value: drift)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: exit)
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
        // One element that says everything on screen and leaves on a double
        // tap, rather than a handful of mono fragments with no way out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .accessibilityHint("Exits desk mode")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { exit() }
    }

    private var spokenSummary: String {
        var parts = ["Desk mode", statusWord]
        if case let .running(host, port) = model.serverState { parts.append("\(host), port \(port)") }
        if let name = model.servedBrainName { parts.append(name) }
        parts.append(Format.counted(model.log.count, "request"))
        return parts.joined(separator: ". ")
    }

    private func exit() {
        showHint = false
        model.deskMode = false
    }
}

// MARK: - Previews

#Preview("Desk mode") {
    DeskModeView()
        .environment(AppModel())
}
