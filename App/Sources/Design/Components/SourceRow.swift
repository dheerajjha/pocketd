import SwiftUI

/// Calendar · Reminders · Health: a source Pocketd can read, and whether it
/// can.
///
/// A symbol, a title, one grey line saying what Pocketd does with it, and on
/// the end exactly one of three things:
///
/// - `.connect` — a small Connect pill (onboarding). A row, not a card with a
///   full-width button, so the screen's own Continue stays the one button.
/// - `.toggle` — a switch (You › What Pocketd can see). Its binding's setter is
///   the connect door: turning it on is what raises the iOS sheet.
/// - `.status` — a word ("On", "Off in iOS Settings"), with `action` for the
///   row tap that fixes it (opening Settings).
///
/// The title and the accessory share a line only while the title fits on it
/// whole (`AccessoryRowLayout`); otherwise the accessory drops under the text.
/// No size, word or language breaks "Reminders" into "Remind / ers".
struct SourceRow: View {
    enum Accessory {
        /// A small pill. "Connect" unless told otherwise.
        case connect(title: String = "Connect", action: () -> Void)
        /// A switch.
        case toggle(Binding<Bool>)
        /// A word. `isOn` puts a ✓ before it in green; otherwise it is grey.
        case status(String, isOn: Bool)
    }

    let symbol: String
    let title: String
    let detail: String
    let accessory: Accessory
    /// For a `.status` row: the tap that changes it — opening Settings. A
    /// chevron says the row goes somewhere.
    var action: (() -> Void)?
    /// The onboarding canvas's warm pair of greys and tiles.
    var warm: Bool = false

    var body: some View {
        if case .status = accessory, let action {
            Button {
                Haptics.tap()
                action()
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(PDPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: PDSpacing.s) {
            IconTile.small(
                symbol,
                fill: warm ? .pd.fillWarm : .pd.accentSoft,
                tint: warm ? .pd.ink : .pd.accent
            )
            // Centred on the title's first line rather than the whole block.
            .padding(.top, 1)

            AccessoryRowLayout(spacing: PDSpacing.s) {
                Text(title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .accessibilityHidden(isToggle)
                Text(detail)
                    .font(Font.pd.secondary)
                    .foregroundStyle(warm ? Color.pd.inkSecondaryWarm : Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(isToggle)
                accessoryView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: isToggle ? .contain : .combine)
    }

    private var isToggle: Bool {
        if case .toggle = accessory { return true }
        return false
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case let .connect(title, action):
            Button {
                Haptics.tap()
                action()
            } label: {
                Text(title)
                    .font(Font.pd.secondary.weight(.semibold))
                    .foregroundStyle(Color.pd.ink)
                    .padding(.horizontal, PDSpacing.m)
                    .padding(.vertical, PDSpacing.xxs)
                    .frame(minHeight: PDMetric.linkPillHeight + PDSpacing.xs)
                    .background(warm ? Color.pd.cardWarm : Color.pd.fillPill, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(warm ? Color.pd.cardStrokeWarm : Color.pd.cardStroke, lineWidth: 1)
                    )
                    .pdHitTarget()
            }
            .buttonStyle(PDPressStyle())
            .accessibilityLabel("\(title) \(self.title)")

        case let .toggle(isOn):
            // The row's words are the switch's label, so VoiceOver reads
            // "Calendar, switch, off — Reads and adds events" as one control.
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(Color.pd.accent)
                .accessibilityLabel(title)
                .accessibilityHint(detail)

        case let .status(text, isOn):
            HStack(spacing: PDSpacing.xxs) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(Font.pd.tick)
                }
                Text(text)
                    .font(Font.pd.secondary.weight(.medium))
                    // Inline it is one line; it only wraps once it has moved
                    // under the text, where it reads from the leading edge.
                    .multilineTextAlignment(.leading)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(Font.pd.chevron)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .padding(.leading, PDSpacing.xxs)
                }
            }
            .foregroundStyle(isOn ? Color.pd.positive : (warm ? Color.pd.inkSecondaryWarm : Color.pd.inkSecondary))
        }
    }
}

#Preview("Source rows light") {
    SourceRowPreview()
}

#Preview("Source rows dark") {
    SourceRowPreview().preferredColorScheme(.dark)
}

#Preview("Source rows AX") {
    SourceRowPreview().dynamicTypeSize(.accessibility3)
}

private struct SourceRowPreview: View {
    @State private var calendar = true
    @State private var reminders = false

    var body: some View {
        ScrollView {
            VStack(spacing: PDSpacing.cardGap) {
                PDCard(warm: true) {
                    VStack(alignment: .leading, spacing: PDSpacing.m) {
                        SourceRow(
                            symbol: "calendar", title: "Calendar",
                            detail: "Reads and adds events",
                            accessory: .connect {}, warm: true
                        )
                        Primer("Next, tap **Allow Full Access** so Pocketd can read your calendar.", warm: true)
                    }
                }
                PDCard {
                    VStack(alignment: .leading, spacing: PDSpacing.m) {
                        SourceRow(
                            symbol: "calendar", title: "Calendar",
                            detail: "Reads and adds events",
                            accessory: .toggle($calendar)
                        )
                        SourceRow(
                            symbol: "checklist", title: "Reminders",
                            detail: "Reads, adds and ticks off reminders",
                            accessory: .toggle($reminders)
                        )
                        SourceRow(
                            symbol: "heart", title: "Health",
                            detail: "Reads sleep and steps",
                            accessory: .status("Off in iOS Settings", isOn: false)
                        ) {}
                    }
                }
            }
            .padding(PDSpacing.gutter)
        }
        .pdCanvas()
    }
}
