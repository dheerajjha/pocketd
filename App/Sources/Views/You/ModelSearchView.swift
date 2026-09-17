import Observation
import PocketdKit
import SwiftUI

/// Searching Hugging Face for a brain that is not on the curated list.
///
/// The catalogue is eight things known to load on a phone: the right default
/// and the wrong ceiling. This screen is the difference between "some brains"
/// and "any brain anyone has published", and it is deliberately one level down
/// — nobody arrives at a new assistant wanting to browse a model hub.
///
/// The search box is the screen's own rather than `.searchable`, because these
/// screens have no navigation bar for the system one to live in, and a search
/// field that appears and disappears with a scroll is the wrong shape for the
/// only control on the page.
struct ModelSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var finder = RepositoryFinder()
    @State private var query = ""
    /// Bumped by Retry, and part of the task id so a retry runs down the same
    /// cancellable path as a keystroke. A loose `Task { }` would not be
    /// cancelled by the next keystroke and could land on top of it.
    @State private var attempt = 0
    @State private var chosen: HuggingFaceSearch.Repository?
    @FocusState private var searching: Bool

    var body: some View {
        YouDetailScreen(
            title: "Add a brain",
            subtitle: "Anything published as a phone-sized file can run here. A family name works best, or the name of whoever converted it."
        ) {
            searchField
            results
        }
        .task(id: SearchKey(query: query, attempt: attempt)) {
            await finder.search(query)
        }
        #if DEBUG
        .onAppear {
            // A screenshot run arrives with something already typed. See
            // `YouStage`; both this and the type are inside `#if DEBUG`.
            if let staged = YouStage.searchQuery, query.isEmpty { query = staged }
        }
        #endif
        .sheet(item: $chosen) { repository in
            RepositoryFilesView(repository: repository) { record, allowingOversized in
                model.download(record, allowingOversized: allowingOversized)
                chosen = nil
                // Back to Brain, where the download is already drawing itself.
                // There is nothing left for this screen to say.
                dismiss()
            }
        }
    }

    // MARK: - The box

    private var searchField: some View {
        HStack(spacing: PDSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.pd.inkSecondary)
            TextField("Search", text: $query)
                .font(Font.pd.body)
                .foregroundStyle(Color.pd.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searching)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.pd.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, PDSpacing.m)
        .frame(height: PDMetric.askBarHeight)
        .background(Color.pd.chip, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
    }

    // MARK: - What came back

    @ViewBuilder
    private var results: some View {
        switch finder.phase {
        case .prompt:
            EmptyCard(
                symbol: "magnifyingglass",
                title: "Type at least two letters.",
                detail: "A family name works best — qwen3, llama, gemma, phi — or the name of whoever converted it."
            )
        case .searching:
            EmptyCard(
                symbol: "ellipsis",
                title: "Looking.",
                detail: "Searching what has been published."
            )
        case let .noMatches(term):
            // Distinct from the prompt on purpose: "nothing matched" and "you
            // have not typed enough yet" look identical as a blank list, and
            // only one of them means try a different word.
            EmptyCard(
                symbol: "questionmark.circle",
                title: "Nothing for “\(term)”.",
                detail: "Only what is published in a phone-ready format shows up here. Adding -gguf to the name, or searching whoever converted it, usually finds it."
            )
        case let .failed(message):
            EmptyCard(symbol: "wifi.exclamationmark", title: "That did not work.", detail: message) {
                PillButton(title: "Try again", symbol: "arrow.clockwise") { attempt += 1 }
            }
        case let .results(repositories):
            YouSection(
                "MOST DOWNLOADED FIRST",
                footnote: "Popularity is the only quality signal available here, and a broken conversion costs gigabytes to discover."
            ) {
                ForEach(Array(repositories.enumerated()), id: \.element.id) { index, repository in
                    if index > 0 { RowDivider(inset: 0) }
                    repositoryRow(repository)
                }
            }
        }
    }

    @ViewBuilder
    private func repositoryRow(_ repository: HuggingFaceSearch.Repository) -> some View {
        // Gated repositories are deliberately listed and deliberately inert.
        // Hiding them means somebody searching for a well-known name concludes
        // the search is broken; linking them means a refusal after the tap.
        if repository.gated {
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                HStack {
                    Text(repository.name)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.inkSecondary)
                    Spacer(minLength: PDSpacing.xs)
                    StatusPill(.neutral, "Needs sign-in")
                }
                Text(repository.owner)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                Text("This one is behind an account. Pocketd has no account to sign in with — look for a copy published by somebody else.")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, PDSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(repository.name) by \(repository.owner). Unavailable: behind an account this app cannot sign in to.")
        } else {
            NavRow(
                title: repository.name,
                detail: "\(repository.owner) · \(compactCount(repository.downloads)) downloads"
            ) {
                searching = false
                chosen = repository
            }
            // Spelled out rather than "95K", which VoiceOver reads as a letter.
            .accessibilityLabel("\(repository.name) by \(repository.owner). \(repository.downloads.formatted()) downloads, \(repository.likes.formatted()) likes.")
        }
    }
}

