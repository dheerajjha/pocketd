import PocketdKit
import SwiftUI
import UIKit

/// The proof behind every promise on the Privacy page: what this app holds,
/// what it sends and where, and what it may read — measured on this phone.
///
/// The numbers are counted by walking the app's own folder, not by asking the
/// app what it thinks it saved (see `StoredDataAudit`), and every byte is
/// attributed somewhere, including the parts nothing here can delete. That is
/// what makes the page an argument rather than a claim, and it is kept.
///
/// What went, against the page this used to be: Swift file names, preference
/// keys, raw paths, and the vocabulary of the code (CDN, Bonjour, URLSession).
/// The list of brains with Delete buttons went too — the Brain page owns
/// brains, and two places to remove one is how they started to disagree.
/// Their bytes are still counted here, with a way to that page.
struct PrivacyDetailsView: View {
    /// The section to open at, when a promise sent the reader here.
    var focus: StoredDataAudit.Proof?

    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    @State private var audit = StoredDataAudit()
    @State private var pending: Pending?

    /// Whether the walk has landed. Every row has an empty state, and until
    /// the first walk finishes that empty state would be a falsehood: the
    /// first frame of the old page said "Nothing downloaded" on a phone
    /// holding 4.63 GB.
    private var isMeasuring: Bool { audit.survey == nil }

