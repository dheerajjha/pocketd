import Foundation
import HealthKit
import PocketdKit
import SwiftUI

/// Everything this app holds, measured on demand.
///
/// Measured rather than derived. The manifest, the conversation list and the
/// download progress in `AppModel` are all in-memory pictures of the disk, and
/// each of them is allowed to be incomplete for good reasons — `ModelStore`
/// drops manifest entries whose file vanished, `ConversationStore` skips a
/// transcript it cannot decode, and a paused download's byte count lives only
/// until the app is force-quit. A screen that assembled itself from those
/// would under-report by exactly the amount that matters, and under-reporting
/// is the only way this screen can be a lie. So it walks the container.
@MainActor
@Observable
final class StoredDataAudit {
    private(set) var survey: ContainerSurvey?
    private(set) var models: [ModelRow] = []
    /// Files in the models directory that the manifest does not list. Normally
    /// none; `ModelStore` calls a weights file in this state "a multi-gigabyte
    /// leak that delete can never be called on".
    private(set) var orphanedModelFiles: [OrphanRow] = []
    private(set) var conversations = ConversationSummary()
    private(set) var defaults: [DefaultsRow] = []
    private(set) var permissions: [PermissionRow] = []
    /// The last thing a delete actually did, in bytes, so the screen can prove
    /// the button was not decorative.
    private(set) var lastFreed: String?

    /// The walk in progress, so a second one queues behind it instead of
    /// racing it. See `refresh`.
    private var refreshTask: Task<Void, Never>?

    /// Transfers `ModelStore` knew about at the last walk or delete.
    ///
    /// Cached because the footer and every row's enabled state are computed
    /// synchronously inside `body`, and the authoritative set lives behind an
    /// actor. It is only ever unioned with the app's own live map, never used
    /// in place of it, so a stale entry can only make this screen refuse to
    /// delete something — the direction that cannot destroy anything.
    private var storeTransfers: Set<String> = []

    /// The app's own directory on this device. Everything below is inside it.
    let container = URL(fileURLWithPath: NSHomeDirectory())

    // MARK: - Rows

    struct ModelRow: Identifiable, Equatable {
        var record: ModelRecord
        /// Read from the filesystem, not from the manifest.
        var weightsBytes: Int64
        var projectorBytes: Int64
        var isLoaded: Bool
        var isMissing: Bool

        var id: String { record.id }
        var totalBytes: Int64 { weightsBytes + projectorBytes }
    }

    struct OrphanRow: Identifiable, Equatable {
        var orphan: OrphanedModelFile
        var url: URL
        var file: StoredFile { orphan.file }
        var explanation: String { orphan.explanation }
        var id: String { orphan.id }

        /// Whether the file is still abandoned *now*, as against when the
        /// container was last walked. A download started since then makes this
        /// row a live transfer's completed half.
        func isStillAbandoned(downloadingIDs: Set<String>) -> Bool {
            guard let id = ModelFileRole.of(fileNamed: file.name).modelID else { return true }
            return !downloadingIDs.contains(id)
        }
    }

    struct ConversationSummary: Equatable {
        var fileCount = 0
        var readableCount = 0
        var messageCount = 0
        /// Every byte in the conversations directory, which is every byte the
        /// delete removes. The two used to differ — the count was `.json` only
        /// while the size was the whole directory and the delete was `.json`
        /// only again — so the size row and the confirmation both quoted bytes
        /// that stayed on disk.
        var byteCount: Int64 = 0
        /// Files in the conversations directory that are not transcripts.
        /// `ConversationStore.save` writes with `.atomic`, which stages a temp
        /// file in the same directory, and its own doc comment is about the
        /// kernel killing the process mid-write. The remnant is real, it is
        /// counted, and it is removed.
        var remnantCount = 0
        var remnantBytes: Int64 = 0
        var oldest: Date?
        var newest: Date?

        /// Transcripts on disk that the app itself cannot open. They are still
        /// text someone typed, they are still in the count, and a delete that
        /// walked the readable list alone would leave them behind.
        var unreadableCount: Int { max(0, fileCount - readableCount) }
    }

