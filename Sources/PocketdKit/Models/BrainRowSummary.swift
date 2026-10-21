import Foundation

/// The You page's Brain row, in two short lines: which brain, and whether it
/// is ready.
///
/// Read from `BrainStatus` — the answer every other screen reads — so the row
/// cannot say "Ready" while the conversation says Pocketd is getting ready.
/// The name is the Brain page's word for it ("Built into iPhone", "Qwen3
/// 1.7B"); everything after it is one phrase from ideal-ui §3.5: "Ready",
/// "Getting ready · 34%", "Can't read your day — switch?".
public struct BrainRowSummary: Sendable, Equatable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    /// The line for a brain that answers and cannot read the day — a question,
    /// because the row is the way to the fix.
    public static let cannotReadYourDay = "Can't read your day — switch?"

    /// - Parameters:
    ///   - status: `AppModel.brainStatus`.
    ///   - usingBuiltIn: whether the brain answering the phone is Apple's.
    ///   - builtInAvailability: Apple's model on this phone, for its line.
    ///   - downloadName: the download answering, loading, arriving or waiting
    ///     on disk, by its display name.
    ///   - waitingReadsYourDay: for a download on disk and not in memory,
    ///     whether it reads the day (it loads by itself when needed).
    public static func make(
        status: BrainStatus,
        usingBuiltIn: Bool,
        builtInAvailability: BuiltInBrainAvailability,
        downloadName: String?,
        waitingReadsYourDay: Bool = true
    ) -> BrainRowSummary {
        if usingBuiltIn {
            return BrainRowSummary(
                title: BuiltInBrainOffer.title,
                detail: BuiltInBrainOffer.rowStatus(for: builtInAvailability)
            )
        }
        switch status {
        case .ready:
            return BrainRowSummary(title: downloadName ?? "Ready", detail: "Ready")
        case .cannotReadYourDay:
            return BrainRowSummary(title: downloadName ?? "Chat only", detail: cannotReadYourDay)
        case .loading:
            return BrainRowSummary(title: downloadName ?? "Getting ready", detail: "Getting ready")
        case let .arriving(fraction, _):
            let percent = fraction.map { " · \(Int((min(max($0, 0), 1) * 100).rounded(.down)))%" } ?? ""
            return BrainRowSummary(title: downloadName ?? "Getting ready", detail: "Getting ready\(percent)")
        case let .failed(reason):
            return BrainRowSummary(title: downloadName ?? "Not set up", detail: reason)
        case .none(hasDownloaded: true):
            // On this phone and not in memory: it loads by itself the moment
            // something needs it, so it is as ready as anyone can tell.
            return BrainRowSummary(
                title: downloadName ?? "Ready",
                detail: waitingReadsYourDay ? "Ready" : cannotReadYourDay
            )
        case .none(hasDownloaded: false):
            return BrainRowSummary(title: "Not set up", detail: "Choose how Pocketd thinks")
        }
    }
}