    var body: some View {
        ScrollViewReader { proxy in
            YouDetailScreen(
                title: "Privacy details",
                subtitle: "Counted on this iPhone just now, file by file. Pull down to count again."
            ) {
                statementSection(.account)
                statementSection(.asking)
                otherDevices
                connections
                storage
                permissions
                finePrint
                deleteEverything
            }
            .refreshable { await audit.refresh(model) }
            // Keyed on the history so the counts follow it: a page opened
            // straight from launch can measure before conversations load.
            .task(id: model.history.count) { await audit.refresh(model) }
            .task(id: focus) {
                // After the first layout, so the anchor exists to scroll to.
                guard let focus else { return }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(PDMotion.standard) { proxy.scrollTo(focus, anchor: .top) }
            }
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

    // MARK: - Promises, restated

    private func statementSection(_ proof: StoredDataAudit.Proof) -> some View {
        YouSection(proof.heading) {
            if let statement = proof.statement {
                paragraph(statement)
            }
        }
        .id(proof)
    }

    private var otherDevices: some View {
        YouSection(StoredDataAudit.Proof.otherDevices.heading) {
            if let statement = StoredDataAudit.Proof.otherDevices.statement {
                paragraph(statement)
            }
            RowDivider(inset: 0)
            paragraph(audit.caveats[0], tint: .pd.inkSecondary, font: Font.pd.footnote)
        }
        .id(StoredDataAudit.Proof.otherDevices)
    }

    // MARK: - Connections

    private var connections: some View {
        YouSection(StoredDataAudit.Proof.downloads.heading) {
            if let statement = StoredDataAudit.Proof.downloads.statement {
                paragraph(statement)
            }
            ForEach(audit.destinations) { destination in
                RowDivider(inset: 0)
                let isUsage = destination.carriesUsageCounts
                if isUsage {
                    // Where "What a count holds" lands.
                    Color.clear.frame(height: 0).id(StoredDataAudit.Proof.usage)
                }
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    Label {
                        Text(destination.host)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                    } icon: {
                        Image(systemName: "arrow.up.forward")
                            .font(Font.pd.chevron)
                            .foregroundStyle(Color.pd.accent)
                    }
                    Text(destination.sends)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(destination.when)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isUsage {
                        Text(audit.usageCountFields)
                            .font(Font.pd.footnote)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let statement = StoredDataAudit.Proof.usage.statement {
                            Text(statement)
                                .font(Font.pd.footnote)
                                .foregroundStyle(Color.pd.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, PDSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .id(StoredDataAudit.Proof.downloads)
    }

    // MARK: - On this iPhone

    private var storage: some View {
        YouSection(StoredDataAudit.Proof.storage.heading) {
            total
            if let survey = audit.survey {
                ForEach(rows(in: survey)) { row in
                    RowDivider(inset: 0)
                    DataRow(title: row.title, subtitle: row.subtitle, value: row.value, links: row.links)
                        .padding(.vertical, PDSpacing.s)
                }
                ForEach(audit.orphanedModelFiles) { orphan in
                    RowDivider(inset: 0)
                    orphanRow(orphan)
                }
            }
        }
        .id(StoredDataAudit.Proof.storage)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            if let survey = audit.survey {
                Text(pdBytes(survey.totalBytes))
                    .font(Font.pd.statValue)
                    .foregroundStyle(Color.pd.ink)
                Text("\(Format.counted(survey.totalFiles, "file")), all inside Pocketd's own folder.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                if !survey.unreadablePaths.isEmpty {
                    // A count from a walk that could not finish is a count
                    // that is too small, which on this page is the only kind of
                    // wrong that matters.
                    Text("\(Format.counted(survey.unreadablePaths.count, "folder")) couldn't be read, so the real total is higher.")
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                measuring
            }
            if let freed = audit.lastFreed {
                Text("\(freed) freed.")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.positive)
            }
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One row per kind of data, biggest decisions first: what is about you,
    /// then what you can clear, then what iOS keeps. Empty kinds that nothing
    /// can be done about are left out; the personal ones are always shown, so
    /// "no conversations" is said rather than implied.
    private struct AreaRow: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var value: String
        var links: [DataRow.Link] = []
    }

    private func rows(in survey: ContainerSurvey) -> [AreaRow] {
        var rows: [AreaRow] = []
        let downloading = audit.downloadingIDs(model)

        // Brains: counted from the files, removed on the Brain page.
        let brains = audit.models.reduce(Int64(0)) { $0 + $1.totalBytes }
        rows.append(AreaRow(
            id: "brains",
            title: StoredDataKind.models.title,
            subtitle: audit.models.isEmpty
                ? "None downloaded."
                : StoredDataKind.models.detail + " Remove them on the Brain page.",
            value: pdBytes(brains),
            links: audit.models.isEmpty ? [] : [.init("Brain page", symbol: "arrow.right") { navigator.push(.brain) }]
        ))

        let conversations = audit.conversations
        var conversationLine = StoredDataKind.conversations.detail
        if conversations.readableCount > 0 {
            conversationLine += " \(Format.counted(conversations.readableCount, "conversation")), \(Format.counted(conversations.messageCount, "message"))."
        }
        if conversations.unreadableCount > 0 {
            conversationLine += " \(Format.counted(conversations.unreadableCount, "file")) this version can't open; Delete removes them too."
        }
        rows.append(AreaRow(
            id: "conversations",
            title: StoredDataKind.conversations.title,
            subtitle: conversationLine,
            value: pdBytes(conversations.byteCount),
            links: conversations.fileCount + conversations.remnantCount > 0
                ? [.init("Delete", symbol: "trash") { pending = .conversations }]
                : []
        ))

        for kind in [StoredDataKind.scheduledTasks, .dailyBrief] {
            let area = survey.area(kind)
            rows.append(AreaRow(id: kind.rawValue, title: kind.title, subtitle: kind.detail, value: pdBytes(area.tally.byteCount)))
        }

        let partial = survey.area(.partialDownloads)
        if !partial.tally.isEmpty {
            rows.append(AreaRow(
                id: StoredDataKind.partialDownloads.rawValue,
                title: StoredDataKind.partialDownloads.title,
                subtitle: StoredDataKind.partialDownloads.detail
                    + (downloading.isEmpty ? " Deleting them means a paused download starts again." : " A download is running, so they stay for now."),
                value: pdBytes(partial.tally.byteCount),
                links: downloading.isEmpty ? [.init("Delete", symbol: "trash") { pending = .partialDownloads }] : []
            ))
        }

        let cache = survey.area(.networkCache)
        if !cache.tally.isEmpty {
            rows.append(AreaRow(
                id: StoredDataKind.networkCache.rawValue,
                title: StoredDataKind.networkCache.title,
                subtitle: StoredDataKind.networkCache.detail,
                value: pdBytes(cache.tally.byteCount),
                links: [.init("Clear", symbol: "trash") { pending = .networkCache }]
            ))
        }

        // What this page can only describe: the settings file, what iOS
        // keeps, and anything it has no name for. Shown with the reason it
        // stays, because a privacy page listing only what it can delete is
        // describing its own buttons, not the phone.
        for kind in [StoredDataKind.preferences, .shaderCache, .systemState, .other] {
            let area = survey.area(kind)
            guard !area.tally.isEmpty else { continue }
            rows.append(AreaRow(
                id: kind.rawValue,
                title: kind.title,
                subtitle: [kind.detail, kind.disposal.limitation].compactMap { $0 }.joined(separator: " "),
                value: pdBytes(area.tally.byteCount)
            ))
        }
        return rows
    }

    private func orphanRow(_ orphan: StoredDataAudit.OrphanRow) -> some View {
        // Live download state, not the state of the last walk: a download for
        // exactly this brain can start while the page is open, and the file
        // this row offers to delete is then the finished half of it.
        let abandoned = orphan.isStillAbandoned(downloadingIDs: audit.downloadingIDs(model))
        return DataRow(
            title: "Leftover brain file",
            subtitle: abandoned
                ? orphan.explanation
                : "A download for it is running, so it stays until that finishes.",
            value: pdBytes(orphan.file.byteCount),
            valueTint: .pd.caution,
            links: abandoned ? [.init("Delete", symbol: "trash") { pending = .orphan(orphan) }] : []
        )
        .padding(.vertical, PDSpacing.s)
    }

    // MARK: - Permissions

    private var permissions: some View {
        YouSection(StoredDataAudit.Proof.permissions.heading) {
            ForEach(Array(audit.permissions.enumerated()), id: \.element.id) { index, row in
                if index > 0 { RowDivider(inset: 0) }
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                        Text(row.title)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                        Spacer(minLength: PDSpacing.xs)
                        Text(row.state.label)
                            .font(Font.pd.secondary.weight(.semibold))
                            .foregroundStyle(row.state.isConcern ? Color.pd.caution : Color.pd.inkSecondary)
                            .multilineTextAlignment(.trailing)
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
                // The note is part of the row's meaning — "Not reported by
                // iOS" with its reason removed reads like a dodge.
                .accessibilityLabel(permissionAnnouncement(title: row.title, state: row.state.label, note: row.note))
            }
            RowDivider(inset: 0)
            LinkRow(symbol: "gear", title: "Open iOS Settings", detail: nil) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        .id(StoredDataAudit.Proof.permissions)
    }

    // MARK: - Fine print

    private var finePrint: some View {
        YouSection("The fine print") {
            ForEach(Array(audit.caveats.dropFirst().enumerated()), id: \.offset) { index, line in
                if index > 0 { RowDivider(inset: 0) }
                paragraph(line, tint: .pd.inkSecondary, font: Font.pd.footnote)
            }
        }
    }

    // MARK: - Delete everything

    private var deleteEverything: some View {
        let plan = audit.deletionPlan(model)
        return YouSection(StoredDataAudit.Proof.deleting.heading, footnote: everythingFooter(plan)) {
            DangerButton(
                title: "Delete everything Pocketd stores",
                symbol: "trash",
                isEnabled: !isMeasuring && !plan.isEmpty
            ) {
                pending = .everything
            }
            .padding(.vertical, PDSpacing.xs)
        }
        .id(StoredDataAudit.Proof.deleting)
    }

    /// Built from the same plan the delete itself uses, in the Kit, so the
    /// promise this control makes is somewhere a test can read it.
    private func everythingFooter(_ plan: DeletionPlan) -> String {
        DeletionNarrative.sentences(
            plan: plan,
            measured: !isMeasuring,
            systemOwnedTitles: audit.systemOwnedAreas.map(\.kind.title),
            preferencesBytes: audit.survey?.area(.preferences).tally.byteCount ?? 0,
            unnamedTitles: audit.unnamedAreas.map(\.kind.title),
            unnamedBytes: audit.unnamedAreas.reduce(0) { $0 + $1.tally.byteCount }
        )
        .joined(separator: " ")
    }

    // MARK: - Small pieces

    private func paragraph(_ text: String, tint: Color = .pd.ink, font: Font = Font.pd.body) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, PDSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var measuring: some View {
        HStack(spacing: PDSpacing.xs) {
            ProgressView().controlSize(.small)
            Text("Counting…")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Confirmation

    private enum Pending: Identifiable, Equatable {
        case conversations
        case partialDownloads
        case networkCache
        case orphan(StoredDataAudit.OrphanRow)
        case everything

        var id: String {
            switch self {
            case .conversations: "conversations"
            case .partialDownloads: "partial"
            case .networkCache: "cache"
            case let .orphan(row): "orphan-\(row.id)"
            case .everything: "everything"
            }
        }

        var title: String {
            switch self {
            case .conversations: "Delete every conversation?"
            case .partialDownloads: "Delete unfinished downloads?"
            case .networkCache: "Clear the network cache?"
            case .orphan: "Delete this file?"
            case .everything: "Delete everything Pocketd stores?"
            }
        }

        var confirmTitle: String {
            self == .networkCache ? "Clear" : "Delete"
        }
    }

    /// What is lost, in the terms it will be lost in — and, on this page,
    /// that there is no copy anywhere to restore from.
    private func message(for action: Pending) -> String {
        switch action {
        case .conversations:
            let summary = audit.conversations
            return "\(Format.counted(summary.readableCount, "conversation")), \(pdBytes(summary.byteCount)). Nothing was ever uploaded, so there is no copy anywhere to bring back."
        case .partialDownloads:
            let area = audit.survey?.area(.partialDownloads) ?? StoredDataArea(kind: .partialDownloads)
            return "Frees \(pdBytes(area.tally.byteCount)). A paused download starts again from the beginning."
        case .networkCache:
            let area = audit.survey?.area(.networkCache) ?? StoredDataArea(kind: .networkCache)
            return "Frees about \(pdBytes(area.tally.byteCount)). iOS frees the last of it in its own time."
        case let .orphan(row):
            return "Frees \(pdBytes(row.file.byteCount)). \(row.explanation)"
        case .everything:
            var sentences = DeletionNarrative.confirmation(plan: audit.deletionPlan(model))
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
        case .partialDownloads: await audit.deletePartialDownloads(model)
        case .networkCache: await audit.clearNetworkCache(model)
        case let .orphan(row): await audit.deleteOrphan(row, model: model)
        case .everything: await audit.deleteEverythingDeletable(model)
        }
        if let freed = audit.lastFreed {
            toasts.show("\(freed) freed", symbol: "trash")
        }
    }
}

// MARK: - Previews

#Preview("Privacy details light") {
    NavigationStack { PrivacyDetailsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Privacy details dark") {
    NavigationStack { PrivacyDetailsView(focus: .usage) }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
