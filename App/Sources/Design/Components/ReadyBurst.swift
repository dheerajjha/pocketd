import SwiftUI

/// The moment something worked.
///
/// A symbol that draws itself in, a ring that expands once, and a success
/// haptic. It is used exactly where the app has earned it — the brain finished
/// loading, the reminder was set, onboarding is done — and nowhere else. A
/// celebration for something routine is how an app stops being believed.
///
/// The haptic fires once per appearance, guarded by state rather than by the
/// caller, because this view is usually inside a card that SwiftUI is free to
/// re-evaluate several times.
struct ReadyBurst: View {
    var symbol: String = "checkmark"
    var size: CGFloat = 64
    var tint: Color = .pd.positive
    var fill: Color = .pd.positiveSoft
    /// What VoiceOver announces when it lands.
    var announcement: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0.55

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(ringOpacity), lineWidth: 2)
                .scaleEffect(ringScale)
                .frame(width: size, height: size)

            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .scaleEffect(landed || reduceMotion ? 1 : 0.7)
                .opacity(landed || reduceMotion ? 1 : 0)
                // `.bounce` draws the glyph in on appearance. Available since
                // iOS 17 and purely additive: a device that cannot play it
                // still sees the scale above.
                .symbolEffect(.bounce, value: landed)
        }
        .onAppear(perform: land)
        .accessibilityElement()
        .accessibilityLabel(announcement ?? "Done")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func land() {
        guard !landed else { return }
        Haptics.success()
        if reduceMotion {
            landed = true
            ringOpacity = 0
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) {
            landed = true
        }
        withAnimation(.easeOut(duration: 0.65)) {
            ringScale = 1.35
            ringOpacity = 0
        }
    }
}

#Preview("Ready burst light") {
    ReadyBurstPreview()
}

#Preview("Ready burst dark") {
    ReadyBurstPreview().preferredColorScheme(.dark)
}

private struct ReadyBurstPreview: View {
    @State private var generation = 0

    var body: some View {
        VStack(spacing: PDSpacing.xxl) {
            ReadyBurst(announcement: "You're all set")
                .id(generation)
            ReadyBurst(symbol: "bell", size: 44, tint: .pd.accent, fill: .pd.accentSoft)
                .id(generation)
            PrimaryButton(title: "Again", arrow: false) { generation += 1 }
        }
        .padding(PDSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pdCanvas()
    }
}
