import PocketdKit
import SwiftUI
import UIKit

/// Brain: how Pocketd thinks, as one choice between two good options.
///
/// Built into iPhone — Apple Intelligence, nothing to download — and a private
/// download that works on any iPhone. One card each, one button each, and the
/// one in use says so. This page used to be eight brains in four sections with
/// amber warnings on most of them, and three different recommendations; now
/// the recommendation is one (`BrainRecommendation`), it always reads the day,
/// and everything else is one tap further down under More brains.
///
/// Loading is not a step anybody takes. Choosing a brain puts it in memory;
/// the app lets it go and brings it back on its own. There is no Unload here
/// and no "tap the name to load it".
struct BrainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(\.openURL) private var openURL

    var body: some View {
        YouDetailScreen(
            title: "Brain",
            subtitle: "Pocketd thinks on this iPhone. Nothing you ask leaves it."
        ) {
            if let current = otherDownloadInUse {
                inUseCard(current)
            }
            if model.builtInOffer.isListed {
                builtInCard
            }
            downloadCard
            builtInNote
            PDCard(padding: PDSpacing.m) {
                NavRow(symbol: "square.stack", title: "More brains") {
                    navigator.push(.addBrain)
                }
            }
        }
    }

    // MARK: - Built into iPhone

    private var builtInCard: some View {
        let offer = model.builtInOffer
        let inUse = model.isUsingBuiltInBrain
        return BrainCard(
            symbol: "sparkles",
            title: BuiltInBrainOffer.title,
            detail: offer.detail ?? BuiltInBrainOffer.readyDetail,
            accessory: inUse
                ? .inUse
                : .action("Use this", symbol: BrainCardAccessory.useSymbol) {
                    Task { await model.useBuiltInBrain() }
                }
        )
    }

    /// The one quiet line for a phone that could run Apple's model but cannot
    /// right now — off in Settings, or not in this language. Nothing at all
    /// for a phone that never could: a disabled option is a promise that
    /// cannot be kept.
    @ViewBuilder
    private var builtInNote: some View {
        let offer = model.builtInOffer
        if !offer.isListed, let footnote = offer.footnote {
            VStack(alignment: .leading, spacing: 0) {
                Text(footnote)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = offer.settingsAction {
                    // iOS has no link to the Apple Intelligence pane; this
                    // opens Settings, which is as far as an app may go.
                    TextLink(action, symbol: "arrow.up.right") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            .padding(.horizontal, PDSpacing.xxs)
        }
    }

    // MARK: - Private download

    /// The download this phone uses or should get.
    ///
    /// The one in use when it reads the day; else one already here that does;
    /// else THE recommendation. Never a second recommendation to someone who
    /// already has a brain that reads the day — that is how a phone holding
    /// three brains was once offered a fourth.
    private var downloadSubject: ModelRecord? {
        if let current = currentDownload, readsYourDay(current) { return current }
        if let here = installedRecords.first(where: { readsYourDay($0) }) { return here }
        return BrainRecommendation.recommended(for: model.budget)
    }

    @ViewBuilder
    private var downloadCard: some View {
        if let record = downloadSubject {
            BrainCard(
                symbol: "arrow.down.circle",
                title: "Private download",
                detail: "\(downloadPromise) · \(pdBytes(record.totalDownloadBytes))",
                note: downloadNote(record),
                accessory: accessory(for: record)
            ) {
                BrainTransferStatus(record: record)
            }
        } else {
            // Nothing that reads the day fits this phone. Said once, plainly;
            // a chat-only brain is never offered as the consolation.
            BrainCard(
                symbol: "arrow.down.circle",
                title: "Private download",
                detail: "None of Pocketd's brains fit on this iPhone yet.",
                accessory: .none
            )
        }
    }

    /// "Qwen3 1.7B · Reads your day", and "· Tight fit" exactly where More
    /// brains says it: on a small phone the recommendation can be the only
    /// brain that reads the day and still only just fit, and the two pages
    /// must not disagree about the same brain.
    private func downloadNote(_ record: ModelRecord) -> String {
        var parts = [record.displayName, dayAccess(of: record).label]
        if model.fit(for: record) == .tight { parts.append(pdFitWords(.tight)) }
        return parts.joined(separator: " · ")
    }

    /// "Works on any iPhone, even with Apple Intelligence off" only where
    /// Apple Intelligence is the other card; otherwise the plain promise.
    private var downloadPromise: String {
        model.builtInOffer.isListed
            ? "Works on any iPhone, even with Apple Intelligence off"
            : "Downloads once, then works with no signal"
    }

    private func accessory(for record: ModelRecord) -> BrainCardAccessory {
        let inUse = !model.isUsingBuiltInBrain && model.effectiveBrain == .downloaded(id: record.id)
        if model.loadingModelID == record.id { return .status("Getting ready") }
        if inUse { return .inUse }
        if model.isInstalled(record) {
            return .action("Use this", symbol: BrainCardAccessory.useSymbol) {
                Task { await model.useDownloadedBrain(id: record.id) }
            }
        }
        switch model.transfer(for: record.id)?.state {
        case .waiting?, .running?, .stopping?:
            return .none
        case .paused?:
            return .action("Resume", symbol: "arrow.down") { model.download(record) }
        case .failed?:
            return .action("Try again", symbol: "arrow.clockwise") { model.download(record) }
        case .finished?, nil:
            return .action("Download", symbol: "arrow.down") { model.download(record) }
        }
    }

    // MARK: - A download in use that cannot read the day

    /// The brain answering now, when it is a download the cards above do not
    /// show — a chat-only one kept from an earlier version. Shown first and
    /// plainly, so the two cards below read as the way out.
    private var otherDownloadInUse: ModelRecord? {
        guard let current = currentDownload, current.id != downloadSubject?.id else { return nil }
        return current
    }

    private func inUseCard(_ record: ModelRecord) -> some View {
        BrainCard(
            symbol: "bubble.left",
            title: record.displayName,
            detail: readsYourDay(record) ? DayAccess.readsYourDay.label : "Chat only — can't read your day",
            accessory: model.loadingModelID == record.id ? .status("Getting ready") : .inUse
        )
    }

    // MARK: - Facts

    /// The download answering the phone, from the catalogue (which knows its
    /// name and what it can do).
    private var currentDownload: ModelRecord? {
        guard !model.isUsingBuiltInBrain, case let .downloaded(id)? = model.effectiveBrain else { return nil }
        return model.catalog.first { $0.id == id }
    }

    private var installedRecords: [ModelRecord] {
        model.installed.compactMap { record in model.catalog.first { $0.id == record.id } ?? record }
    }

    /// The engine's verdict for the brain in memory, the catalogue's for the
    /// rest — the same rule `BrainStatus` uses.
    private func dayAccess(of record: ModelRecord) -> DayAccess {
        record.dayAccess(resident: model.loadedModelID == record.id ? model.personalDataToolGate : nil)
    }

    private func readsYourDay(_ record: ModelRecord) -> Bool {
        dayAccess(of: record).readsYourDay
    }
}

// MARK: - A card for one brain

/// What a brain card offers: one thing, or a word saying why there is none.
enum BrainCardAccessory {
    /// The glyph on "Use" / "Use this": switching, not a tick. A check circle
    /// on a button reads as "already chosen", beside a card that says "✓ In
    /// use" for the one that is.
    static let useSymbol = "arrow.left.arrow.right"

    /// ✓ In use. Words, not a button: there is nothing to do to it.
    case inUse
    /// A state with no action — "Getting ready".
    case status(String)
    /// One small pill.
    case action(String, symbol: String, () -> Void)
    case none
}

/// A brain as a choice: a tile, a name, a grey line, and one thing to do.
///
/// A state — "✓ In use", "Getting ready" — sits on the name's line while the
/// name fits beside it, and drops under it when it does not. A button goes
/// under the words, where the grey line can use the card's whole width: beside
/// it, "Apple Intelligence · Nothing to download · Ready" broke into three
/// short lines on a phone held at the default text size.
struct BrainCard<Footer: View>: View {
    let symbol: String
    let title: String
    let detail: String
    /// A second, quieter line: which brain, and whether it reads the day.
    var note: String?
    let accessory: BrainCardAccessory
    @ViewBuilder var footer: Footer

    var body: some View {
        PDCard {
            HStack(alignment: .top, spacing: PDSpacing.s) {
                IconTile.small(symbol)
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        Text(pdSeparated(detail))
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note {
                            Text(pdSeparated(note))
                                .font(Font.pd.footnote)
                                .foregroundStyle(Color.pd.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if case let .action(title, symbol, action) = accessory {
                        PillButton(title: title, symbol: symbol, action: action)
                            // The pill's 44pt target overhangs the words
                            // above rather than pushing the card taller.
                            .padding(.vertical, -PDSpacing.xxs)
                    }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleText: some View {
        Text(title)
            .font(Font.pd.headline)
            .foregroundStyle(Color.pd.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var titleLine: some View {
        switch accessory {
        case .inUse:
            AccessoryRowLayout(spacing: PDSpacing.s) {
                titleText
                HStack(spacing: PDSpacing.xxs) {
                    Image(systemName: "checkmark")
                        .font(Font.pd.tick)
                    Text("In use")
                        .font(Font.pd.secondary.weight(.semibold))
                }
                .foregroundStyle(Color.pd.positive)
                .accessibilityElement(children: .combine)
            }
        case let .status(text):
            AccessoryRowLayout(spacing: PDSpacing.s) {
                titleText
                Text(text)
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.inkSecondary)
            }
        case .action, .none:
            titleText
        }
    }
}

extension BrainCard where Footer == EmptyView {
    init(symbol: String, title: String, detail: String, note: String? = nil, accessory: BrainCardAccessory) {
        self.init(symbol: symbol, title: title, detail: detail, note: note, accessory: accessory) { EmptyView() }
    }
}

// MARK: - A download on its way

/// What a download is doing, under the card or row it belongs to: a stripe
/// and a percentage while it runs, one sentence when it stopped.
///
/// Nothing at all for a brain with no transfer, or one that finished — the
/// card's own button says what happens next.
struct BrainTransferStatus: View {
    @Environment(AppModel.self) private var model
    let record: ModelRecord

    var body: some View {
        if let transfer = model.transfer(for: record.id) {
            switch transfer.state {
            case .waiting:
                running(fraction: nil, line: "Starting…")
            case .running:
                running(fraction: transfer.fraction, line: progressLine(transfer))
            case .stopping:
                sentence("Stopping…")
            case .paused:
                sentence("Paused at \(percent(transfer.fraction)).")
            case .failed:
                sentence("The download didn't finish.")
            case .finished:
                EmptyView()
            }
        } else if model.lastLoadFailure?.id == record.id, let reason = model.lastLoadFailure?.sentence {
            sentence(reason)
        }
    }

    private func running(fraction: Double?, line: String) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            ProgressStripe(fraction: fraction ?? 0, isIndeterminate: fraction == nil)
                .padding(.top, PDSpacing.xxs)
            HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                Text(line)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                InlineLink("Cancel", tint: .pd.inkSecondary) { model.cancelDownload(record) }
                    .fixedSize()
                    .accessibilityLabel("Cancel the download")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(Font.pd.footnote)
            .foregroundStyle(Color.pd.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "34% · about 3 min left". The minutes only once the rate has settled.
    private func progressLine(_ transfer: ModelTransfer) -> String {
        var line = percent(transfer.fraction)
        if let seconds = model.pace(for: transfer.id)?.secondsRemaining,
           let minutes = BrainStatus.minutes(for: seconds) {
            line += minutes == 1 ? " · about a minute left" : " · about \(minutes) min left"
        }
        return line
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }
}

// MARK: - More brains

/// Every brain Pocketd knows, and the way to search for more.
///
/// The list the Brain page used to be, one level down where choosing between
/// names is the point. Each row says the one thing that matters about a brain
/// before its size — whether it reads your day — and offers Use, Remove or a
/// download. A brain that cannot fit this phone says so instead of offering
/// itself.
struct MoreBrainsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ProStore.self) private var pro: ProStore?

    @State private var removing: ModelRecord?
    @State private var searching = false

    var body: some View {
        YouDetailScreen(
            title: "More brains",
            subtitle: "Every one runs on this iPhone. Only some can read your day."
        ) {
            if !installed.isEmpty {
                YouSection("On this iPhone") {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { RowDivider(inset: 0) }
                        BrainRow(record: record) { removing = record }
                    }
                }
            }
            if !toDownload.isEmpty {
                YouSection("To download") {
                    ForEach(Array(toDownload.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { RowDivider(inset: 0) }
                        BrainRow(record: record)
                    }
                }
            }
            YouSection("Anything else") {
                // Searching is "Any brain", Pocketd Pro; the capsule says so
                // before the tap.
                ProGateReader { proGate in
                    NavRow(
                        symbol: "magnifyingglass",
                        title: "Search Hugging Face",
                        detail: "Brains other people have published",
                        status: ProBadge.status(for: pro)
                    ) {
                        proGate(.brains) { searching = true }
                    }
                }
                RowDivider()
                NavRow(symbol: "gearshape.2", title: "Technical details", detail: "Size, memory and speed") {
                    navigator.push(.brainAdvanced)
                }
            }
        }
        .navigationDestination(isPresented: $searching) {
            ModelSearchView()
        }
        .confirmationDialog(
            removing.map { "Remove \($0.displayName)?" } ?? "Remove this brain?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { record in
            Button("Remove", role: .destructive) {
                Task { await model.delete(record) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { record in
            Text(isInUse(record)
                 ? "Pocketd is using it now. Removing it frees \(pdBytes(record.totalDownloadBytes))."
                 : "Frees \(pdBytes(record.totalDownloadBytes)).")
        }
        #if DEBUG
        .onAppear {
            // A screenshot run that asked for a search lands on it.
            if YouStage.searchQuery != nil { searching = true }
        }
        #endif
    }

    /// On this phone, the one in use first.
    private var installed: [ModelRecord] {
        model.catalog
            .filter { model.isInstalled($0) }
            .sorted { isInUse($0) && !isInUse($1) }
    }

    /// Everything else: the brains that read the day first, smallest first
    /// within each — the order somebody choosing should read them in.
    private var toDownload: [ModelRecord] {
        model.catalog
            .filter { !model.isInstalled($0) }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.dayAccess().readsYourDay, rhs.dayAccess().readsYourDay)
                if l != r { return l }
                return lhs.totalDownloadBytes < rhs.totalDownloadBytes
            }
    }

    private func isInUse(_ record: ModelRecord) -> Bool {
        !model.isUsingBuiltInBrain && model.effectiveBrain == .downloaded(id: record.id)
    }
}

/// One brain in More brains: name, "Reads your day" or "Chat only" with its
/// size, and one control.
private struct BrainRow: View {
    @Environment(AppModel.self) private var model
    let record: ModelRecord
    /// Set for a brain on this phone: the Remove link under it.
    var onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            AccessoryRowLayout(spacing: PDSpacing.s) {
                Text(record.displayName)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pdSeparated(detail))
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) { control }
            }
            BrainTransferStatus(record: record)
            if let onRemove {
                InlineLink("Remove", tint: .pd.danger, action: onRemove)
                    // The 44pt target overhangs the row's own padding rather
                    // than adding a band of nothing under the word.
                    .padding(.vertical, -PDSpacing.xs)
                    .accessibilityLabel("Remove \(record.displayName)")
            }
        }
        .padding(.vertical, PDSpacing.s)
        .accessibilityElement(children: .contain)
    }

    private var fit: DeviceBudget.Fit { model.fit(for: record) }

    private var dayAccess: DayAccess {
        record.dayAccess(resident: model.loadedModelID == record.id ? model.personalDataToolGate : nil)
    }

    /// "Reads your day · 1.1 GB", plus the fit when it is a consequence —
    /// "Tight fit" for one that leaves little room. A brain too big for this
    /// phone says so in the control instead.
    private var detail: String {
        var parts = [dayAccess.label, pdBytes(record.totalDownloadBytes)]
        if fit == .tight { parts.append(pdFitWords(fit)) }
        return parts.joined(separator: " · ")
    }

    private var isInUse: Bool {
        !model.isUsingBuiltInBrain && model.effectiveBrain == .downloaded(id: record.id)
    }

    @ViewBuilder
    private var control: some View {
        let transfer = model.transfer(for: record.id)
        if model.loadingModelID == record.id {
            quiet("Getting ready")
        } else if isInUse {
            HStack(spacing: PDSpacing.xxs) {
                Image(systemName: "checkmark").font(Font.pd.tick)
                Text("In use").font(Font.pd.secondary.weight(.semibold))
            }
            .foregroundStyle(Color.pd.positive)
            .frame(minHeight: PDMetric.minHitTarget)
            .accessibilityElement(children: .combine)
        } else if model.isInstalled(record) {
            PillButton(title: "Use", symbol: BrainCardAccessory.useSymbol) {
                Task { await model.useDownloadedBrain(id: record.id) }
            }
            .accessibilityLabel("Use \(record.displayName)")
        } else if transfer?.isActive == true || transfer?.state == .stopping {
            EmptyView()
        } else if !fit.allowsDownload {
            quiet(pdFitWords(fit))
        } else if case .paused? = transfer?.state {
            PillButton(title: "Resume", symbol: "arrow.down") { model.download(record) }
                .accessibilityLabel("Resume \(record.displayName)")
        } else {
            // The recommended download is free; any other is "Any brain",
            // Pocketd Pro. Use, Resume and Remove never ask.
            let gated = getNeedsPro
            ProGateReader { proGate in
                HStack(spacing: PDSpacing.xs) {
                    if gated { ProBadge() }
                    PillButton(title: "Get", symbol: "arrow.down") {
                        if gated {
                            proGate(.brains) { model.download(record) }
                        } else {
                            model.download(record)
                        }
                    }
                    .accessibilityLabel("Download \(record.displayName), \(pdBytes(record.totalDownloadBytes))")
                }
            }
        }
    }

    private var getNeedsPro: Bool {
        ProAccess.brainNeedsPro(
            id: record.id,
            recommendedID: BrainRecommendation.recommended(for: model.budget)?.id,
            onPhone: []
        )
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Font.pd.secondary.weight(.medium))
            .foregroundStyle(Color.pd.inkSecondary)
            .frame(minHeight: PDMetric.minHitTarget)
    }
}

// MARK: - Previews

#Preview("Brain light") {
    NavigationStack { BrainView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Brain dark") {
    NavigationStack { BrainView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}

#Preview("More brains") {
    NavigationStack { MoreBrainsView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}
