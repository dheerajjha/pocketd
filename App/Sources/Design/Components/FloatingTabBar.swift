import SwiftUI

/// The four tabs, in a capsule that floats over the page.
///
/// Not a `TabView`. The system bar is 83pt of opaque chrome that ends every
/// screen with a hard line, and this app's screens are meant to run off the
/// bottom of the phone — content scrolls *under* this capsule, which is what
/// the 96pt bottom inset on every tab is for.
///
/// No labels. Four icons at 358×53 with a capsule behind the selected one is
/// the whole control; the labels are in the accessibility layer, where a
/// person who needs them is actually served rather than being given 9pt text.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(.horizontal, PDSpacing.xs)
        .frame(height: PDMetric.tabBarHeight)
        .frame(maxWidth: PDMetric.tabBarMaxWidth)
        .background(Color.pd.fillFloat, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
        .pdFloatShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func item(_ tab: AppTab) -> some View {
        Button {
            guard selection != tab else { return }
            Haptics.tabChanged()
            if reduceMotion {
                selection = tab
            } else {
                withAnimation(PDMotion.standard) { selection = tab }
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(selection == tab ? Color.pd.ink : Color.pd.inkSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: PDMetric.tabBarSelectionHeight)
                .background {
                    if selection == tab {
                        Capsule(style: .continuous)
                            .fill(Color.pd.card)
                            .frame(width: PDMetric.tabBarSelectionWidth)
                            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
                            // Matched so the capsule slides between tabs
                            // rather than blinking out and back in.
                            .matchedGeometryEffect(id: "pd.tab.selection", in: indicator)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Tab bar light") {
    FloatingTabBarPreview()
}

#Preview("Tab bar dark") {
    FloatingTabBarPreview().preferredColorScheme(.dark)
}

private struct FloatingTabBarPreview: View {
    @State private var tab: AppTab = .today

    var body: some View {
        VStack {
            Spacer()
            Text("Content runs under the bar.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
            Spacer()
            FloatingTabBar(selection: $tab)
                .padding(.horizontal, PDMetric.tabBarSideMargin)
                .padding(.bottom, PDMetric.tabBarBottomInset)
        }
        .pdCanvas()
    }
}