    struct DefaultsRow: Identifiable, Equatable {
        var key: String
        var summary: String
        /// Written by iOS rather than by this app.
        var isSystem: Bool
        var id: String { key }
    }

    struct PermissionRow: Identifiable, Equatable {
        var title: String
        var infoKey: String
        var state: PermissionState
        /// Why the state reads the way it does, when that needs saying.
        var note: String?
        var id: String { infoKey }
    }

    /// What iOS will tell us about a permission, including the two cases where
    /// the honest answer is that it will not tell us anything.
    enum PermissionState: Equatable {
        case granted
        case denied
        case restricted
        case notAsked
        case addOnly
        /// iOS reports no read authorization for this, by design, so no app can
        /// show it — including this one.
        case neverReported
        /// There is no store on this device to have a permission about.
        case unavailable

        var label: String {
            switch self {
            case .granted: "Allowed"
            case .denied: "Not allowed"
            case .restricted: "Restricted"
            case .notAsked: "Never asked"
            case .addOnly: "Add only"
            case .neverReported: "Not reported by iOS"
            case .unavailable: "Unavailable on this device"
            }
        }

        /// Whether the row needs to catch the eye. "Not reported" does: it is
        /// the honest answer and it is also the one a reader will assume is a
        /// dodge unless it is given the weight of a warning and a reason.
        var isConcern: Bool {
            switch self {
            case .granted, .notAsked, .unavailable: false
            case .denied, .restricted, .addOnly, .neverReported: true
            }
        }
    }

    /// Somewhere bytes go when they leave this phone.
    struct Destination: Identifiable, Equatable {
        var host: String
        var sends: String
        var when: String
        var id: String { host + when }
    }

    // MARK: - What leaves

    /// Every outbound connection this app makes, from a grep of the whole
    /// repository for `URLSession` and `URLRequest`. Two of them, both to
    /// Hugging Face, both about model files. Inference never calls out — the
    /// weights are a file on this phone. The HTTP server does: `GET
    /// /api/search`, `POST /api/pull` and `POST /api/models/add` all reach
    /// Hugging Face because a network peer asked them to, which is why both
    /// rows below say "or when a paired device asks".
    ///
    /// Hardcoded rather than observed, and that is the weakness of this
    /// section: it is a claim about the source, checked when it was written.
    /// The claim is worth making anyway because it is the one thing a user
    /// most wants to know and cannot find out for themselves.
    let destinations: [Destination] = [
        Destination(
            host: "huggingface.co",
            sends: "The name of the repository you searched for, and this phone's IP address.",
            when: "Only while a model search is open, or when a paired device asks this phone to search."
        ),
        Destination(
            host: "huggingface.co, redirecting to its CDN",
            sends: "Which model file you are fetching, and this phone's IP address. No account, no token, no identifier of yours.",
            when: "Only while a model is downloading."
        ),
    ]

    /// True of what leaves, and true of the things people assume leave.
    let assurances: [String] = [
        "Inference is local. Nothing you type in Chat, and nothing a paired device sends, is transmitted anywhere — it goes to a file of weights on this phone and comes back.",
        "The HTTP server never calls out on its own initiative. The only requests it makes are the two above, and only when a paired device asks it to search Hugging Face or to pull a model.",
        "There is no analytics, no crash reporting and no telemetry of any kind in this app. There is no server to receive it, because there is no account.",
    ]

    /// The awkward corners, which belong on a page like this more than the
    /// reassurances do.
    let caveats: [String] = [
        "While the server is running, this phone announces itself over Bonjour to everyone on the same Wi-Fi: its device name, this app's version, whether a key is required, and the id of the loaded model. That is how a laptop finds it without typing an address. It never leaves the local network.",
        "Every download address is built as huggingface.co, then the repository and filename, and the CDN it redirects to serves the bytes. Adding a model by search does not change that: the search API takes a repository and a filename, never a host. The record type carries a field that could point somewhere else, and nothing in this app or its HTTP API sets it.",
        "Opening a model's page hands the address to Safari. What Safari then sends is Safari's business, with Safari's cookies.",
        "Copying the API key or the server address puts it on the system pasteboard. If Handoff is on, Universal Clipboard forwards the pasteboard to your other Apple devices through iCloud.",
    ]