// MARK: - Files in one repository

/// The phone-ready files in one repository, one of which becomes a download.
///
/// A sheet rather than a push: the You tab's stack is typed, and this is a
/// choice made and finished in one go — you pick a size, it starts, and you are
/// back where you were.
///
/// Projector files are filtered out rather than shown: one is not a brain,
/// downloading it alone produces something that cannot answer anything, and it
/// is paired automatically with whatever weights you do pick. So it appears as
/// a property of those weights — a bigger total — which is what it is.
private struct RepositoryFilesView: View {
    let repository: HuggingFaceSearch.Repository
    /// `allowingOversized` rides along so the caller can pass the same flag
    /// `AppModel.download` takes; the store refuses an oversized download
    /// otherwise, and the failure would surface on a screen the user has
    /// already been dismissed back to.
    let onAdd: (ModelRecord, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var loader = FileLoader()
    @State private var attempt = 0
    @State private var oversized: ModelRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                VStack(alignment: .leading, spacing: PDSpacing.xs) {
                    Text(repository.name)
                        .font(Font.pd.titleDetail)
                        .foregroundStyle(Color.pd.ink)
                    Text("Published by \(repository.owner)")
                        .pdSubtitle()
                }
                .padding(.top, PDSpacing.s)

                content
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.bottom, PDSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .pdCanvas()
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await loader.load(repository: repository.id) }
        .confirmationDialog(
            "This one is larger than this phone can hold",
            isPresented: Binding(get: { oversized != nil }, set: { if !$0 { oversized = nil } }),
            titleVisibility: .visible,
            presenting: oversized
        ) { record in
            Button("Download anyway", role: .destructive) {
                onAdd(record, true)
                oversized = nil
            }
            Button("Cancel", role: .cancel) { oversized = nil }
        } message: { record in
            Text("\(record.displayName) needs about \(pdBytes(record.estimatedResidentBytes)) of memory and iOS allows this app roughly \(pdBytes(model.budget.usableBytes)). It will most likely be stopped while loading.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.phase {
        case .loading:
            EmptyCard(symbol: "ellipsis", title: "Reading it.", detail: "Listing what this one publishes.")
        case let .empty(message):
            EmptyCard(symbol: "shippingbox", title: "Nothing to download here.", detail: message)
        case let .failed(message):
            EmptyCard(symbol: "wifi.exclamationmark", title: "Could not read it.", detail: message) {
                PillButton(title: "Try again", symbol: "arrow.clockwise") { attempt += 1 }
            }
        case let .ready(weights, projector):
            YouSection("SIZES", footnote: guidance(projector: projector)) {
                ForEach(Array(weights.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { RowDivider(inset: 0) }
                    row(for: file, projector: projector)
                }
            }
            if let url = URL(string: "https://huggingface.co/\(repository.id)") {
                YouSection(
                    "WORTH KNOWING",
                    footnote: "Licence, benchmarks and whether this one is any good all live on its own page. Nothing on this screen can tell you that."
                ) {
                    LinkRow(symbol: "doc.text", title: "Its page", detail: repository.id) {
                        openURL(url)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for file: HuggingFaceSearch.File, projector: HuggingFaceSearch.File?) -> some View {
        let record = record(for: file, projector: projector)
        let fit = model.fit(for: record)
        let installed = model.isInstalled(record)
        let downloading = model.transfer(for: record.id)?.isActive == true

        Button {
            Haptics.tap()
            // The fit number is a heuristic, so it warns rather than forbids —
            // the same bargain Brain strikes.
            if fit.allowsDownload {
                onAdd(record, false)
            } else {
                oversized = record
            }
        } label: {
            RowShell(
                title: file.quantization,
                detail: pdDownloadLine(record.totalDownloadBytes)
            ) {
                if installed {
                    StatusPill(.positive, "On this phone")
                } else if downloading {
                    StatusPill(.neutral, "Getting it")
                } else {
                    StatusPill(pdFitPill(fit).kind, pdFitPill(fit).text)
                }
            }
        }
        .buttonStyle(.plain)
        // Offering a download for something already on the phone is how you get
        // a second copy of two gigabytes.
        .disabled(installed || downloading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(file: file, record: record, fit: fit, installed: installed, downloading: downloading))
    }

    private func label(
        file: HuggingFaceSearch.File,
        record: ModelRecord,
        fit: DeviceBudget.Fit,
        installed: Bool,
        downloading: Bool
    ) -> String {
        var parts = [file.quantization, pdBytes(record.totalDownloadBytes), pdFitWords(fit)]
        if installed { parts.append("already on this phone") }
        if downloading { parts.append("downloading") }
        return parts.joined(separator: ", ")
    }

    /// The context length is the server's cap rather than anything the API
    /// said, because it does not report a window and the served context is
    /// capped there anyway.
    private func record(for file: HuggingFaceSearch.File, projector: HuggingFaceSearch.File?) -> ModelRecord {
        HuggingFaceSearch.record(
            repository: repository.id,
            file: file,
            projector: projector,
            contextLength: model.configuration.maxContextTokens
        )
    }

    /// Eight files whose names differ by three characters is where a first-time
    /// reader gives up, so the steer goes next to the choice.
    private func guidance(projector: HuggingFaceSearch.File?) -> String {
        var text = "Q4_K_M is the usual first choice. A higher number keeps more of the original and costs proportionally more memory; F16 is the unshrunk version and is several times larger than a phone should load."
        if let projector {
            text += " This one also ships an image part (\(pdBytes(projector.sizeBytes))). It is downloaded and paired automatically, and it is counted in the sizes above."
        }
        return text
    }
}

// MARK: - An empty state that sells rather than shrugs

/// A card that says what happened and what to do about it.
///
/// Not `ContentUnavailableView`: that one centres a grey glyph in the middle of
/// an empty screen, which on a page with a search box at the top leaves the
/// answer a long way from the question.
struct EmptyCard<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                IconTile(symbol: symbol)
                Text(title)
                    .font(Font.pd.headline)
                    .foregroundStyle(Color.pd.ink)
                Text(detail)
                    .pdBody()
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

extension EmptyCard where Actions == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
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
        // the hub and none of it usefully.
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

/// The phone-ready files in one repository.
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
                               ? "\(repository) publishes nothing a phone can load. It is probably the original, and somebody else has converted it — search for the same name with -gguf."
                               : "\(repository) publishes only the image half, with no brain to pair it with. That half is useful alongside weights from somewhere else.")
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
/// because there is no reason for what somebody searched for to outlive the
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
            return "The hub is rate-limiting this phone. Wait a minute and try again."
        case let .httpStatus(code) where code == 401 || code == 403:
            return "The hub refused the request (\(code)). That one needs an account, which Pocketd does not have."
        case let .httpStatus(code):
            return "The hub answered \(code)."
        case .malformed:
            return "The hub sent something this build could not read."
        }
    }
    if let error = error as? URLError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "This iPhone is offline. Finding a brain needs the internet, even though running one does not."
        case .timedOut:
            return "No answer within fifteen seconds."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not resolve huggingface.co. Check the network this iPhone is on."
        default:
            return "Could not reach huggingface.co."
        }
    }
    return "Could not reach huggingface.co."
}

private func compactCount(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
}

// MARK: - Previews

#Preview("Add a brain light") {
    NavigationStack { ModelSearchView() }
        .environment(AppModel())
        .environment(Navigator())
}

#Preview("Add a brain dark") {
    NavigationStack { ModelSearchView() }
        .environment(AppModel())
        .environment(Navigator())
        .preferredColorScheme(.dark)
}
