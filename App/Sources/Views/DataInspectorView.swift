import PocketdKit
import SwiftUI

/// Everything this app holds, and everything it sends, with a way to remove
/// each of them.
///
/// The competitor's onboarding promises a screen like this and never ships it.
/// Building it is nearly free here and the promise is true here, which is the
/// whole argument — so the screen is written as an argument: quiet, specific,
/// numbers you can go and check, and a plain statement wherever the answer is
/// "this cannot be deleted from here" rather than a category left out.
///
/// Present it from anywhere with `.sheet { DataInspectorView() }`. It reads
/// `AppModel` from the environment and owns everything else itself.
struct DataInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var audit = StoredDataAudit()
    @State private var pending: Pending?
    @State private var showAPIKey = false

    var body: some View {
        NavigationStack {
            List {
                summarySection
                leavesSection
                modelsSection
                conversationsSection
                partialDownloadsSection
                networkCacheSection
                settingsSection
                permissionsSection
                systemSection
                unnamedSection
                deleteEverythingSection
            }
            .navigationTitle("Your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            LabeledContent("On this iPhone") {
                if let survey = audit.survey {
                    Text(bytes(survey.totalBytes)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityLabel("Total stored by Pocketd")
            if let survey = audit.survey {
                LabeledContent("Files", value: "\(survey.totalFiles)")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                if !survey.unreadablePaths.isEmpty {
                    // A count taken from a walk that could not finish is a
                    // count that is too small, which on this screen is the
                    // only kind of wrong that matters.
                    Label(
                        "\(survey.unreadablePaths.count) folders could not be read, so the total above is a floor rather than a figure.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
            if let freed = audit.lastFreed {
                Label("\(freed) freed.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Everything Pocketd stores")
        } footer: {
            Text("Counted by walking this app's own folder on this device, not by asking the app what it thinks it saved. Pull down to measure again.")
        }
    }

    // MARK: - What leaves

    private var leavesSection: some View {
        Section {
            ForEach(audit.destinations) { destination in
                VStack(alignment: .leading, spacing: 3) {
                    Label(destination.host, systemImage: "arrow.up.forward")
                        .font(.subheadline.weight(.medium))
                    Text(destination.sends).font(.footnote).foregroundStyle(.secondary)
                    Text(destination.when).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            ForEach(audit.assurances, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("The awkward parts") {
                ForEach(audit.caveats, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .font(.subheadline)
        } header: {
            Text("What leaves this device")
        } footer: {
            Text("Two connections, both to Hugging Face, both about model files. This list comes from reading every network call in the source; it is the one claim on this screen you cannot check from the phone itself.")
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            if audit.models.isEmpty {
                Text("No models downloaded.").foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(audit.models) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.record.displayName).font(.subheadline)
                        if row.isLoaded {
                            Circle().fill(.green).frame(width: 7, height: 7)
                                .accessibilityLabel("In memory now")
                        }
                        Spacer()
                        Text(bytes(row.totalBytes)).font(.subheadline).monospacedDigit()
                    }
                    if row.projectorBytes > 0 {
                        Text("\(bytes(row.weightsBytes)) of weights and \(bytes(row.projectorBytes)) of image projector.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if row.isMissing {
                        Text("Listed as installed, and its file is not on disk.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Delete", role: .destructive) { pending = .model(row.record) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Delete \(row.record.displayName), \(bytes(row.totalBytes))")
                }
                .padding(.vertical, 2)
            }
            ForEach(audit.orphanedModelFiles) { orphan in
                // Live download state, not the state of the last walk. The
                // sheet can sit open while a download starts, and the file this
                // row offers to delete is then the finished half of it.
                let abandoned = orphan.isStillAbandoned(downloadingIDs: Set(model.downloads.keys))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(orphan.file.name).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(bytes(orphan.file.byteCount)).font(.subheadline).monospacedDigit()
                    }
                    Text(orphan.explanation).font(.caption).foregroundStyle(.orange)
                    if !abandoned {
                        Text("A download for this model is running, so this file is not stranded after all. It is left alone until the download finishes or is cancelled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Delete", role: .destructive) { pending = .orphan(orphan) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!abandoned)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(StoredDataKind.models.title)
        } footer: {
            Text(StoredDataKind.models.detail + " Sizes are read from the files themselves, so a model that downloaded short shows what actually arrived.")
        }
    }

    // MARK: - Conversations

    private var conversationsSection: some View {
        Section {
            let summary = audit.conversations
            LabeledContent("Conversations", value: "\(summary.readableCount)")
            LabeledContent("Messages", value: "\(summary.messageCount)")
            LabeledContent("Size") { Text(bytes(summary.byteCount)).monospacedDigit() }
            if let oldest = summary.oldest, let newest = summary.newest {
                LabeledContent("From", value: oldest.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("To", value: newest.formatted(date: .abbreviated, time: .omitted))
            }
            if summary.unreadableCount > 0 {
                // These are the ones a naive delete leaves behind, so they are
                // named before the button rather than after it.
                Text("\(summary.unreadableCount) transcripts on disk cannot be opened by this build and do not appear in your history. They are still text you typed, and Delete below removes them too.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if summary.remnantCount > 0 {
                // The size above counts these, so the screen says what they
                // are rather than letting the number be larger than the
                // conversation count explains.
                Text("\(summary.remnantCount) files here — \(bytes(summary.remnantBytes)) — are not transcripts. Saving writes each conversation to a temporary file first, and a process killed mid-write leaves one behind. They are in the size above and Delete removes them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Delete every conversation", role: .destructive) { pending = .allConversations }
                .disabled(summary.fileCount == 0 && summary.remnantCount == 0)
        } header: {
            Text(StoredDataKind.conversations.title)
        } footer: {
            Text(StoredDataKind.conversations.detail + " Not encrypted beyond what iOS does for every file on a locked device, and never sent anywhere.")
        }
    }

    // MARK: - Unfinished downloads

    @ViewBuilder
    private var partialDownloadsSection: some View {
        let area = audit.survey?.area(.partialDownloads) ?? StoredDataArea(kind: .partialDownloads)
        Section {
            if area.tally.isEmpty {
                Text("Nothing left over.").font(.footnote).foregroundStyle(.secondary)
            } else {
                LabeledContent("Left on disk") { Text(bytes(area.tally.byteCount)).monospacedDigit() }
                // The paths are here because the surprising one — a partial
                // model parked in `tmp` by URLSession — is not somewhere a
                // person would think to look, and naming it is most of the
                // point of reporting it.
                ForEach(area.files.prefix(6)) { file in
                    Text(file.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if area.files.count > 6 {
                    Text("and \(area.files.count - 6) more, all of which Delete removes")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Delete unfinished downloads", role: .destructive) { pending = .partialDownloads }
                    .disabled(!model.downloads.isEmpty)
                if !model.downloads.isEmpty {
                    Text("A download is running. One of the files above belongs to it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(StoredDataKind.partialDownloads.title)
        } footer: {
            Text(StoredDataKind.partialDownloads.detail + " Cancelling a download in the Models tab keeps these on purpose, so the next attempt resumes instead of starting again.")
        }
    }

    // MARK: - Settings and keys

    private var settingsSection: some View {
        Section {
            if model.configuration.requiresAuth {
                HStack {
                    Text("API key")
                    Spacer()
                    Text(showAPIKey ? model.configuration.apiKey : redactedSecret(model.configuration.apiKey))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                        .font(.caption)
                        .accessibilityHint("Reveals the key other devices use to reach this phone")
                }
                Button("Replace the API key", role: .destructive) { pending = .apiKey }
            } else {
                Label("No API key is required, so anything on your network can use this model.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(audit.defaults) { row in
                LabeledContent {
                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(row.key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(row.isSystem ? .secondary : .primary)
                }
            }
        } header: {
            Text(StoredDataKind.preferences.title)
        } footer: {
            Text("Every key in this app's preferences file, listed as it is stored — the app's own first, anything iOS wrote after. \(bytes(audit.survey?.area(.preferences).tally.byteCount ?? 0)) in all. \(StoredDataKind.preferences.disposal.limitation ?? "")")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(audit.permissions) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.title)
                        Spacer()
                        Text(row.state.label)
                            .font(.caption)
                            .foregroundStyle(row.state.isConcern ? Color.orange : Color.secondary)
                    }
                    if let note = row.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title): \(row.state.label)")
            }
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Taken from what this app declares in its own bundle, so a permission added to Pocketd appears here whether or not anyone remembered to update this screen. The calendar and reminder switches live under Privacy & Security, per app; iOS does not let an app link you straight to them.")
        }
    }

    // MARK: - What cannot be deleted from here

    /// The cache is separate from the shader cache above it on purpose: one is
    /// a record of what someone looked for and the other is compiled GPU code,
    /// and only one of them is worth a delete button.
    @ViewBuilder
    private var networkCacheSection: some View {
        let area = audit.survey?.area(.networkCache) ?? StoredDataArea(kind: .networkCache)
        Section {
            if area.tally.isEmpty {
                Text("Nothing cached.").font(.footnote).foregroundStyle(.secondary)
            } else {
                LabeledContent("Kept by the system") { Text(bytes(area.tally.byteCount)).monospacedDigit() }
                Button("Clear the network cache", role: .destructive) { pending = .networkCache }
            }
        } header: {
            Text(StoredDataKind.networkCache.title)
        } footer: {
            Text(StoredDataKind.networkCache.detail + " Searching from this phone leaves nothing here; the searches a paired laptop asks this phone to run do, and that is a difference worth knowing about.")
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        if !audit.systemOwnedAreas.isEmpty {
            Section {
                ForEach(audit.systemOwnedAreas) { area in
                    areaRow(area)
                }
            } header: {
                Text("Held by iOS, not by Pocketd")
            } footer: {
                Text("Listed rather than hidden. A privacy screen that shows only the parts with a delete button beside them is describing its own buttons, not your device.")
            }
        }
    }

    /// Separate from the section above it, and the separation is the fix.
    ///
    /// These bytes were being shown under "Held by iOS, not by Pocketd" and
    /// named in the delete-everything dialog as something "nothing inside this
    /// app can" remove. Neither is true — this is Pocketd's own container, and
    /// `Documents` lands here — and because every iOS container has a metadata
    /// plist at its root, the false sentence rendered on every device.
    @ViewBuilder
    private var unnamedSection: some View {
        if !audit.unnamedAreas.isEmpty {
            Section {
                ForEach(audit.unnamedAreas) { area in
                    areaRow(area)
                }
            } header: {
                Text("In Pocketd's folder, unnamed by this screen")
            } footer: {
                Text("Counted in the total at the top and listed by path, so the number up there is not missing them. Every button on this screen leaves them alone: sweeping up whatever it could not identify is exactly the promise this screen exists to disprove.")
            }
        }
    }

    private func areaRow(_ area: StoredDataArea) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(area.kind.title).font(.subheadline)
                Spacer()
                Text(bytes(area.tally.byteCount)).font(.subheadline).monospacedDigit()
            }
            Text(area.kind.detail).font(.caption).foregroundStyle(.secondary)
            if let limitation = area.kind.disposal.limitation {
                Text(limitation).font(.caption).foregroundStyle(.secondary)
            }
            if area.kind == .other {
                ForEach(area.files) { file in
                    Text(file.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if area.unlistedFileCount > 0 {
                    Text("and \(area.unlistedFileCount) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Delete everything

    private var deleteEverythingSection: some View {
        Section {
            Button("Delete everything Pocketd can delete", role: .destructive) { pending = .everything }
                .disabled(audit.deletionPlan(model).isEmpty)
        } footer: {
            Text(everythingFooter)
        }
    }

    /// The confirmation dialog's body and the footer are the same string on
    /// purpose, and both are built from the plan the delete itself uses. The
    /// footer used to be written by hand from a total that summed every
    /// deletable area — including unfinished downloads, which the delete skips
    /// whenever one is running — so with a transfer in flight it promised
    /// gigabytes it then deliberately left alone.
    private var everythingFooter: String {
        let plan = audit.deletionPlan(model)
        var sentences: [String] = []

        if plan.included.isEmpty {
            sentences.append("There is nothing here left for this screen to delete.")
        } else {
            sentences.append("Removes \(bytes(plan.byteCount)): \(list(plan.included.map(\.name))).")
        }
        for entry in plan.skipped {
            guard let reason = entry.skippedBecause else { continue }
            sentences.append("It leaves \(entry.name) — \(bytes(entry.byteCount)) — because \(reason).")
        }
        if plan.included.contains(where: { $0.name == DeletionPlan.EntryName.networkCache }) {
            // The "freed" line afterwards is measured from the container, so
            // it will fall short of the number above by whatever iOS has not
            // released yet. Better said here than left as an unexplained gap.
            sentences.append("iOS owns the cache files themselves, so the last of that number can take a while to come back.")
        }
        sentences.append("The API key is left alone, so devices you have already paired keep working — replace it above if that is what you want.")

        let systemOwned = audit.systemOwnedAreas.map(\.kind.title)
        let preferences = audit.survey?.area(.preferences)
        let keptByIOS = systemOwned + ((preferences?.tally.isEmpty == false) ? [StoredDataKind.preferences.title] : [])
        if !keptByIOS.isEmpty {
            sentences.append("It does not touch \(list(keptByIOS)) — nothing inside this app can, and deleting the app is the only thing that removes them.")
        }
        let unnamed = audit.unnamedAreas
        if !unnamed.isEmpty {
            let size = bytes(unnamed.reduce(0) { $0 + $1.tally.byteCount })
            // Deliberately not folded into the sentence above. These bytes are
            // in this app's own folder and it could remove them; it will not,
            // because it cannot say what they are, and that is a different
            // claim from "nothing inside this app can".
            sentences.append("It also leaves \(list(unnamed.map(\.kind.title))) — \(size) this screen has no name for and so will not delete.")
        }
        return sentences.joined(separator: " ")
    }

    /// "a, b and c", because a footer that says "a, b, c" reads like a
    /// truncated list on the screen whose subject is completeness.
    private func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
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
    /// because on this screen the second half is the point: there is no copy
    /// on a server to restore from, and that is the same fact the rest of the
    /// screen is selling.
    private func message(for action: Pending) -> String {
        switch action {
        case .allConversations:
            let summary = audit.conversations
            var text = "\(summary.readableCount) conversations, \(summary.messageCount) messages, \(bytes(summary.byteCount))."
            if summary.remnantCount > 0 {
                // Named because they are inside the byte count above, and a
                // number a reader cannot account for is a number they stop
                // trusting.
                text += " That includes \(summary.remnantCount) leftover files from interrupted saves, which go too."
            }
            return text + " Every question you asked and every answer you got. Nothing was ever uploaded, so there is no copy anywhere to restore from."
        case .partialDownloads:
            let area = audit.survey?.area(.partialDownloads) ?? StoredDataArea(kind: .partialDownloads)
            return "Frees \(bytes(area.tally.byteCount)). Any download you paused starts again from zero next time instead of resuming."
        case .networkCache:
            let area = audit.survey?.area(.networkCache) ?? StoredDataArea(kind: .networkCache)
            return "Discards \(bytes(area.tally.byteCount)) of Hugging Face responses and cookies. iOS manages these files, so the number above may not drop all the way to zero straight away."
        case .apiKey:
            return "Every device already paired stops working and has to pair again. The old key cannot be recovered."
        case let .model(record):
            let row = audit.models.first { $0.id == record.id }
            let size = bytes(row?.totalBytes ?? record.totalDownloadBytes)
            return model.loadedModelID == record.id
                ? "\(record.displayName) is in memory right now. Deleting it unloads it and frees \(size), which has to be downloaded again to use it."
                : "Frees \(size). It has to be downloaded again to use it."
        case let .orphan(row):
            return "Frees \(bytes(row.file.byteCount)). \(row.explanation)"
        case .everything:
            return everythingFooter
        }
    }

    private func perform(_ action: Pending) async {
        switch action {
        case .allConversations:
            await audit.deleteAllConversations(model)
        case .partialDownloads:
            await audit.deletePartialDownloads(model)
        case .networkCache:
            await audit.clearNetworkCache(model)
        case .apiKey:
            await audit.regenerateAPIKey(model)
        case let .model(record):
            await model.delete(record)
            await audit.refresh(model)
        case let .orphan(row):
            await audit.deleteOrphan(row, model: model)
        case .everything:
            await audit.deleteEverythingDeletable(model)
        }
    }

    private func bytes(_ count: Int64) -> String {
        StoredDataAudit.formatted(count)
    }
}
