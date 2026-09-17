import PocketdKit
import SwiftUI
import UIKit

/// Everything this app holds, everything it sends, and a way to remove each of
/// them.
///
/// Competitors promise a screen like this in onboarding and never ship it.
/// Building it is nearly free here and the promise is true here, which is the
/// whole argument — so the screen is written as an argument: quiet, specific,
/// numbers anybody can go and check, and a plain statement wherever the answer
/// is "this cannot be deleted from here" rather than a category left out.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var audit = StoredDataAudit()
    @State private var pending: Pending?
    @State private var showAPIKey = false
    @State private var awkwardExpanded = false

    var body: some View {
        YouDetailScreen(
            title: "What leaves this phone",
            subtitle: "Counted by walking this app's own folder on this device, not by asking the app what it thinks it saved. Pull down to measure again."
        ) {
            summary
            leaves
            brains
            conversations
            partialDownloads
            keysAndSettings
            permissions
            networkCache
            systemOwned
            unnamed
            deleteEverything
        }
        .task { await audit.refresh(model) }
        .refreshable { await audit.refresh(model) }
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

    /// Whether the walk has landed.
    ///
    /// Every section renders its own empty state, and until this is false that
    /// empty state is a falsehood: the first frame of this screen said "No
    /// brains downloaded", "Nothing left over" and "Nothing cached" on a phone
    /// holding 4.63 GB across 37 files.
    private var isMeasuring: Bool { audit.survey == nil }

    // MARK: - The total

    private var summary: some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            SectionLabel("ON THIS IPHONE")
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    if let survey = audit.survey {
                        Text(pdBytes(survey.totalBytes))
                            .font(Font.pd.statValue)
                            .foregroundStyle(Color.pd.ink)
                        Text("\(survey.totalFiles) files, all inside this app's own folder.")
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                        if !survey.unreadablePaths.isEmpty {
                            // A count from a walk that could not finish is a
                            // count that is too small, which on this screen is
                            // the only kind of wrong that matters.
                            Text("\(survey.unreadablePaths.count) folders could not be read, so the number above is a floor rather than a figure.")
                                .font(Font.pd.footnote)
                                .foregroundStyle(Color.pd.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: PDSpacing.xs) {
                            ShimmerLine(widthFraction: 0.45, height: 26)
                            ShimmerLine(widthFraction: 0.7)
                        }
                    }
                    if let freed = audit.lastFreed {
                        Text("\(freed) freed.")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.positive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - What leaves

    private var leaves: some View {
        YouSection(
            "WHAT LEAVES THIS DEVICE",
            footnote: "Three connections. Two are about brain files; the third carries usage counts. This list comes from reading every network call in the source — and the third cannot be found that way, because those requests are made inside a dependency rather than by code in this repository. It is the one claim on this screen you cannot check from the phone itself."
        ) {
            ForEach(Array(audit.destinations.enumerated()), id: \.element.id) { index, destination in
                if index > 0 { RowDivider(inset: 0) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: PDSpacing.xs) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.pd.accent)
                        Text(destination.host)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                    }
                    Text(destination.sends)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(destination.when)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, PDSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            RowDivider(inset: 0)

            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                ForEach(audit.assurances, id: \.self) { line in
                    HStack(alignment: .top, spacing: PDSpacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.pd.positive)
                            .padding(.top, 3)
                        Text(line)
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, PDSpacing.s)

            RowDivider(inset: 0)

            RowDisclosure(
                title: "The awkward parts",
                detail: "The corners a privacy page usually leaves out",
                isExpanded: $awkwardExpanded
            ) {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    ForEach(audit.caveats, id: \.self) { line in
                        Text(line)
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Brains

    private var brains: some View {
        YouSection(
            StoredDataKind.models.title,
            footnote: StoredDataKind.models.detail + " Sizes are read from the files themselves, so one that downloaded short shows what actually arrived."
        ) {
            if isMeasuring {
                measuring
            } else if audit.models.isEmpty, audit.orphanedModelFiles.isEmpty {
                empty("Nothing downloaded.")
            }
            ForEach(Array(audit.models.enumerated()), id: \.element.id) { index, row in
                if index > 0 { RowDivider(inset: 0) }
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                        Text(row.record.displayName)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                        if row.isLoaded { LoadedDot(label: "In memory now") }
                        Spacer(minLength: PDSpacing.xs)
                        Text(pdBytes(row.totalBytes))
                            .font(Font.pd.monoValue)
                            .foregroundStyle(Color.pd.ink)
                    }
                    if row.projectorBytes > 0 {
                        Text("\(pdBytes(row.weightsBytes)) of weights and \(pdBytes(row.projectorBytes)) of image part.")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                    }
                    if row.isMissing {
                        Text("Listed as installed, and its file is not on disk.")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.caution)
                    }
                    deleteLink("Delete", label: "Delete \(row.record.displayName), \(pdBytes(row.totalBytes))") {
                        pending = .model(row.record)
                    }
                }
                .padding(.vertical, PDSpacing.s)
            }
            ForEach(audit.orphanedModelFiles) { orphan in
                // Live download state, not the state of the last walk, and from
                // both doors rather than from this app's own map: the screen can
                // sit open while a download starts — including one a paired
                // laptop started — and the file this row offers to delete is
                // then the finished half of it.
                let abandoned = orphan.isStillAbandoned(downloadingIDs: audit.downloadingIDs(model))
                RowDivider(inset: 0)
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: PDSpacing.xs) {
                        Text(breakableIdentifier(orphan.file.name))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.pd.inkSecondary)
                        Spacer(minLength: PDSpacing.xs)
                        Text(pdBytes(orphan.file.byteCount))
                            .font(Font.pd.monoValue)
                            .foregroundStyle(Color.pd.ink)
                    }
                    Text(orphan.explanation)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    if !abandoned {
                        Text("A download for this one is running, so the file is not stranded after all. It is left alone until that finishes or is cancelled.")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        deleteLink("Delete", label: "Delete this stranded file") {
                            pending = .orphan(orphan)
                        }
                    }
                }
                .padding(.vertical, PDSpacing.s)
            }
        }
    }

    // MARK: - Conversations

    private var conversations: some View {
        let summary = audit.conversations

        return YouSection(
            StoredDataKind.conversations.title,
            footnote: StoredDataKind.conversations.detail + " Not encrypted beyond what iOS does for every file on a locked device, and never sent anywhere."
        ) {
            if isMeasuring {
                measuring
            } else {
                ValueRow(title: "Conversations", value: "\(summary.readableCount)")
                RowDivider(inset: 0)
                ValueRow(title: "Messages", value: "\(summary.messageCount)")
                RowDivider(inset: 0)
                ValueRow(title: "Size", value: pdBytes(summary.byteCount))
                if let oldest = summary.oldest, let newest = summary.newest {
                    RowDivider(inset: 0)
                    ValueRow(
                        title: "From",
                        value: oldest.formatted(date: .abbreviated, time: .omitted)
                    )
                    RowDivider(inset: 0)
                    ValueRow(
                        title: "To",
                        value: newest.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if summary.unreadableCount > 0 {
                    // These are the ones a naive delete leaves behind, so they
                    // are named before the button rather than after it.
                    note("\(summary.unreadableCount) transcripts on disk cannot be opened by this build and do not appear in your history. They are still text you typed, and Delete below removes them too.", tint: .pd.caution)
                }
                if summary.remnantCount > 0 {
                    // The size above counts these, so the screen says what they
                    // are rather than letting the number be larger than the
                    // conversation count explains.
                    note("\(summary.remnantCount) files here — \(pdBytes(summary.remnantBytes)) — are not transcripts. Saving writes each conversation to a temporary file first, and a process killed mid-write leaves one behind. They are in the size above and Delete removes them.", tint: .pd.inkSecondary)
                }
                DangerButton(
                    title: "Delete every conversation",
                    symbol: "trash",
                    isEnabled: summary.fileCount > 0 || summary.remnantCount > 0
                ) {
                    pending = .allConversations
                }
                .padding(.top, PDSpacing.xs)
            }
        }
    }

    // MARK: - Unfinished downloads

    private var partialDownloads: some View {
        let area = audit.survey?.area(.partialDownloads) ?? StoredDataArea(kind: .partialDownloads)
        let downloading = audit.downloadingIDs(model)

        return YouSection(
            StoredDataKind.partialDownloads.title,
            footnote: StoredDataKind.partialDownloads.detail + " Cancelling a download in Brain keeps these on purpose, so the next attempt resumes instead of starting again."
        ) {
            if isMeasuring {
                measuring
            } else if area.tally.isEmpty {
                empty("Nothing left over.")
            } else {
                ValueRow(title: "Left on disk", value: pdBytes(area.tally.byteCount))
                // The paths are here because the surprising one — a half-
                // downloaded brain parked in `tmp` by the system — is not
                // somewhere a person would think to look, and naming it is most
                // of the point of reporting it.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(area.files.prefix(6)) { file in
                        Text(breakableIdentifier(file.path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.pd.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if area.files.count > 6 {
                        Text("and \(area.files.count - 6) more, all of which Delete removes")
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkTertiary)
                    }
                }
                .padding(.bottom, PDSpacing.xs)
                if !downloading.isEmpty {
                    note("A download is running. One of the files above belongs to it.", tint: .pd.inkSecondary)
                }
                DangerButton(
                    title: "Delete unfinished downloads",
                    symbol: "trash",
                    isEnabled: downloading.isEmpty
                ) {
                    pending = .partialDownloads
                }
            }
        }
    }

    // MARK: - Settings and keys

    private var keysAndSettings: some View {
        YouSection(
            StoredDataKind.preferences.title,
            footnote: "Every key in this app's preferences file, listed as it is stored — the app's own first, anything iOS wrote after. \(pdBytes(audit.survey?.area(.preferences).tally.byteCount ?? 0)) in all. \(StoredDataKind.preferences.disposal.limitation ?? "")"
        ) {
            if model.configuration.requiresAuth {
                apiKeyRow
                NavRow(symbol: "doc.on.doc", title: "Copy the key", detail: nil) {
                    UIPasteboard.general.string = model.configuration.apiKey
                    toasts.show("Key copied")
                }
                RowDivider()
                deleteLink("Replace the key", label: "Replace the API key") { pending = .apiKey }
                    .padding(.vertical, PDSpacing.s)
            } else {
                note("No key is required, so anything on your network can use the brain on this phone.", tint: .pd.caution)
            }

            RowDivider(inset: 0)

            // A stack rather than a value row, because a preferences key is
            // long and its summary is a sentence: putting them on one line
            // means one of the two gets truncated on every device.
            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                ForEach(audit.defaults) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(breakableIdentifier(row.key))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(row.isSystem ? Color.pd.inkTertiary : Color.pd.ink)
                        Text(row.summary)
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, PDSpacing.s)
        }
    }

    /// The key, readable at every text size.
    ///
    /// `Show` is the only control on this screen whose whole function is to
    /// reveal a string, and in a fixed single-line row at `.accessibility3` it
    /// revealed six characters of a thirty-five character key — fewer than the
    /// nine the redaction it replaced was already showing. Stacking when the
    /// type is large, and wrapping rather than truncating while shown, are what
    /// make the control do its job.
    @ViewBuilder
    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack {
                Text("API key")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: PDSpacing.xs)
                Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                    .font(Font.pd.secondary.weight(.semibold))
                    .foregroundStyle(Color.pd.accent)
                    .accessibilityHint("Reveals the key other devices use to reach this phone")
            }
            if showAPIKey {
                MonoBlock(text: breakableIdentifier(model.configuration.apiKey))
            } else {
                Text(redactedSecret(model.configuration.apiKey))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .padding(.vertical, PDSpacing.s)
    }

    // MARK: - Permissions

    private var permissions: some View {
        YouSection(
            "PERMISSIONS",
            footnote: "Taken from what this app declares in its own bundle, so a permission added to Pocketd appears here whether or not anyone remembered to update this screen. The calendar and reminder switches live under Privacy & Security, per app; iOS does not let an app link you straight to them."
        ) {
            ForEach(Array(audit.permissions.enumerated()), id: \.element.id) { index, row in
                if index > 0 { RowDivider(inset: 0) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                        Spacer(minLength: PDSpacing.xs)
                        Text(row.state.label)
                            .font(Font.pd.footnote)
                            .foregroundStyle(row.state.isConcern ? Color.pd.caution : Color.pd.inkSecondary)
                    }
                    if let note = row.note {
                        Text(note)
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, PDSpacing.s)
                .accessibilityElement(children: .combine)
                // Combining derives a label from the children and this override
                // replaces it outright, so the sentence that makes each row
                // honest — including the one saying iOS never reports whether a
                // Health read was allowed — had no route out to VoiceOver.
                .accessibilityLabel(permissionAnnouncement(
                    title: row.title,
                    state: row.state.label,
                    note: row.note
                ))
            }
            RowDivider(inset: 0)
            LinkRow(symbol: "gear", title: "Open iOS Settings", detail: nil) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    // MARK: - What cannot be deleted from here

    /// The cache is separate from the shader cache on purpose: one is a record
    /// of what somebody looked for and the other is compiled GPU code, and only
    /// one of them is worth a delete button.
    private var networkCache: some View {
        let area = audit.survey?.area(.networkCache) ?? StoredDataArea(kind: .networkCache)

        return YouSection(
            StoredDataKind.networkCache.title,
            footnote: StoredDataKind.networkCache.detail + " Searching from this phone leaves nothing here; the searches a paired laptop asks this phone to run do, and that is a difference worth knowing about."
        ) {
            if isMeasuring {
                measuring
            } else if area.tally.isEmpty {
                empty("Nothing cached.")
            } else {
                ValueRow(title: "Kept by the system", value: pdBytes(area.tally.byteCount))
                DangerButton(title: "Clear the network cache", symbol: "trash") {
                    pending = .networkCache
                }
                .padding(.top, PDSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var systemOwned: some View {
        if !audit.systemOwnedAreas.isEmpty {
            YouSection(
                "HELD BY IOS, NOT BY POCKETD",
                footnote: "Listed rather than hidden. A privacy screen that shows only the parts with a delete button beside them is describing its own buttons, not your device."
            ) {
                ForEach(Array(audit.systemOwnedAreas.enumerated()), id: \.element.id) { index, area in
                    if index > 0 { RowDivider(inset: 0) }
                    areaRow(area)
                }
            }
        }
    }

    /// Separate from the section above it, and the separation is the fix.
    ///
    /// These bytes were being shown under "Held by iOS" and named in the
    /// delete-everything dialog as something "nothing inside this app can"
    /// remove. Neither is true — this is Pocketd's own container — and because
    /// every iOS container has a metadata plist at its root, the false sentence
    /// rendered on every device.
    @ViewBuilder
    private var unnamed: some View {
        if !audit.unnamedAreas.isEmpty {
            YouSection(
                "IN POCKETD'S FOLDER, UNNAMED BY THIS SCREEN",
                footnote: "Counted in the total at the top and listed by path, so the number up there is not missing them. Every button on this screen leaves them alone: sweeping up whatever it could not identify is exactly the promise this screen exists to disprove."
            ) {
                ForEach(Array(audit.unnamedAreas.enumerated()), id: \.element.id) { index, area in
                    if index > 0 { RowDivider(inset: 0) }
                    areaRow(area)
                }
            }
        }
    }

    private func areaRow(_ area: StoredDataArea) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(area.kind.title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: PDSpacing.xs)
                Text(pdBytes(area.tally.byteCount))
                    .font(Font.pd.monoValue)
                    .foregroundStyle(Color.pd.ink)
            }
            Text(area.kind.detail)
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let limitation = area.kind.disposal.limitation {
                Text(limitation)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if area.kind == .other {
                ForEach(area.files) { file in
                    Text(breakableIdentifier(file.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.pd.inkTertiary)
                }
                if area.unlistedFileCount > 0 {
                    Text("and \(area.unlistedFileCount) more")
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkTertiary)
                }
            }
        }
        .padding(.vertical, PDSpacing.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Delete everything

    private var deleteEverything: some View {
        YouSection("DELETE EVERYTHING", footnote: everythingFooter) {
            DangerButton(
                title: "Delete everything Pocketd can delete",
                symbol: "trash",
                isEnabled: !audit.deletionPlan(model).isEmpty
            ) {
                pending = .everything
            }
            .padding(.vertical, PDSpacing.xs)
        }
    }

    /// The confirmation dialog's body and the footnote are the same string on
    /// purpose, and both are built from the plan the delete itself uses. The
    /// sentences are assembled in `DeletionNarrative` rather than here, so the
    /// promise this control makes is somewhere a test can read it.
    private var everythingFooter: String {
        DeletionNarrative.sentences(
            plan: audit.deletionPlan(model),
            measured: !isMeasuring,
            systemOwnedTitles: audit.systemOwnedAreas.map(\.kind.title),
            preferencesBytes: audit.survey?.area(.preferences).tally.byteCount ?? 0,
            unnamedTitles: audit.unnamedAreas.map(\.kind.title),
            unnamedBytes: audit.unnamedAreas.reduce(0) { $0 + $1.tally.byteCount }
        )
        .joined(separator: " ")
    }

    // MARK: - Small pieces

    private var measuring: some View {
        HStack(spacing: PDSpacing.xs) {
            ProgressView().controlSize(.small)
            Text("Still counting.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Font.pd.secondary)
            .foregroundStyle(Color.pd.inkSecondary)
            .padding(.vertical, PDSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Font.pd.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, PDSpacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteLink(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.warning()
            action()
        } label: {
            Text(title)
                .font(Font.pd.secondary.weight(.semibold))
                .foregroundStyle(Color.pd.danger)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
    }

    // MARK: - Confirmation

    private enum Pending: Identifiable, Equatable {
        case allConversations
        case partialDownloads
        case networkCache
        case apiKey
        case model(ModelRecord)
        case orphan(StoredDataAudit.OrphanRow)
        case everything

        var id: String {
            switch self {
            case .allConversations: "conversations"
            case .partialDownloads: "partial"
            case .networkCache: "cache"
            case .apiKey: "key"
            case let .model(record): "model-\(record.id)"
            case let .orphan(row): "orphan-\(row.id)"
            case .everything: "everything"
            }
        }

        var title: String {
            switch self {
            case .allConversations: "Delete every conversation?"
            case .partialDownloads: "Delete unfinished downloads?"
            case .networkCache: "Clear the network cache?"
            case .apiKey: "Replace the API key?"
            case let .model(record): "Delete \(record.displayName)?"
            case .orphan: "Delete this file?"
            case .everything: "Delete everything?"
            }
        }

        var confirmTitle: String {
            switch self {
            case .networkCache: "Clear"
            case .apiKey: "Replace"
            default: "Delete"
            }
        }
    }

    /// What is lost, in the terms it will be lost in.
    ///
    /// Each of these names the thing and then says what cannot be recovered,
    /// because on this screen the second half is the point: there is no copy on
    /// a server to restore from, and that is the same fact the rest of the
    /// screen is selling.
    private func message(for action: Pending) -> String {
        switch action {
        case .allConversations:
            let summary = audit.conversations
            var text = "\(summary.readableCount) conversations, \(summary.messageCount) messages, \(pdBytes(summary.byteCount))."
            if summary.remnantCount > 0 {
                text += " That includes \(summary.remnantCount) leftover files from interrupted saves, which go too."
            }
            return text + " Every question you asked and every answer you got. Nothing was ever uploaded, so there is no copy anywhere to restore from."
        case .partialDownloads:
            let area = audit.survey?.area(.partialDownloads) ?? StoredDataArea(kind: .partialDownloads)
            return "Frees \(pdBytes(area.tally.byteCount)). Any download you paused starts again from zero next time instead of resuming."
        case .networkCache:
            let area = audit.survey?.area(.networkCache) ?? StoredDataArea(kind: .networkCache)
            return "Discards \(pdBytes(area.tally.byteCount)) of cached responses and cookies. iOS manages these files, so the number above may not drop all the way to zero straight away."
        case .apiKey:
            return "Every device already paired stops working and has to pair again. The old key cannot be recovered."
        case let .model(record):
            let row = audit.models.first { $0.id == record.id }
            let size = pdBytes(row?.totalBytes ?? record.totalDownloadBytes)
            return model.loadedModelID == record.id
                ? "\(record.displayName) is in memory right now. Deleting it unloads it and frees \(size), which has to be downloaded again to use it."
                : "Frees \(size). It has to be downloaded again to use it."
        case let .orphan(row):
            return "Frees \(pdBytes(row.file.byteCount)). \(row.explanation)"
        case .everything:
            return everythingFooter
        }
    }

    private func perform(_ action: Pending) async {
        switch action {
        case .allConversations: await audit.deleteAllConversations(model)
        case .partialDownloads: await audit.deletePartialDownloads(model)
        case .networkCache: await audit.clearNetworkCache(model)
        case .apiKey: await audit.regenerateAPIKey(model)
        case let .model(record): await audit.deleteModel(record, model: model)
        case let .orphan(row): await audit.deleteOrphan(row, model: model)
        case .everything: await audit.deleteEverythingDeletable(model)
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
