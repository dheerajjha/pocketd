import PocketdKit
import SwiftUI

/// Privacy, as promises: one line each, and every line opens its proof.
///
/// The full audit — every file, connection and permission, measured on this
/// phone — is one level down in `PrivacyDetailsView`. It used to be this page,
/// and it was thorough, honest and written for whoever wrote the code: Swift
/// file names, preference keys, CDN and Bonjour. Most people want the three
/// answers (who can see it, what leaves, what can I delete) and want to know
/// the proof exists; the curious can open it.
///
/// The hero says "personal". "Nothing leaves your phone" would be the cleaner
/// line, and two sections below it would say what does leave — brain downloads
/// and, while the switch is on, anonymous usage counts. A page whose argument
/// is that every sentence can be checked cannot open with one that fails.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var audit = StoredDataAudit()
    @State private var details: DetailsRequest?
    @State private var pending: Pending?

    /// Which part of the details page to open at. An item rather than a route
    /// because a promise opens the page *at its proof*, and `YouRoute` has no
    /// room for where to scroll.
    private struct DetailsRequest: Hashable {
        var focus: StoredDataAudit.Proof?
    }

    var body: some View {
        YouDetailScreen(title: "Privacy") {
            hero
            whoCanSeeIt
            whatLeaves
            whatYouCanDelete
            seeTheDetails
        }
        // Keyed on the history so the counts follow it: a page opened
        // straight from launch can measure before conversations load.
        .task(id: model.history.count) { await audit.refresh(model) }
        .navigationDestination(item: $details) { request in
            PrivacyDetailsView(focus: request.focus)
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                let chosen = action
                pending = nil
                Task { await perform(chosen) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(message(for: action))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            IconTile(symbol: "lock.shield")
                .accessibilityHidden(true)
            Text("Nothing personal leaves your phone.")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Pocketd thinks on this iPhone. Here's what that means.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, PDSpacing.xs)
    }

    // MARK: - Who can see it

    private var whoCanSeeIt: some View {
        YouSection("Who can see it") {
            ForEach(Array(StoredDataAudit.whoCanSeeIt.enumerated()), id: \.element.id) { index, promise in
                if index > 0 { RowDivider() }
                promiseRow(promise)
            }
        }
    }

    private func promiseRow(_ promise: StoredDataAudit.Promise) -> some View {
        NavRow(symbol: promise.symbol, title: promise.title, detail: promise.detail) {
            details = DetailsRequest(focus: promise.proof)
        }
        .accessibilityHint("Shows the proof")
    }

    // MARK: - What leaves the phone

    private var whatLeaves: some View {
        YouSection("What leaves the phone") {
            promiseRow(StoredDataAudit.brainDownloads)
            RowDivider()
            usageCountsSwitch
            TextLink("What a count holds") {
                details = DetailsRequest(focus: .usage)
            }
            .padding(.leading, PDMetric.iconTileSmall + PDSpacing.s)
            .padding(.bottom, PDSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The switch at the trailing edge, like every other switch row.
    ///
    /// `ToggleRow` lets a wide control drop under the words when the title
    /// would not fit beside it on one line — right for a menu or a value, and
    /// what put this switch under its three lines of text, alone on the left,
    /// at the default size. A switch is narrow enough to stay beside the words
    /// while they wrap; at the accessibility sizes it goes under them like
    /// every other row's does.
    private var usageCountsSwitch: some View {
        let isOn = Binding(
            get: { model.analyticsConsent.permitsSending },
            set: { model.setAnalyticsConsent($0 ? .granted : .refused) }
        )
        return RowShell(
            symbol: "chart.bar",
            title: "Share anonymous usage counts",
            detail: StoredDataAudit.usageCountsDetail,
            trailingPlacement: typeSize.isAccessibilitySize ? .adaptive : .pinned
        ) {
            Toggle("Share anonymous usage counts", isOn: isOn)
                .labelsHidden()
                .tint(Color.pd.accent)
        }
        .accessibilityRepresentation {
            Toggle("Share anonymous usage counts", isOn: isOn)
                .accessibilityHint(StoredDataAudit.usageCountsDetail)
        }
    }

    // MARK: - What you can delete

    private var whatYouCanDelete: some View {
        let conversations = audit.conversations
        let plan = audit.deletionPlan(model)
        let measuring = audit.survey == nil

        return YouSection("What you can delete") {
            if measuring {
                RowShell(symbol: "trash", title: "Conversations", detail: "Counting…") { EmptyView() }
            } else if conversations.fileCount + conversations.remnantCount > 0 {
                ActionRow(
                    symbol: "trash",
                    title: "Delete conversations",
                    // Files this build cannot open are still conversations
                    // somebody had, so they are counted by size rather than
                    // reported as "0 conversations" beside a non-zero size.
                    detail: conversations.readableCount > 0
                        ? "\(Format.counted(conversations.readableCount, "conversation")) · \(pdBytes(conversations.byteCount))"
                        : "\(pdBytes(conversations.byteCount)) of conversation files",
                    isDestructive: true
                ) {
                    pending = .conversations
                }
            } else {
                RowShell(symbol: "trash", title: "Conversations", detail: "None on this iPhone") { EmptyView() }
            }
            RowDivider()
            if measuring {
                RowShell(symbol: "trash", title: "Everything Pocketd stores", detail: "Counting…") { EmptyView() }
            } else if !plan.isEmpty {
                ActionRow(
                    symbol: "trash",
                    title: "Delete everything Pocketd stores",
                    detail: "\(pdBytes(plan.byteCount)) on this iPhone",
                    isDestructive: true
                ) {
                    pending = .everything
                }
            } else {
                RowShell(symbol: "trash", title: "Everything Pocketd stores", detail: "Nothing left to delete") { EmptyView() }
            }
            if let freed = audit.lastFreed {
                Text("\(freed) freed.")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.positive)
                    .padding(.leading, PDMetric.iconTileSmall + PDSpacing.s)
                    .padding(.bottom, PDSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - The details

    private var seeTheDetails: some View {
        PDCard(padding: PDSpacing.m) {
            NavRow(
                symbol: "doc.text.magnifyingglass",
                title: "See the details",
                detail: "Every file, connection and permission, measured on this iPhone"
            ) {
                details = DetailsRequest(focus: nil)
            }
        }
    }

    // MARK: - Confirmation

    private enum Pending: Identifiable, Equatable {
        case conversations
        case everything

        var id: Self { self }

        var title: String {
            switch self {
            case .conversations: "Delete every conversation?"
            case .everything: "Delete everything Pocketd stores?"
            }
        }

        var confirmTitle: String { "Delete" }
    }

    private func message(for action: Pending) -> String {
        switch action {
        case .conversations:
            let summary = audit.conversations
            let what = summary.readableCount > 0
                ? "\(Format.counted(summary.readableCount, "conversation")), \(pdBytes(summary.byteCount))."
                : "\(pdBytes(summary.byteCount)) of conversation files."
            return "\(what) Nothing was ever uploaded, so there is no copy anywhere to bring back."
        case .everything:
            var sentences = DeletionNarrative.confirmation(plan: audit.deletionPlan(model))
            // Said only when it is true: a phone that answers with the
            // built-in brain loses nothing it needs to answer.
            if audit.deletionPlan(model).included.contains(where: { $0.name == DeletionPlan.EntryName.models }),
               !model.isUsingBuiltInBrain {
                sentences.insert("Pocketd will need a brain again before it can answer.", at: 1)
            }
            return sentences.joined(separator: " ")
        }
    }

    private func perform(_ action: Pending) async {
        switch action {
        case .conversations: await audit.deleteAllConversations(model)
        case .everything: await audit.deleteEverythingDeletable(model)
        }
        if let freed = audit.lastFreed {
            toasts.show("\(freed) freed", symbol: "trash")
        }
    }
}

// MARK: - Previews

#Preview("Privacy light") {
    NavigationStack { PrivacyView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Privacy dark") {
    NavigationStack { PrivacyView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
