import Foundation

/// Everything a screen needs to know about one model arriving on this phone.
///
/// This type exists because the state used to be spread across four
/// dictionaries keyed by model id — progress, error, paused, plus the manifest
/// — and *none of them held the model*. That worked for the eight curated
/// entries, whose records are compiled into the binary, and failed completely
/// for anything pulled off Hugging Face: the id was in `downloads`, the record
/// was nowhere, and every screen built its list by walking the catalogue. So a
/// search download ran for minutes with no row, no banner, no percentage and no
/// error if it failed — the bytes were moving and the app said nothing at all.
///
/// Carrying the record alongside the state is the fix, and keeping the states
/// in one enum is what stops them contradicting each other: a transfer cannot
/// be running and failed at once, which the four-dictionary version could
/// represent and did.
public struct ModelTransfer: Sendable, Equatable, Identifiable {
    public var record: ModelRecord
    public var state: State
    /// The furthest this transfer ever got.
    ///
    /// Kept outside `state` because it outlives the running state: a pause
    /// keeps its bytes on disk, and a bar that snaps back to empty the moment
    /// a download is interrupted tells the user the opposite of the truth —
    /// that the 900 MB they waited for is gone.
    public var lastProgress: DownloadProgress?
    /// Whether the user was warned this model is too big for the device and
    /// said go ahead anyway.
    ///
    /// Carried here so Resume means what Download meant. Without it a paused
    /// oversized download resumes into the store's own memory check and dies
    /// with "not enough memory" — refusing, on the second tap, the thing it
    /// was explicitly permitted to do on the first.
    public var allowingOversized: Bool

    public var id: String { record.id }

    public enum State: Sendable, Equatable {
        /// Started, and the first byte has not landed. Its own state rather
        /// than zero-of-total because they read differently: a bar pinned at
        /// 0% looks stuck, and "Starting…" looks like what it is. A download
        /// from a cold DNS lookup over a phone's Wi-Fi sits here for a second
        /// or two.
        case waiting
        case running(DownloadProgress)
        /// Cancelled, and the answer to "can this be resumed?" has not
        /// arrived yet.
        ///
        /// It is a real state, not a nicety. URLSession hands back its resume
        /// blob from `cancel(byProducingResumeData:)`'s callback, which for a
        /// multi-gigabyte transfer lands *seconds* after the cancel returns,
        /// and nothing signals when. Declaring "393 MB kept — Resume picks up
        /// where it stopped" the instant Stop was tapped therefore offered a
        /// button that, pressed promptly, read no blob and started the whole
        /// download again — having just promised in writing that it would not.
        case stopping
        /// On disk, in the manifest, and worth saying so. Timestamped because
        /// this is the one state that expires on its own — a completion notice
        /// that never leaves becomes furniture.
        case finished(at: Date)
        /// Interrupted with the bytes kept. The next tap resumes.
        case paused(String)
        case failed(String)
    }

    public init(
        record: ModelRecord,
        state: State,
        lastProgress: DownloadProgress? = nil,
        allowingOversized: Bool = false
    ) {
        self.record = record
        self.state = state
        self.lastProgress = lastProgress
        self.allowingOversized = allowingOversized
        if case let .running(progress) = state { self.lastProgress = progress }
    }

    /// Moves the transfer on, carrying the byte count forward.
    public mutating func advance(to next: State) {
        if case let .running(progress) = next { lastProgress = progress }
        state = next
    }

    /// Bytes are moving, or about to.
    public var isActive: Bool {
        switch state {
        case .waiting, .running: true
        // Deliberately not active: bytes have stopped moving, and the download
        // task's own cancellation callback clears anything still calling
        // itself active. Saying yes here would delete this state a moment
        // after entering it.
        case .stopping, .finished, .paused, .failed: false
        }
    }

    /// Worth taking up room above the tabs. Everything except a completion
    /// that has had its moment.
    public func isWorthShowing(now: Date = Date(), noticeSeconds: TimeInterval = 6) -> Bool {
        switch state {
        case .waiting, .running, .stopping, .paused, .failed:
            true
        case let .finished(at):
            now.timeIntervalSince(at) < noticeSeconds
        }
    }

    public var progress: DownloadProgress? {
        if case let .running(progress) = state { return progress }
        return nil
    }

    /// What to print under the name, in bytes. A paused or failed transfer
    /// still has a number worth showing — it is the evidence that resuming is
    /// worth more than starting over.
    public var bytesSoFar: DownloadProgress? { progress ?? lastProgress }

    /// 0…1 for a determinate bar. A finished transfer reads as full rather
    /// than as nothing, because the bar is still on screen for a few seconds
    /// after the last byte and snapping it back to empty would say the
    /// opposite of what happened.
    public var fraction: Double {
        switch state {
        case .waiting: 0
        case let .running(progress): progress.fraction
        case .finished: 1
        case .stopping, .paused, .failed: lastProgress?.fraction ?? 0
        }
    }
}

extension ModelCatalog {
    /// Every model a list on this device should be able to show.
    ///
    /// Three sources, and the order is the point. The curated catalogue leads
    /// and wins on id, so a catalogue model that has been downloaded keeps the
    /// name and description someone wrote for it rather than the filename
    /// Hugging Face happens to use. Then what is installed but not curated.
    /// Then — and this is the line that was missing — what is *arriving* but
    /// neither, which is every single download started from search.
    public static func listing(
        catalogue: [ModelRecord] = ModelCatalog.all,
        installed: [ModelRecord],
        transferring: [ModelRecord]
    ) -> [ModelRecord] {
        var merged = catalogue
        var known = Set(merged.map(\.id))
        for record in installed where !known.contains(record.id) {
            merged.append(record)
            known.insert(record.id)
        }
        for record in transferring where !known.contains(record.id) {
            merged.append(record)
            known.insert(record.id)
        }
        return merged
    }
}
