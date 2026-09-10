import Observation
import PocketdKit
import SwiftUI

/// Searches Hugging Face for a GGUF and hands the chosen file to the downloader.
///
/// The curated catalogue is eight models that are known to load on a phone: the
/// right default and the wrong ceiling. PocketPal's whole Models screen is four
/// presets and a `+`, and that `+` is the entire difference between "some
/// models" and "any model on Hugging Face" — this is the `+`.
///
/// Present it as a sheet from the Models tab:
///
///     .sheet(isPresented: $isAdding) { ModelSearchView() }
///
/// It brings its own `NavigationStack` and its own Cancel button, and it
/// dismisses itself the moment a download starts, because the Models list
/// already renders progress and there is nothing left for this screen to say.
struct ModelSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var finder = RepositoryFinder()
    @State private var query = ""
    /// Bumped by Retry, and part of the task id so a retry runs down the same
    /// cancellable path as a keystroke. A loose `Task { }` would not be
    /// cancelled by the next keystroke and could land on top of it.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            List {
                if case let .results(repositories) = finder.phase {
                    Section {
                        ForEach(repositories) { repository in
                            // Gated repositories are deliberately listed and
                            // deliberately not links. Hiding them means someone
                            // searching for `gemma` concludes the search is
                            // broken; linking them means a 401 after the tap.
                            if repository.gated {
                                GatedRepositoryRow(repository: repository)
                            } else {
                                NavigationLink {
                                    RepositoryFilesView(repository: repository) { record, allowingOversized in
                                        model.download(record, allowingOversized: allowingOversized)
                                        dismiss()
                                    }
                                } label: {
                                    RepositoryRow(repository: repository)
                                }
                            }
                        }
                    } footer: {
                        Text("Most downloaded first. Popularity is the only quality signal Hugging Face offers, and a broken quantisation costs gigabytes to discover.")
                    }
                }
            }
            // The List stays the root view in every state so the search field
            // keeps its identity — swapping the root out from under `.searchable`
            // drops the keyboard mid-word.
            .overlay { status }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Add a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Hugging Face"
            )
            // Each keystroke replaces this task and SwiftUI cancels the one it
            // replaced, which buys the debounce and the ordering guarantee in
            // the same line: a slow answer for "qwe" cannot arrive after — and
            // overwrite — the answer for "qwen3".
            .task(id: SearchKey(query: query, attempt: attempt)) {
                await finder.search(query)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch finder.phase {
        case .prompt:
            ContentUnavailableView {
                Label("Find a model", systemImage: "magnifyingglass")
            } description: {
                Text("Type at least two characters. A family name works best — qwen3, llama, gemma, phi — or an author like unsloth.")
            }
        case .searching:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching Hugging Face…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case let .noMatches(term):
            // Distinct from the prompt above on purpose: "nothing matched" and
            // "you have not typed enough yet" look identical as a blank list,
            // and only one of them means you should try a different word.
            ContentUnavailableView {
                Label("No GGUF models for “\(term)”", systemImage: "magnifyingglass")
            } description: {
                Text("Only repositories that publish GGUF files appear here. Adding -gguf to the name, or searching the author who converted it, usually finds them.")
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
            }
        case .results:
            EmptyView()
        }
    }
}

// MARK: - Repository rows

private struct RepositoryRow: View {
    let repository: HuggingFaceSearch.Repository

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(repository.name)
                .font(.headline)
            Text(repository.owner)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(compactCount(repository.downloads)) downloads · \(compactCount(repository.likes)) likes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // Spelled out rather than "95K", which VoiceOver reads as a letter.
        .accessibilityLabel("\(repository.name) by \(repository.owner). \(repository.downloads.formatted()) downloads, \(repository.likes.formatted()) likes.")
    }
}

/// A repository that needs a Hugging Face token, which this app has no way to
/// supply. Shown, greyed, and inert: the download would 401 after the tap.
private struct GatedRepositoryRow: View {
    let repository: HuggingFaceSearch.Repository

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(repository.name)
                    .font(.headline)
                Spacer()
                Text("Needs sign-in")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.gray.opacity(0.15), in: Capsule())
            }
            Text(repository.owner)
                .font(.subheadline)
            Text("Gated on Hugging Face: downloading it needs an account and a token, which Pocketd cannot send. Look for a re-upload by another author.")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(repository.name) by \(repository.owner). Unavailable: gated on Hugging Face, which needs an account token this app cannot send.")
    }
}