    // MARK: - Measuring

    /// Measures everything again, one walk at a time.
    ///
    /// Serialised rather than merely guarded. `.task` and `.refreshable`
    /// overlap routinely and every delete schedules a walk of its own on top of
    /// them, and because each walk publishes unconditionally when it lands, two
    /// in flight publish in completion order rather than start order — so the
    /// older one can overwrite the newer one's numbers, which on a screen that
    /// has just deleted something means showing the bytes back again. Queuing
    /// behind the previous walk rather than joining it matters too: a caller
    /// that has just removed files needs numbers measured after its own delete,
    /// not the ones a walk already in flight is about to publish.
    func refresh(_ model: AppModel) async {
        let previous = refreshTask
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.measure(model)
        }
        refreshTask = task
        await task.value
    }

    private func measure(_ model: AppModel) async {
        let container = container
        let modelsDirectory = try? ModelStore.defaultDirectory()
        let conversationsDirectory = try? ConversationStore.defaultDirectory()

        // Off the main actor: this stats every file in the container, and the
        // container holds gigabytes of weights on a device that is also
        // generating tokens.
        let walk = await Task.detached(priority: .userInitiated) { () -> Walk in
            Walk(
                survey: ContainerSurvey.survey(container: container),
                modelFiles: modelsDirectory.map { StoredFile.listing(of: $0) } ?? [],
                conversationFiles: conversationsDirectory.map { StoredFile.listing(of: $0) } ?? []
            )
        }.value

        // The manifest rather than `AppModel.installed`, and the store rather
        // than `AppModel.downloads`. Both of those are snapshots of what this
        // app's own UI did; a model a paired device pulled over the HTTP API is
        // in neither, which made this screen call it a stray file, offer a live
        // Delete for it, and — while the pull was still running — sweep the
        // bytes URLSession was writing.
        let installedNow = await model.manifestInstalled()
        storeTransfers = await model.transfersInFlight()

        survey = walk.survey
        models = Self.modelRows(installed: installedNow, files: walk.modelFiles, loaded: model.loadedModelID)
        orphanedModelFiles = Self.orphans(
            files: walk.modelFiles,
            knownIDs: Set(installedNow.map(\.id)),
            downloadingIDs: downloadingIDs(model),
            directory: modelsDirectory
        )
        conversations = Self.conversationSummary(files: walk.conversationFiles, readable: model.history)
        defaults = Self.defaultsRows()
        permissions = Self.permissionRows()
    }

    /// Every model id with a transfer running, from both doors.
    ///
    /// The app's live map is unioned in rather than replaced by the store's set
    /// because it is written the instant a tap lands, before the store's task
    /// has begun. Neither alone is complete.
    func downloadingIDs(_ model: AppModel) -> Set<String> {
        // Active only. A finished notice still on screen, or a transfer paused
        // with its bytes on disk, is not a reason to refuse a delete — and
        // this set is what guards one.
        storeTransfers.union(model.transfers.values.filter(\.isActive).map(\.id))
    }

    /// The same question, asked of the store again, for a caller about to
    /// delete something on the strength of the answer.
    private func liveDownloadingIDs(_ model: AppModel) async -> Set<String> {
        storeTransfers = await model.transfersInFlight()
        return downloadingIDs(model)
    }

    private struct Walk: Sendable {
        var survey: ContainerSurvey
        var modelFiles: [StoredFile]
        var conversationFiles: [StoredFile]
    }

    private static func modelRows(
        installed: [ModelRecord],
        files: [StoredFile],
        loaded: String?
    ) -> [ModelRow] {
        var sizes: [String: (weights: Int64, projector: Int64)] = [:]
        for file in files {
            switch ModelFileRole.of(fileNamed: file.name) {
            case let .weights(id): sizes[id, default: (0, 0)].weights += file.byteCount
            case let .projector(id): sizes[id, default: (0, 0)].projector += file.byteCount
            case .resumeBlob, .manifest, .unrecognised: continue
            }
        }
        return installed.map { record in
            let measured = sizes[record.id]
            return ModelRow(
                record: record,
                weightsBytes: measured?.weights ?? 0,
                projectorBytes: measured?.projector ?? 0,
                isLoaded: loaded == record.id,
                // The manifest says this model is installed and there is no
                // file. `ModelStore.load()` prunes these at launch, so seeing
                // one means the file went missing while the app was running.
                isMissing: measured == nil
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// The rule itself lives in `ModelDirectoryAudit`, where it can be tested
    /// against a download in flight without a device. This only attaches a URL
    /// to each result.
    private static func orphans(
        files: [StoredFile],
        knownIDs: Set<String>,
        downloadingIDs: Set<String>,
        directory: URL?
    ) -> [OrphanRow] {
        guard let directory else { return [] }
        return ModelDirectoryAudit.orphans(
            files: files,
            installedIDs: knownIDs,
            downloadingIDs: downloadingIDs
        )
        .map { OrphanRow(orphan: $0, url: directory.appendingPathComponent($0.file.name)) }
    }

    private static func conversationSummary(
        files: [StoredFile],
        readable: [Conversation]
    ) -> ConversationSummary {
        var summary = ConversationSummary()
        let transcripts = files.filter { $0.name.hasSuffix(".json") }
        let remnants = files.filter { !$0.name.hasSuffix(".json") }
        summary.fileCount = transcripts.count
        summary.remnantCount = remnants.count
        summary.remnantBytes = remnants.reduce(0) { $0 + $1.byteCount }
        // Every file in the directory, because the delete now takes every file
        // in the directory. Counting bytes the button then leaves behind is the
        // same lie as not counting them, told in the other direction.
        summary.byteCount = files.reduce(0) { $0 + $1.byteCount }
        summary.readableCount = readable.count
        summary.messageCount = readable.reduce(0) { $0 + $1.messages.count }
        // From the transcripts rather than from file dates: a file's timestamp
        // is when it was last written, which for a conversation reopened this
        // morning is today, whatever it says inside.
        summary.oldest = readable.map(\.createdAt).min()
        summary.newest = readable.map(\.updatedAt).max()
        return summary
    }

    /// What is in this app's own preferences file.
    ///
    /// Read from the persistent domain rather than by listing the key names
    /// this app is known to use. The key names live in a private enum in
    /// `AppModel`; restating them here would mean a setting added tomorrow is
    /// stored, is real, and is invisible on the one screen that promises to
    /// show everything.
    private static func defaultsRows() -> [DefaultsRow] {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID)
        else { return [] }

        return domain.keys.sorted().map { key in
            let value = domain[key]
            let isSystem = key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple")
                || key.hasPrefix("AK") || key.hasPrefix("WebKit") || key.hasPrefix("METAL")
            return DefaultsRow(
                key: key,
                summary: storedValueSummary(value, forKey: key),
                isSystem: isSystem
            )
        }
        // This app's own settings first: they are the ones the promise is about.
        .sorted { ($0.isSystem ? 1 : 0, $0.key) < ($1.isSystem ? 1 : 0, $1.key) }
    }

    /// Every permission this app declares, taken from its own Info.plist.
    ///
    /// Driven by the bundle rather than by a list written here, so a
    /// permission added to the app is on this screen the moment it is added
    /// rather than the next time somebody remembers this file exists.
    private static func permissionRows() -> [PermissionRow] {
        let info = Bundle.main.infoDictionary ?? [:]
        var rows: [PermissionRow] = []

        // `rowKeys` drops the two usage descriptions another row already covers
        // in full — local network, which is reported from NSBonjourServices
        // because that key also names what is advertised, and Health's write
        // string, which exists only because iOS terminates an app that links
        // HealthKit without one.
        for key in DeclaredPermissions.rowKeys(in: info) {
            switch key {
            case "NSCalendarsFullAccessUsageDescription":
                rows.append(PermissionRow(
                    title: "Calendar",
                    infoKey: key,
                    state: state(for: EventAccess.authorization(for: .calendar)),
                    note: "Read only, only for the assistant on this phone, and never for a request that arrived over the network."
                ))
            case "NSRemindersFullAccessUsageDescription":
                rows.append(PermissionRow(
                    title: "Reminders",
                    infoKey: key,
                    state: state(for: EventAccess.authorization(for: .reminders)),
                    note: "Read only, only for the assistant on this phone, and never for a request that arrived over the network."
                ))
            case "NSHealthShareUsageDescription":
                rows.append(PermissionRow(
                    title: "Health",
                    infoKey: key,
                    state: HKHealthStore.isHealthDataAvailable() ? .neverReported : .unavailable,
                    // Not a limitation of this screen. HealthKit reports write
                    // authorization and refuses to report read authorization,
                    // deliberately, so that an app cannot tell "you denied me"
                    // apart from "you have no data of that type". No app can
                    // show you this, and one that claims to is guessing.
                    note: "iOS never tells an app whether its request to read Health was allowed, so this screen cannot show it. Health > Data Access & Devices > Pocketd has the truth."
                ))
            default:
                rows.append(PermissionRow(
                    title: DeclaredPermissions.title(forInfoKey: key),
                    infoKey: key,
                    state: .neverReported,
                    // Every other row's note explains its state, so this one
                    // does too rather than printing the App Store prompt copy
                    // where the explanation belongs. The declared reason
                    // follows it, because it is what the user was shown.
                    note: [
                        "This app declares this permission and nothing on this screen asks iOS for its state, so this screen will not claim one.",
                        info[key] as? String,
                    ]
                    .compactMap(\.self)
                    .joined(separator: " ")
                ))
            }
        }

        // Declared as a Bonjour service list rather than as a usage string, so
        // the loop above cannot find it — and it is the permission this app
        // depends on most.
        if let services = info["NSBonjourServices"] as? [String], !services.isEmpty {
            rows.append(PermissionRow(
                title: "Local network",
                infoKey: "NSBonjourServices",
                state: .neverReported,
                note: "iOS offers no way to ask whether local network access was allowed; an app finds out by being ignored. Advertised as \(services.joined(separator: " and ")) while the server is running."
            ))
        }
        return rows
    }

    private static func state(for authorization: PersonalDataAuthorization) -> PermissionState {
        switch authorization {
        case .granted: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        case .writeOnly: .addOnly
        }
    }

    // MARK: - Deleting

    /// Removes every conversation, including the ones the app cannot read.
    ///
    /// `ConversationStore.all()` deliberately skips a transcript that fails to
    /// decode, which is right — one bad file must not make the history
    /// unopenable — and it means the in-memory history is not the set of files
    /// on disk. Deleting only what the history knows about would leave real
    /// transcripts behind and report success.
    func deleteAllConversations(_ model: AppModel) async {
        // Cancels the debounced save first. Without it a write scheduled
        // before the delete lands after it and puts one conversation back.
        await model.flushConversation()
        // The sweep first, and the history loop after it. Every file, not only
        // the transcripts: `ConversationStore.save` writes atomically, which
        // stages a temp file beside the real one, and a process killed
        // mid-write leaves that remnant behind — counted in the size this
        // screen quotes and skipped by a loop over the readable history.
        //
        // Order is the whole fix. Running the history loop first removed every
        // readable transcript, so the listing taken afterwards found only what
        // that loop had missed and "freed" came out as zero for a delete that
        // freed megabytes.
        var freed: Int64 = 0
        if let directory = try? ConversationStore.defaultDirectory() {
            freed = DirectorySweep.emptyOfFiles(at: directory)
        }
        // Still needed with the files already gone: this is what clears the
        // transcript on screen and the in-memory history behind it.
        for id in model.history.map(\.id) {
            await model.deleteConversation(id)
        }
        await model.loadHistory()
        await finish(model, freed: freed)
    }

    /// Throws away the resume blobs and the part-files they point at.
    ///
    /// `ModelStore.discardPartial` removes the blob and leaves the bytes.
    /// `FileDownloader` uses a default session, so those bytes are a
    /// `CFNetworkDownload` file in this app's own `tmp` — a container pulled
    /// off a simulator still held a 178 MB one days after the download was
    /// abandoned. iOS empties `tmp` when the disk is under pressure, which is
    /// not the same as now and is not something a person can see or trigger.
    func deletePartialDownloads(_ model: AppModel) async {
        // A download in flight owns one of these files. Deleting it would kill
        // a transfer the user is watching, from a screen that has nothing to
        // do with downloads — and the transfer need not be one this phone
        // started, which is why the store is asked rather than the app.
        let downloading = await liveDownloadingIDs(model)
        guard let survey, downloading.isEmpty else { return }
        var freed: Int64 = 0
        for file in survey.area(.partialDownloads).files {
            let url = container.appendingPathComponent(file.path)
            freed += file.byteCount
            try? FileManager.default.removeItem(at: url)
        }
        await finish(model, freed: freed)
    }

    /// Removes one file nothing can load.
    ///
    /// Re-checked against live download state rather than trusted from the row.
    /// The row was measured the last time this screen walked the container, and
    /// a download for exactly that id can have started between that walk and
    /// this tap — at which point the "orphan" is the finished half of a
    /// multi-gigabyte transfer in progress.
    func deleteOrphan(_ orphan: OrphanRow, model: AppModel) async {
        let downloading = await liveDownloadingIDs(model)
        guard orphan.isStillAbandoned(downloadingIDs: downloading) else {
            await refresh(model)
            return
        }
        try? FileManager.default.removeItem(at: orphan.url)
        await finish(model, freed: orphan.file.byteCount)
    }

    /// Clears what the system's HTTP client kept, through the system's own API.
    ///
    /// Deleting the sqlite files behind `URLCache`'s back would corrupt a store
    /// the process has open. The bytes on disk may therefore not fall to zero
    /// immediately, and this screen says so rather than showing a number that
    /// did not move and hoping nobody looks twice.
    func clearNetworkCache(_ model: AppModel) async {
        let before = survey?.area(.networkCache).tally.byteCount ?? 0
        URLCache.shared.removeAllCachedResponses()
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        await refresh(model)
        let after = survey?.area(.networkCache).tally.byteCount ?? 0
        lastFreed = Self.formatted(max(0, before - after))
    }

    /// Runs every delete this screen can perform, and reports what the whole
    /// sequence actually freed.
    ///
    /// The total is the difference in the container's own size rather than the
    /// sum of what each step believed it removed. On a screen whose argument is
    /// that its numbers are measured, the number the button leaves behind has
    /// to be measured too.
    func deleteEverythingDeletable(_ model: AppModel) async {
        let before = survey?.totalBytes ?? 0
        await deleteAllConversations(model)
        for row in models { await model.delete(row.record) }
        // The same guard the single-file delete uses, for the same reason: an
        // unmanifested `<id>.gguf` is what a vision model looks like while its
        // projector is still arriving, and this loop used to remove it without
        // asking — from the button labelled "free up space", with the download
        // still running.
        let downloading = await liveDownloadingIDs(model)
        for orphan in orphanedModelFiles where orphan.isStillAbandoned(downloadingIDs: downloading) {
            try? FileManager.default.removeItem(at: orphan.url)
        }
        if downloading.isEmpty, let partial = survey?.area(.partialDownloads) {
            for file in partial.files {
                try? FileManager.default.removeItem(at: container.appendingPathComponent(file.path))
            }
        }
        URLCache.shared.removeAllCachedResponses()
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        await refresh(model)
        lastFreed = Self.formatted(max(0, before - (survey?.totalBytes ?? 0)))
    }

    /// Deletes one model and says what that freed.
    ///
    /// A wrapper rather than two lines at the call site because this was the
    /// only delete on this screen that never wrote `lastFreed`: the green line
    /// from whatever ran before it stayed on screen and read as the result of
    /// this delete, directly under a total that had just dropped by a
    /// different number.
    ///
    /// Measured as the container's own difference, like the two other deletes
    /// that cannot simply sum what they removed. The row's bytes are not the
    /// whole change: `ModelStore.delete` also takes the resume blob beside the
    /// weights and rewrites the manifest.
    func deleteModel(_ record: ModelRecord, model: AppModel) async {
        let before = survey?.totalBytes ?? 0
        await model.delete(record)
        await refresh(model)
        lastFreed = Self.formatted(max(0, before - (survey?.totalBytes ?? 0)))
    }

    func regenerateAPIKey(_ model: AppModel) async {
        var updated = model.configuration
        updated.apiKey = ServerConfiguration.generateAPIKey()
        await model.applyConfiguration(updated)
        await refresh(model)
        lastFreed = nil
    }

    private func finish(_ model: AppModel, freed: Int64) async {
        await refresh(model)
        lastFreed = Self.formatted(freed)
    }

    /// The same formatter the sentences in `DeletionNarrative` use, so the
    /// figure in a row and the figure in the footer beneath it cannot disagree.
    static func formatted(_ bytes: Int64) -> String {
        formattedByteCount(bytes)
    }

    // MARK: - Totals

    /// What "delete everything" would remove if it ran right now.
    ///
    /// Takes the model because the answer depends on live download state, and
    /// that is the whole point: the footer and the delete read the same value,
    /// so the dialog cannot quote bytes the button then skips.
    func deletionPlan(_ model: AppModel) -> DeletionPlan {
        let downloading = downloadingIDs(model)
        return DeletionPlan.deleteEverything(
            // The model rows, not the models directory: the directory also
            // holds the manifest, which is rewritten rather than removed, and
            // any download in flight, which has no manifest entry to delete
            // through.
            installedModelBytes: models.reduce(0) { $0 + $1.totalBytes },
            orphanBytes: orphanedModelFiles
                .filter { $0.isStillAbandoned(downloadingIDs: downloading) }
                .reduce(0) { $0 + $1.file.byteCount },
            conversationBytes: conversations.byteCount,
            partialDownloadBytes: survey?.area(.partialDownloads).tally.byteCount ?? 0,
            networkCacheBytes: survey?.area(.networkCache).tally.byteCount ?? 0,
            downloadInFlight: !downloading.isEmpty
        )
    }

    /// Areas iOS owns outright. The preferences file is deliberately not here:
    /// it has a section of its own, because the interesting thing about it is
    /// what is inside rather than how big it is.
    var systemOwnedAreas: [StoredDataArea] {
        guard let survey else { return [] }
        return survey.areas.filter { $0.kind.disposal.isSystemOwned && !$0.tally.isEmpty }
    }

    /// Bytes in this app's own container that this screen cannot name.
    ///
    /// Its own list rather than part of `systemOwnedAreas`, because it is not
    /// system-owned and saying so under a heading reading "Held by iOS" was a
    /// plain falsehood on a screen that is only worth shipping if every line
    /// of it is true.
    var unnamedAreas: [StoredDataArea] {
        guard let survey else { return [] }
        return survey.areas.filter {
            if case .unclassified = $0.kind.disposal { return !$0.tally.isEmpty }
            return false
        }
    }

    /// What survives a delete of everything, split by who is actually holding
    /// it, because "nothing inside this app can remove these" is true of one
    /// group and false of the other two.
    var survivesDeleteEverything: [StoredDataArea] {
        guard let survey else { return [] }
        return (systemOwnedAreas + unnamedAreas + [survey.area(.preferences)])
            .filter { !$0.tally.isEmpty }
    }
}
