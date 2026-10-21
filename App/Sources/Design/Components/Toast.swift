import Observation
import SwiftUI
import UIKit

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
    /// The one thing the toast can do — "Undo" after a reminder is ticked off.
    /// Nil for the ordinary toast that only reports.
    var action: ToastAction?

    /// By identity. Two toasts with the same words are still two events, and
    /// the action is a closure, which has no equality to compare.
    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// The verb on a toast. One, short: "Undo".
struct ToastAction {
    var title: String
    var perform: @MainActor () -> Void
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

    /// - Parameters:
    ///   - seconds: How long it stays. Nil picks it: 2.4 seconds, or 5 when
    ///     there is an action to reach for.
    ///   - action: An "Undo", or nothing.
    func show(
        _ text: String,
        symbol: String? = "checkmark.circle",
        tint: Color = .pd.ink,
        seconds: Double? = nil,
        action: ToastAction? = nil
    ) {
        show(ToastMessage(
            text: text,
            symbol: symbol,
            tint: tint,
            seconds: seconds ?? (action == nil ? 2.4 : 5),
            action: action
        ))
    }

    func show(_ message: ToastMessage) {
        dismissal?.cancel()
        current = message
        // A toast appears where VoiceOver's cursor is not, so it is announced;
        // otherwise it is invisible to exactly the people who cannot glance
        // at it. With an action, it also stays long enough to be reached.
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if voiceOver {
            AccessibilityNotification.Announcement(message.text).post()
        }
        let seconds = voiceOver && message.action != nil ? max(message.seconds, 10) : message.seconds
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
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
    /// Called after the action runs, so the toast that offered "Undo" goes
    /// away once it has been used.
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: PDSpacing.xs) {
            HStack(spacing: PDSpacing.xs) {
                if let symbol = message.symbol {
                    Image(systemName: symbol)
                        .font(Font.pd.secondary)
                        .foregroundStyle(message.tint)
                }
                Text(message.text)
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.ink)
                    .lineLimit(3)
            }
            .accessibilityElement(children: .combine)

            if let action = message.action {
                Spacer(minLength: PDSpacing.xs)
                Button {
                    Haptics.tap()
                    action.perform()
                    onAction()
                } label: {
                    Text(action.title)
                        .font(Font.pd.secondary.weight(.semibold))
                        .foregroundStyle(Color.pd.accent)
                        .padding(.horizontal, PDSpacing.xs)
                        .pdHitTarget()
                }
                .buttonStyle(PDPressStyle())
            }
        }
        .padding(.leading, PDSpacing.m)
        .padding(.trailing, message.action == nil ? PDSpacing.m : PDSpacing.xs)
        .padding(.vertical, message.action == nil ? PDSpacing.s : 0)
        .background {
            Capsule(style: .continuous).fill(Color.pd.floatSurface).pdFloatShadow()
        }
        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

private struct ToastOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let center: ToastCenter
    /// How far above the bottom safe area the toast sits.
    let bottomInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = center.current {
                Toast(message: message) { center.dismiss() }
                    .padding(.bottom, bottomInset)
                    .padding(.horizontal, PDSpacing.gutter)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    // A tap anywhere else on the toast puts it away. The
                    // action button inside takes its own taps first.
                    .onTapGesture { center.dismiss() }
            }
        }
        .animation(PDMotion.gentle, value: center.current?.id)
    }
}

extension View {
    /// Show whatever `center` is holding, over this view.
    ///
    /// `bottomInset` clears whatever is pinned to the bottom of the screen —
    /// the composer, on Today and on a detail page.
    func toast(_ center: ToastCenter, bottomInset: CGFloat = 0) -> some View {
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
            PrimaryButton(title: "Tick one off", arrow: false) {
                center.show("Ticked off", action: ToastAction(title: "Undo") {})
            }
            Toast(message: ToastMessage(text: "Reminder set for 17:00", symbol: "bell"))
            Toast(message: ToastMessage(
                text: "Ticked off",
                symbol: "checkmark.circle",
                tint: .pd.positive,
                action: ToastAction(title: "Undo") {}
            ))
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pdCanvas()
        .toast(center)
    }
}