// MARK: - Files in one repository

/// The GGUF files in a repository, one of which becomes a download.
///
/// Projector files are filtered out of the list rather than shown: an mmproj is
/// not a model, downloading one on its own produces something that cannot
/// answer anything, and it is already paired automatically with whatever
/// weights the user does pick. So it appears as a property of those weights —
/// a Vision badge and a bigger total — which is what it actually is.
private struct RepositoryFilesView: View {
    let repository: HuggingFaceSearch.Repository
    /// `allowingOversized` rides along so the caller can pass the same flag
    /// `AppModel.download` takes; the store refuses an oversized download
    /// otherwise, and the failure would surface on a screen the user has
    /// already been dismissed back to.
    let onAdd: (ModelRecord, Bool) -> Void

    @Environment(AppModel.self) private var model
    @State private var loader = FileLoader()
    @State private var attempt = 0
    @State private var oversizedCandidate: ModelRecord?

    var body: some View {
        List {
            if case let .ready(weights, projector) = loader.phase {
                Section {
                    ForEach(weights) { file in
                        row(for: file, projector: projector)
                    }
                } header: {
                    Text("GGUF files")
                } footer: {
                    guidance(projector: projector)
                }

                if let url = URL(string: "https://huggingface.co/\(repository.id)") {
                    Section {
                        Link("Model card on Hugging Face", destination: url)
                            .font(.callout)
                    } footer: {
                        // The catalogue writes "See the model card" into every
                        // record's licence field, so it had better be reachable.
                        Text("Licence, benchmarks and whether this model is any good all live there. Nothing on this screen can tell you that.")
                    }
                }
            }
        }
        .overlay { status }
        .navigationTitle(repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await loader.load(repository: repository.id) }
        .confirmationDialog(
            "This model is larger than this device can hold",
            isPresented: Binding(
                get: { oversizedCandidate != nil },
                set: { if !$0 { oversizedCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: oversizedCandidate
        ) { record in
            Button("Download anyway", role: .destructive) {
                onAdd(record, true)
                oversizedCandidate = nil
            }
            Button("Cancel", role: .cancel) { oversizedCandidate = nil }
        } message: { record in
            Text("\(record.displayName) needs about \(format(record.estimatedResidentBytes)) resident and iOS allows this app roughly \(format(model.budget.usableBytes)). It will most likely be killed while loading.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch loader.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading \(repository.id)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case let .empty(message):
            ContentUnavailableView {
                Label("Nothing to download here", systemImage: "shippingbox")
            } description: {
                Text(message)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Could not read this repository", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func row(for file: HuggingFaceSearch.File, projector: HuggingFaceSearch.File?) -> some View {
        let record = record(for: file, projector: projector)
        let installed = model.isInstalled(record)
        let downloading = model.downloads[record.id] != nil

        Button {
            // The fit number is a heuristic, so it warns rather than forbids —
            // the same bargain the Models tab strikes.
            if model.fit(for: record).allowsDownload {
                onAdd(record, false)
            } else {
                oversizedCandidate = record
            }
        } label: {
            FileRow(
                file: file,
                record: record,
                fit: model.fit(for: record),
                state: installed ? .installed : (downloading ? .downloading : .available)
            )
        }
        .buttonStyle(.plain)
        // Offering Download for something already on the phone is how you get a
        // second copy of two gigabytes.
        .disabled(installed || downloading)
    }

    /// The context length is the server's cap rather than anything Hugging Face
    /// said, because the API does not report a window and the served context is
    /// capped there anyway. Same choice `/api/models/add` makes.
    private func record(for file: HuggingFaceSearch.File, projector: HuggingFaceSearch.File?) -> ModelRecord {
        HuggingFaceSearch.record(
            repository: repository.id,
            file: file,
            projector: projector,
            contextLength: model.configuration.maxContextTokens
        )
    }

    private func guidance(projector: HuggingFaceSearch.File?) -> Text {
        // Eight files whose names differ by three characters is the point where
        // a first-time user gives up, so the steer goes next to the choice.
        var text = Text("Q4_K_M is the usual first choice. A higher Q number keeps more of the original model and costs proportionally more memory; F16 is the unquantised weights and is several times larger than a phone should load.")
        if let projector {
            text = text + Text("\n\nThis repository ships a vision projector (\(format(projector.sizeBytes))). It is downloaded and paired automatically — without it a vision model loads and then cannot see — and it is counted in the sizes above.")
        }
        return text
    }
}

private struct FileRow: View {
    enum State {
        case available
        case installed
        case downloading
    }

    let file: HuggingFaceSearch.File
    let record: ModelRecord
    let fit: DeviceBudget.Fit
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .font(.headline)
                        if record.declaredCapabilities.vision.isYes {
                            Label("Vision", systemImage: "eye")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    // The total, not the weights alone: a paired projector is
                    // another few hundred megabytes, on disk and resident.
                    Text("\(file.quantization) · \(format(record.totalDownloadBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                badge
            }

            switch state {
            case .installed:
                Label("Already on this phone", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .downloading:
                Label("Downloading — see the Models tab", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .available:
                if file.quantization == "Q4_K_M" {
                    Text("Usual default")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(state == .available ? "Downloads this file and returns to the models list." : "")
    }

    @ViewBuilder
    private var badge: some View {
        switch fit {
        case .comfortable:
            Text("Fits").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
                .accessibilityLabel("Fits comfortably in memory")
        case .tight:
            Text("Tight").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
                .accessibilityLabel("Tight fit — little room left for a long conversation")
        case .willNotFit:
            Text("Too large").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red.opacity(0.15), in: Capsule())
                .accessibilityLabel("Too large for this device")
        }
    }

    private var accessibilityLabel: String {
        var parts = [record.displayName, "quantisation \(file.quantization)", format(record.totalDownloadBytes)]
        if record.declaredCapabilities.vision.isYes { parts.append("vision, projector included") }
        switch state {
        case .installed: parts.append("already on this phone")
        case .downloading: parts.append("downloading")
        case .available: break
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - State

/// Repository search, and the reason results never arrive out of order.
@MainActor
@Observable
private final class RepositoryFinder {
    enum Phase {
        /// Nothing worth searching for has been typed yet.
        case prompt
        case searching
        case results([HuggingFaceSearch.Repository])
        case noMatches(String)
        case failed(String)
    }

    private(set) var phase: Phase = .prompt

    func search(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same floor `/api/search` enforces: one character matches half of
        // Hugging Face and none of it usefully.
        guard query.count >= 2 else {
            phase = .prompt
            return
        }

        // Spelling "qwen3" is five requests without this, four of them thrown
        // away. The sleep is cancelled along with the task, so a fast typist
        // pays for nothing.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        phase = .searching
        do {
            let found = try await HuggingFaceClient.shared.repositories(matching: query)
            phase = found.isEmpty ? .noMatches(query) : .results(found)
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(searchMessage(for: error))
        }
    }
}

/// The GGUF files in one repository.
@MainActor
@Observable
private final class FileLoader {
    enum Phase {
        case loading
        /// Weights the user can pick, plus the projector that will be paired
        /// with whichever one they pick.
        case ready(weights: [HuggingFaceSearch.File], projector: HuggingFaceSearch.File?)
        case empty(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    func load(repository: String) async {
        phase = .loading
        do {
            let files = try await HuggingFaceClient.shared.files(in: repository)
            let projector = files.first { $0.isProjector }
            let weights = files.filter { !$0.isProjector }
            if weights.isEmpty {
                phase = .empty(projector == nil
                               ? "\(repository) has no GGUF files. It is probably the original weights, and someone else has converted them — search for the same name with -gguf."
                               : "\(repository) publishes a vision projector but no weights to pair it with. The projector is only useful alongside a model from another repository.")
            } else {
                phase = .ready(weights: weights, projector: projector)
            }
        } catch {
            guard !isCancellation(error) else { return }
            phase = .failed(searchMessage(for: error))
        }
    }
}

// MARK: - Shared plumbing

/// One client for the screen, with a request timeout short enough that a dead
/// network fails visibly. URLSession's default is sixty seconds, which on a
/// phone is indistinguishable from a spinner that never stops. Ephemeral
/// because there is no reason for what someone searched for to outlive the
/// search on a device whose entire premise is that nothing leaves it.
private enum HuggingFaceClient {
    static let shared: HuggingFaceSearch = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return HuggingFaceSearch(session: URLSession(configuration: configuration))
    }()
}

/// Identity for `.task(id:)`: the query plus a retry counter, so Retry re-runs
/// the same cancellable task rather than starting an unmanaged one.
private struct SearchKey: Equatable {
    let query: String
    let attempt: Int
}

/// URLSession reports a cancelled request as a thrown `URLError`, not as
/// `CancellationError`, and a request cancelled because the user kept typing is
/// not a failure worth showing them.
private func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? URLError, error.code == .cancelled { return true }
    return false
}

/// Deliberately fixed strings. A URL error's `userInfo` carries the signed CDN
/// URL and the whole resume blob, so `String(describing:)` on one of these ends
/// up on screen — that has happened here before.
private func searchMessage(for error: any Error) -> String {
    if let error = error as? HuggingFaceSearch.SearchError {
        switch error {
        case .httpStatus(429):
            return "Hugging Face is rate-limiting this device. Wait a minute and try again."
        case let .httpStatus(code) where code == 401 || code == 403:
            return "Hugging Face refused the request (\(code)). That repository needs an account token, which Pocketd cannot send."
        case let .httpStatus(code):
            return "Hugging Face answered \(code)."
        case .malformed:
            return "Hugging Face sent a response this build could not read."
        }
    }
    if let error = error as? URLError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "This iPhone is offline. Finding a model needs the internet, even though running one does not."
        case .timedOut:
            return "Hugging Face did not answer within fifteen seconds."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not resolve huggingface.co. Check the network this iPhone is on."
        default:
            return "Could not reach Hugging Face."
        }
    }
    return "Could not reach Hugging Face."
}

private func compactCount(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
}

private func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Previews

#if DEBUG
#Preview("Search") {
    ModelSearchView()
        .environment(AppModel())
}

#Preview("Rows") {
    List {
        Section {
            RepositoryRow(repository: .sample(id: "unsloth/Qwen3-1.7B-GGUF", downloads: 95226, likes: 412))
            GatedRepositoryRow(repository: .sample(id: "google/gemma-3-4b-it-qat-GGUF", downloads: 1_204_233, likes: 981, gated: true))
        }
        Section {
            FileRow(
                file: .sample(path: "Qwen3-1.7B-Q4_K_M.gguf", sizeBytes: 1_117_000_000),
                record: HuggingFaceSearch.record(
                    repository: "unsloth/Qwen3-1.7B-GGUF",
                    file: .sample(path: "Qwen3-1.7B-Q4_K_M.gguf", sizeBytes: 1_117_000_000)
                ),
                fit: .comfortable,
                state: .available
            )
            FileRow(
                file: .sample(path: "Qwen3-1.7B-Q8_0.gguf", sizeBytes: 2_030_000_000),
                record: HuggingFaceSearch.record(
                    repository: "unsloth/Qwen3-1.7B-GGUF",
                    file: .sample(path: "Qwen3-1.7B-Q8_0.gguf", sizeBytes: 2_030_000_000)
                ),
                fit: .tight,
                state: .installed
            )
        }
    }
}

// The two API types have no public initialiser outside PocketdKit, so a sample
// arrives the same way a real one does: decoded from the shape Hugging Face
// sends.
private extension HuggingFaceSearch.Repository {
    static func sample(id: String, downloads: Int, likes: Int, gated: Bool = false) -> Self {
        let json = #"{"id":"\#(id)","downloads":\#(downloads),"likes":\#(likes),"gated":\#(gated)}"#
        return try! JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

private extension HuggingFaceSearch.File {
    static func sample(path: String, sizeBytes: Int64) -> Self {
        let json = #"{"path":"\#(path)","sizeBytes":\#(sizeBytes)}"#
        return try! JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
#endif
