import Observation
import SwiftUI

/// One sentence, briefly, at the bottom of the screen.
///
/// This is where v1's full-width coloured banners go: a model switch, an
/// offload notice, "Thanks" after a thumbs-up. All of them are things that have
/// already happened and that nobody needs to acknowledge, and a banner that
/// occupies the layout until it is dismissed treats them as if they were.
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String?
    var tint: Color = .pd.ink
    /// How long it stays. Long enough to read twice; anything that needs more
    /// than that is not a toast.
    var seconds: Double = 2.4
}

/// What shows toasts.
///
/// An object in the environment rather than a `@State` on each screen, because
/// the things that raise one — a tool loop finishing, a download completing —
/// are not on the screen that should show it, and because two toasts at once is
/// a bug rather than a layout problem. There is one slot, and a new message
/// replaces whatever was in it.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: ToastMessage?

    /// The timer that will clear `current`. Cancelled and replaced on every
    /// show, so a second toast does not inherit the first one's remaining
    /// time and vanish immediately.
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    init() {}

    func show(_ text: String, symbol: String? = "checkmark.circle", tint: Color = .pd.ink, seconds: Double = 2.4) {
        show(ToastMessage(text: text, symbol: symbol, tint: tint, seconds: seconds))
    }

    func show(_ message: ToastMessage) {
        dismissal?.cancel()
        current = message
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

/// The toast itself.
struct Toast: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: PDSpacing.xs) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(message.tint)
            }
            Text(message.text)
                .font(Font.pd.secondary.weight(.medium))
                .foregroundStyle(Color.pd.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, PDSpacing.m)
        .padding(.vertical, PDSpacing.s)
        .background(Color.pd.floatSurface, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        .pdFloatShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.text)
    }
}

private struct ToastOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let center: ToastCenter
    /// How far above the bottom safe area the toast sits. Defaults to clear the
    /// floating tab bar, which is what it is almost always competing with.
    let bottomInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = center.current {
                Toast(message: message)
                    .padding(.bottom, bottomInset)
                    .padding(.horizontal, PDSpacing.gutter)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .onTapGesture { center.dismiss() }
                    // Deliberately not hit-testable beyond the tap above: a
                    // toast that blocks the control underneath it turns a
                    // confirmation into an obstacle.
                    .allowsHitTesting(true)
            }
        }
        .animation(PDMotion.gentle, value: center.current?.id)
    }
}

extension View {
    /// Show whatever `center` is holding, over this view.
    func toast(_ center: ToastCenter, bottomInset: CGFloat = PDMetric.tabBarClearance) -> some View {
        modifier(ToastOverlay(center: center, bottomInset: bottomInset))
    }
}

#Preview("Toast light") {
    ToastPreview()
}

#Preview("Toast dark") {
    ToastPreview().preferredColorScheme(.dark)
}

private struct ToastPreview: View {
    @State private var center = ToastCenter()

    var body: some View {
        VStack(spacing: PDSpacing.m) {
            PrimaryButton(title: "Say thanks", arrow: false) {
                center.show("Thanks")
            }
            PrimaryButton(title: "Switched brain", arrow: false) {
                center.show("Now using the smaller brain", symbol: "brain")
            }
            Toast(message: ToastMessage(text: "Reminder set for 17:00", symbol: "bell"))
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pdCanvas()
        .toast(center)
    }
}
