import PocketdKit
import SwiftUI

/// Pocketd Pro: what it opens, what it costs, and the way to buy it.
///
/// `PromoSheet`'s layout — icon tile, hero, three benefit rows, the button
/// pinned at the bottom — with what a purchase needs and a promise does not: a
/// price that arrives from the App Store, a button that waits while it does,
/// "Restore purchase", and one sentence when something went wrong. Never a
/// price written here: the button says what StoreKit's `displayPrice` says.
///
/// Presented by `ProGate` when somebody reaches for a Pro feature, and by the
/// Pocketd Pro row on You. `onUnlocked` runs once Pro is on, however it got
/// there — bought, restored, or approved by a parent while the sheet was open —
/// as the sheet closes; the presenter says thank you and carries on with what
/// the person was doing.
struct ProSheet: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var onUnlocked: () -> Void = {}

    /// The outcome of a restore, which the store does not keep.
    @State private var note: String?
    /// Set once, so a purchase that both returns and arrives through the
    /// listener closes the sheet once.
    @State private var finished = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.xl) {
                IconTile(symbol: ProCopy.symbolName)
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    Text(ProCopy.name)
                        .pdHero()
                        .foregroundStyle(Color.pd.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(ProCopy.tagline)
                        .pdSubtitle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: PDSpacing.l) {
                    ForEach(ProFeature.allCases) { feature in
                        benefitRow(feature)
                    }
                }
            }
            .padding(.horizontal, PDSpacing.heroGutter)
            .padding(.top, PDSpacing.xxl)
            .padding(.bottom, PDSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .pdCanvas()
        .presentationDragIndicator(.visible)
        // Apple's sheet is on top while this is true; a swipe here would only
        // orphan the purchase it is waiting for.
        .interactiveDismissDisabled(pro.purchase == .purchasing)
        .task {
            pro.clearFailure()
            await pro.refreshIfNeeded()
            await pro.loadOffer()
        }
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { finish() }
        }
        .onChange(of: statusLine) { _, line in
            // Appears beside the button, where VoiceOver's cursor is not.
            if let line { AccessibilityNotification.Announcement(line).post() }
        }
    }

    // MARK: - Rows

    private func benefitRow(_ feature: ProFeature) -> some View {
        HStack(alignment: .top, spacing: PDSpacing.m) {
            IconTile.small(feature.symbolName, fill: .pd.fillWarm, tint: .pd.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.detail)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Level with the 30pt tile when the title is one line.
            .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The pinned part

    private var actions: some View {
        VStack(spacing: PDSpacing.xxs) {
            if let line = statusLine {
                Primer(line, symbol: statusSymbol)
                    .padding(.bottom, PDSpacing.s)
                    .transition(.opacity)
            }
            PrimaryButton(
                title: buttonTitle,
                arrow: false,
                isLoading: isWorking,
                isEnabled: canBuy || isWorking,
                action: buy
            )
            secondaryLinks
            Text(ProCopy.footer)
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .animation(PDMotion.gentle, value: statusLine)
        .padding(.horizontal, PDSpacing.heroGutter)
        .padding(.top, PDSpacing.s)
        .padding(.bottom, PDSpacing.xs)
        .background(Color.pd.canvas.ignoresSafeArea(edges: .bottom))
    }

    /// "Restore purchase" and "Not now", side by side; one above the other
    /// once the words are too big to share a line.
    private var secondaryLinks: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: PDSpacing.xs))
        return layout {
            SecondaryLink(pro.isRestoring ? ProCopy.restoring : ProCopy.restore, action: restore)
                .disabled(pro.isRestoring || pro.purchase == .purchasing)
            SecondaryLink(ProCopy.notNow) { dismiss() }
        }
    }

    // MARK: - States

    private var buttonTitle: String {
        if case let .ready(price) = pro.offer {
            return ProCopy.unlockTitle(displayPrice: price)
        }
        return ProCopy.unlockTitle(displayPrice: nil)
    }

    /// Waiting for the price, or for Apple's sheet: a spinner in the button.
    private var isWorking: Bool {
        pro.offer == .loading || pro.purchase == .purchasing
    }

    private var canBuy: Bool {
        guard case .ready = pro.offer else { return false }
        return !pro.isRestoring
    }

    /// The one sentence above the button, when there is one.
    private var statusLine: String? {
        if let note { return note }
        switch pro.purchase {
        case .pending: return ProCopy.waitingForApproval
        case let .failed(failure): return failure.sentence
        case .idle, .purchasing: break
        }
        if pro.offer == .unavailable { return ProFailure.unavailable.sentence }
        return nil
    }

    private var statusSymbol: String {
        if note == nil, pro.purchase == .pending { return "clock" }
        return "exclamationmark.circle"
    }

    // MARK: - Actions

    private func buy() {
        note = nil
        Task {
            if await pro.buy() { finish() }
        }
    }

    private func restore() {
        note = nil
        Task {
            switch await pro.restore() {
            case .restored: finish()
            case .nothingToRestore: note = ProCopy.nothingToRestore
            case let .failed(failure): note = failure.sentence
            case .cancelled: break
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        Haptics.success()
        dismiss()
        onUnlocked()
    }
}

#Preview("Pro sheet light") {
    Color.pd.canvas
        .sheet(isPresented: .constant(true)) { ProSheet() }
        .environment(ProStore())
}

#Preview("Pro sheet dark") {
    Color.pd.canvas
        .sheet(isPresented: .constant(true)) { ProSheet() }
        .environment(ProStore())
        .preferredColorScheme(.dark)
}
