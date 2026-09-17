import SwiftUI

/// A 3pt capsule that says how far through something you are.
///
/// Used twice: across the top of the onboarding run, and inside a download
/// card. The gradient is fixed across light and dark because progress is the
/// same event in both appearances — a stripe that changes colour with the
/// system theme reads as a different state rather than the same one at night.
struct ProgressStripe: View {
    /// 0...1. Clamped here rather than trusted, because the two callers are a
    /// step counter and a byte counter and both have been wrong before.
    var fraction: Double
    var height: CGFloat = 3
    /// An indeterminate stripe, for the moment between "started" and "the first
    /// byte arrived".
    var isIndeterminate: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pd.progressTrack)

                if isIndeterminate && !reduceMotion {
                    Capsule()
                        .fill(PDGradient.progress)
                        .frame(width: proxy.size.width * 0.35)
                        .offset(x: sweep * proxy.size.width)
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: 1.1).repeatForever(autoreverses: false)
                            ) {
                                sweep = 1
                            }
                        }
                } else {
                    Capsule()
                        .fill(PDGradient.progress)
                        .frame(width: max(0, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .animation(PDMotion.standard, value: clamped)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(isIndeterminate ? "Starting" : "\(Int(clamped * 100)) percent")
    }
}

#Preview("Progress stripe light") {
    ProgressStripePreview()
}

#Preview("Progress stripe dark") {
    ProgressStripePreview().preferredColorScheme(.dark)
}

private struct ProgressStripePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xl) {
            ProgressStripe(fraction: 0)
            ProgressStripe(fraction: 0.34)
            ProgressStripe(fraction: 1)
            ProgressStripe(fraction: 0, isIndeterminate: true)
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    SectionLabel("Downloading brain")
                    Text("1.1 GB · about 3 minutes on Wi-Fi")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                    ProgressStripe(fraction: 0.34)
                }
            }
        }
        .padding(PDSpacing.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .pdCanvas()
    }
}
