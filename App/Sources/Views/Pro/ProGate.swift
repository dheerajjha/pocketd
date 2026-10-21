import PocketdKit
import SwiftUI

/// Runs a Pro feature when Pocketd Pro is on, and offers Pro when it is not.
///
///     @Environment(\.proGate) private var proGate
///
///     Toggle("Allow other devices", isOn: Binding(
///         get: { isOn },
///         set: { on in on ? proGate(.laptop) { start() } : stop() }
///     ))
///
/// For someone with Pro the action runs at once. For anyone else the Pro sheet
/// opens, and the action runs as it closes with Pro on — so flipping the
/// switch, paying, and finding the switch on is one gesture rather than two.
/// Closing the sheet without buying runs nothing.
///
/// The sheet is presented by a host, `proGateHost()`, installed on each screen
/// that has a gated control. Not one host at the root: SwiftUI presents a sheet
/// only from a view that is not already presenting one, so a gate inside a
/// sheet (the routine templates) needs a host inside that sheet; and the host's
/// thank-you toast belongs to the screen's `ToastCenter`, which lives below the
/// root. A gate with no host above it does nothing, and says so in a Debug
/// build's console — a dead button is found in testing, a free one is not.
///
/// `.proGated(_:perform:)` is the same thing for a view that is not a button
/// yet: it makes it one, and hosts its own sheet.
struct ProGate {
    /// The feature is nil for `offer()`, which is asked for Pro itself.
    fileprivate var request: @MainActor (ProFeature?, @escaping @MainActor () -> Void) -> Void = { feature, _ in
        #if DEBUG
        print("ProGate: no proGateHost() above a \(feature?.rawValue ?? "Pro") gate, so nothing ran")
        #endif
    }

    @MainActor
    func callAsFunction(_ feature: ProFeature, perform action: @escaping @MainActor () -> Void) {
        request(feature, action)
    }

    /// The Pro sheet with nothing waiting behind it — the Pocketd Pro row on
    /// You. Does nothing once Pro is on.
    @MainActor
    func offer() {
        request(nil) {}
    }
}

extension EnvironmentValues {
    @Entry var proGate = ProGate()
}

extension View {
    /// Presents the Pro sheet for every `proGate` inside this view.
    func proGateHost() -> some View {
        modifier(ProGateHost())
    }

    /// This view as a button that runs `action` when Pocketd Pro is on, and
    /// opens the Pro sheet when it is not.
    func proGated(_ feature: ProFeature, perform action: @escaping @MainActor () -> Void) -> some View {
        ProGateButton(feature, action: action) { self }
            .buttonStyle(PDPressStyle())
    }
}

/// A region with a host of its own, handing its content that host's gate.
///
///     ProGateReader { proGate in
///         PillButton(title: "Get") { proGate(.brains) { download() } }
///     }
///
/// For a control in a view that cannot install a host above itself: a view's
/// `@Environment` is read from *above* it, so a host added inside its own
/// `body` is invisible to it — and a sheet like the routine templates has no
/// view of ours above it to put one on.
struct ProGateReader<Content: View>: View {
    @ViewBuilder let content: (ProGate) -> Content

    init(@ViewBuilder content: @escaping (ProGate) -> Content) {
        self.content = content
    }

    var body: some View {
        Reader(content: content)
            .proGateHost()
    }

    private struct Reader: View {
        @Environment(\.proGate) private var proGate
        let content: (ProGate) -> Content

        var body: some View { content(proGate) }
    }
}

/// `Button`, with the gate in front of its action when `gated` is true. The
/// label and style are the caller's either way, so a row looks the same
/// whether or not it is a Pro one.
struct ProGateButton<Label: View>: View {
    let feature: ProFeature
    var gated: Bool
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    init(
        _ feature: ProFeature,
        gated: Bool = true,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.feature = feature
        self.gated = gated
        self.action = action
        self.label = label
    }

    var body: some View {
        ProGateReader { proGate in
            Button {
                if gated {
                    proGate(feature, perform: action)
                } else {
                    action()
                }
            } label: {
                label()
            }
        }
    }
}

