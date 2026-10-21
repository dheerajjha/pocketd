import PocketdKit
import SwiftUI

/// Pocketd Pro's rows at the top of You › About: whether it is on, and while
/// it is not, the way to buy it and the way to restore it.
///
///     YouSection("About") {
///         ProAboutRows()
///         LinkRow(symbol: "star", title: "Rate Pocketd") { … }
///         …
///     }
///
/// Ends with its own divider, so it drops in above the first row of a card.
/// Hosts its own sheet, outside the branch that changes when Pro comes on, so
/// buying from here does not pull the sheet's presenter out from under it.
///
/// "Restore purchase" is here and on the sheet because App Review asks for it
/// wherever a purchase can be made, and because it is the one thing that puts
/// an early supporter right when the App Store could not be read at launch.
/// Once Pro is on there is nothing to restore, and the row goes.
struct ProAboutRows: View {
    @Environment(ProStore.self) private var pro: ProStore?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    var body: some View {
        Group {
            if let pro {
                if pro.isPro {
                    RowShell(symbol: ProCopy.statusSymbolName, title: ProCopy.name, detail: ProCopy.rowState(pro.entitlement)) {
                        EmptyView()
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    UnlockRow()
                    RowDivider()
                    ActionRow(
                        symbol: "arrow.clockwise",
                        title: pro.isRestoring ? ProCopy.restoring : ProCopy.restore
                    ) {
                        restore(pro)
                    }
                    .disabled(pro.isRestoring)
                }
                RowDivider()
            }
        }
        .proGateHost()
        .task { await pro?.refreshIfNeeded() }
    }

    /// The outcome as a toast: the row it was asked from stays where it is.
    private func restore(_ pro: ProStore) {
        Task {
            switch await pro.restore() {
            case .restored:
                toasts?.show(ProCopy.unlocked, symbol: ProCopy.statusSymbolName, tint: .pd.accent)
            case .nothingToRestore:
                toasts?.show(ProCopy.nothingToRestore, symbol: "info.circle")
            case let .failed(failure):
                toasts?.show(failure.sentence, symbol: "exclamationmark.circle", tint: .pd.caution)
            case .cancelled:
                break
            }
        }
    }

    /// Inside the host, so its gate is the host's.
    private struct UnlockRow: View {
        @Environment(\.proGate) private var proGate

        var body: some View {
            NavRow(symbol: ProCopy.statusSymbolName, title: ProCopy.name, detail: ProCopy.rowState(.locked)) {
                proGate.offer()
            }
        }
    }
}

/// A switch that turns on a Pro feature: the "Pro" capsule beside its title
/// while Pro is off, and turning it on asks for Pro first.
///
/// `ToggleRow`, with the gate between the switch and the binding. Turning it
/// off is never gated. For someone without Pro the switch stays off while the
/// sheet is up and turns on once they have bought it.
struct ProToggleRow: View {
    @Environment(ProStore.self) private var pro: ProStore?

    let feature: ProFeature
    var symbol: String?
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        GatedSwitch(feature: feature, symbol: symbol, title: title, detail: detail, status: ProBadge.status(for: pro), isOn: $isOn)
            .proGateHost()
    }

    /// Inside the host, so its gate is the host's.
    private struct GatedSwitch: View {
        @Environment(\.proGate) private var proGate
        let feature: ProFeature
        let symbol: String?
        let title: String
        let detail: String?
        let status: (kind: StatusPill.Kind, text: String)?
        @Binding var isOn: Bool

        private var gated: Binding<Bool> {
            Binding(
                get: { isOn },
                set: { on in
                    if on {
                        proGate(feature) { isOn = true }
                    } else {
                        isOn = false
                    }
                }
            )
        }

        var body: some View {
            RowShell(symbol: symbol, title: title, detail: detail, status: status) {
                Toggle(title, isOn: gated)
                    .labelsHidden()
                    .tint(Color.pd.accent)
            }
            .accessibilityRepresentation {
                Toggle(title, isOn: gated)
                    .accessibilityHint([status == nil ? nil : ProCopy.badgeSpoken, detail].compactMap { $0 }.joined(separator: ". "))
            }
        }
    }
}

#Preview("Pro rows light") {
    ProRowsPreview()
}

#Preview("Pro rows dark") {
    ProRowsPreview().preferredColorScheme(.dark)
}

private struct ProRowsPreview: View {
    @State private var serving = false

    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.xl) {
                YouSection("Use from your laptop") {
                    ProToggleRow(
                        feature: .laptop,
                        symbol: "laptopcomputer",
                        title: "Allow other devices",
                        detail: "Off. Nothing else can reach this iPhone.",
                        isOn: $serving
                    )
                }
                YouSection("About") {
                    ProAboutRows()
                    LinkRow(symbol: "star", title: "Rate Pocketd") {}
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
        .environment(ProStore())
        .environment(ToastCenter())
    }
}
