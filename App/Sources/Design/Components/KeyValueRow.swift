import SwiftUI

/// A label on the left, a value on the right, in mono.
///
/// The value is monospaced and right-aligned because a column of these is
/// almost always a column of numbers or addresses, and the whole reason to put
/// them in a column is so they can be compared. Proportional digits make that
/// impossible.
struct KeyValueRow: View {
    let title: String
    var subtitle: String?
    let value: String
    var tint: Color = .pd.ink
    /// A chevron and a tap target, for a row that goes somewhere.
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button {
                Haptics.tap()
                action()
            } label: { row }
                .buttonStyle(PDPressStyle())
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PDSpacing.s)
            Text(value)
                .font(Font.pd.monoValue)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.pd.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(value)")
    }
}

#Preview("Key value row light") {
    KeyValueRowPreview()
}

#Preview("Key value row dark") {
    KeyValueRowPreview().preferredColorScheme(.dark)
}

private struct KeyValueRowPreview: View {
    var body: some View {
        PDCard {
            VStack(spacing: PDSpacing.m) {
                KeyValueRow(title: "Address", value: "192.168.1.42:11434")
                Divider().background(Color.pd.divider)
                KeyValueRow(
                    title: "Pairing code",
                    subtitle: "Type this on the laptop",
                    value: "4821",
                    tint: .pd.accent
                )
                Divider().background(Color.pd.divider)
                KeyValueRow(title: "Version", value: "1.0.0")
                Divider().background(Color.pd.divider)
                KeyValueRow(title: "Recent requests", value: "14") {}
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .pdCanvas()
    }
}