/// Where a gate's sheet comes from, and what happens once Pro is on.
private struct ProGateHost: ViewModifier {
    /// Optional so a screen's preview without a store still draws; the app
    /// always has one (`PocketdApp`). Without one a gate runs its action.
    @Environment(ProStore.self) private var pro: ProStore?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    @State private var offer: Offer?
    /// The action waiting for the sheet to finish closing, set once Pro came
    /// on inside it.
    @State private var unlocked: Unlocked?

    struct Offer: Identifiable {
        let id = UUID()
        let feature: ProFeature?
        let action: @MainActor () -> Void
    }

    struct Unlocked {
        let action: @MainActor () -> Void
    }

    func body(content: Content) -> some View {
        content
            .environment(\.proGate, ProGate { feature, action in
                request(feature, action)
            })
            .sheet(item: $offer, onDismiss: carryOn) { offer in
                ProSheet {
                    unlocked = Unlocked(action: offer.action)
                }
            }
    }

    private func request(_ feature: ProFeature?, _ action: @escaping @MainActor () -> Void) {
        guard let pro else {
            action()
            return
        }
        if pro.isPro {
            action()
            return
        }
        Task {
            // A tap in the first moments after launch, or after an offline
            // launch, asks the App Store once more before offering anything.
            await pro.settle()
            await pro.refreshIfNeeded()
            if pro.isPro {
                action()
            } else {
                offer = Offer(feature: feature, action: action)
            }
        }
    }

    /// After the sheet has gone: thanks, then what the person reached for.
    /// Here rather than in the sheet's own callback, so the toast is not drawn
    /// under a sheet still on its way down, and an action that closes or
    /// pushes a screen does not race the dismissal.
    private func carryOn() {
        guard let unlocked else { return }
        self.unlocked = nil
        toasts?.show(ProCopy.unlocked, symbol: ProCopy.statusSymbolName, tint: .pd.accent)
        unlocked.action()
    }
}

/// "Pro", beside a control that needs Pocketd Pro, so the person knows before
/// they tap. Draws nothing once Pro is on.
///
/// The neutral `StatusPill`, the same capsule a `NavRow` takes as its
/// `status` — pass `ProBadge.status(for:)` there.
struct ProBadge: View {
    @Environment(ProStore.self) private var pro: ProStore?

    var body: some View {
        if !(pro?.isPro ?? false) {
            StatusPill(.neutral, ProCopy.badge)
                .accessibilityLabel(ProCopy.badgeSpoken)
        }
    }

    /// The same capsule as a `NavRow`/`RowShell` status, or nil once Pro is on.
    static func status(for pro: ProStore?) -> (kind: StatusPill.Kind, text: String)? {
        (pro?.isPro ?? false) ? nil : (.neutral, ProCopy.badge)
    }
}

/// A row title with the "Pro" capsule beside it — or under it, once the two
/// cannot share a line without breaking a word. Beside a narrow title column
/// at the accessibility sizes the capsule squeezed "Evening" into "Eveni/ng".
struct ProBadgedTitle<Title: View>: View {
    var showsBadge = true
    @ViewBuilder let title: () -> Title

    var body: some View {
        if showsBadge {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PDSpacing.xs) {
                    title()
                    ProBadge()
                }
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    title()
                    ProBadge()
                }
            }
        } else {
            title()
        }
    }
}

#if DEBUG
extension View {
    /// `-pocketd.proSheet`: the Pro sheet open at launch, for a screenshot.
    /// `PocketdApp` applies it at the root; the store is passed in because
    /// that is outside the `.environment` it injects. See `ProStage`.
    func proSheetIfRequested(_ pro: ProStore) -> some View {
        modifier(ProSheetStage(pro: pro))
    }
}

private struct ProSheetStage: ViewModifier {
    let pro: ProStore
    @State private var shows = ProStage.opensSheet

    func body(content: Content) -> some View {
        content.sheet(isPresented: $shows) {
            ProSheet().environment(pro)
        }
    }
}
#endif

#Preview("Gated row") {
    VStack(spacing: PDSpacing.m) {
        HStack {
            Text("Search Hugging Face")
                .font(Font.pd.rowTitle)
            ProBadge()
            Spacer()
        }
        .padding()
        .proGated(.brains) {}
    }
    .padding(PDSpacing.gutter)
    .frame(maxHeight: .infinity)
    .pdCanvas()
    .environment(ProStore())
}
