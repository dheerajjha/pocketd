import Foundation

/// Splits actual microphone samples, not text: every buffer goes to exactly
/// one request. A long quiet tail can seal a phrase even on recognizers that
/// return no usable timestamps. Short hesitations stay in the same request.
public struct DictationAudioRequests: Sendable {
    private var peak: Float = 0
    private var voiced: TimeInterval = 0
    private var quiet: TimeInterval = 0
    private var waitingAbove: [Float?] = [nil]
    private var closed = false
    public private(set) var reader = 0
    private var finished = false
    public init() {}

    /// `level` is the unsmoothed buffer RMS on VoiceInput's -50...0 dB scale.
    /// The incoming buffer always has one writer. An opened successor receives
    /// every *subsequent* buffer, including silence before the next voiced onset.
    public mutating func write(level: Float, seconds: TimeInterval, spareReady: Bool) -> (part: Int, opensNext: Bool, woke: Bool)? {
        guard !closed else { return nil }
        let i = waitingAbove.count - 1
        let woke = waitingAbove[i].map { level > $0 } == true
        if woke { waitingAbove[i] = nil }
        guard seconds.isFinite, seconds > 0, level.isFinite else { return (i, false, woke) }
        peak = max(peak, level)
        let floor = min(0.34, max(0.12, peak - 0.30))
        if level > floor { voiced += seconds; quiet = 0 }
        else { quiet += seconds }
        guard voiced >= 0.15, quiet >= 1.25, spareReady else { return (i, false, woke) }
        waitingAbove.append(floor)
        peak = 0
        voiced = 0
        quiet = 0
        return (i, true, woke)
    }

    public func state(at i: Int) -> (ready: Bool, sealed: Bool) {
        let sealed = closed || i < waitingAbove.count - 1
        return (sealed || waitingAbove[i] == nil, sealed)
    }

    public func acceptsResult(from i: Int) -> Bool { !finished && reader == i }

    public mutating func finish(at i: Int) -> (hasNext: Bool, quietOnly: Bool)? {
        guard acceptsResult(from: i) else { return nil }
        let hasNext = i < waitingAbove.count - 1
        if hasNext { reader += 1 } else { closed = true; finished = true }
        return (hasNext, waitingAbove[i] != nil)
    }

    public mutating func close() { closed = true }
}

/// Times are positions in one recognition request's audio, not callback times.
/// `substringRange` is UTF-16 in Apple's formatted transcription.
public struct DictationTiming: Sendable {
    public struct Segment: Sendable {
        public let start: TimeInterval
        public let duration: TimeInterval
        public let substringRange: NSRange

        public init(start: TimeInterval, duration: TimeInterval, substringRange: NSRange) {
            self.start = start
            self.duration = duration
            self.substringRange = substringRange
        }
    }

    public let segments: [Segment]
    public let speechStart: TimeInterval?
    public let speechDuration: TimeInterval?

    public init(segments: [Segment] = [], speechStart: TimeInterval? = nil, speechDuration: TimeInterval? = nil) {
        self.segments = segments
        self.speechStart = speechStart
        self.speechDuration = speechDuration
    }
}

/// Speech revises hypotheses for the same audio. Some on-device results after
/// a pause cover only later audio, while others replay the entire request.
/// Never use spelling, confidence, a callback delay, or zero-duration timings
/// to decide that two utterances are different.
struct DictationTranscript: Sendable {
    private struct Piece: Sendable {
        var text: String
        var span: Range<TimeInterval>?
        var segments: [DictationTiming.Segment]
        var confirmed: Bool

        init(_ text: String, _ timing: DictationTiming, confirmed: Bool) {
            self.text = text
            self.confirmed = confirmed
            let segments = timing.segments
            let length = text.utf16.count
            if let first = segments.first, let last = segments.last,
               segments.allSatisfy({ segment in
                   let r = segment.substringRange
                   return Self.valid(start: segment.start, duration: segment.duration) && r.location >= 0 && r.location <= length
                       && r.length > 0 && r.length <= length - r.location && Range(r, in: text) != nil
               }),
               zip(segments, segments.dropFirst()).allSatisfy({ $0.start <= $1.start && NSMaxRange($0.substringRange) <= $1.substringRange.location }) {
                self.segments = segments
                span = first.start..<(last.start + last.duration)
            } else {
                self.segments = []
                if let start = timing.speechStart, let duration = timing.speechDuration, Self.valid(start: start, duration: duration) {
                    span = start..<(start + duration)
                }
            }
        }

        private static func valid(start: Double, duration: Double) -> Bool {
            start.isFinite && start >= 0 && duration > 0 && (start + duration).isFinite && start + duration > start
        }

        /// A rolling result can start at the last word of the previous one.
        /// Retain only the formatted prefix belonging to earlier audio.
        func prefix(before start: TimeInterval) -> Self? {
            let earlier = segments.prefix { $0.start + $0.duration <= start }
            guard !earlier.isEmpty, earlier.count < segments.count,
                  let cut = Range(segments[earlier.count].substringRange, in: text)?.lowerBound else { return nil }
            return Self(String(text[..<cut]), .init(segments: Array(earlier)), confirmed: confirmed)
        }
    }

    private var pieces: [Piece] = []
    var text: String { pieces.reduce("") { Self.join($0, $1.text) } }
    var hasConfirmed: Bool { pieces.contains(where: \.confirmed) }
    var allConfirmed: Bool { !pieces.isEmpty && pieces.allSatisfy(\.confirmed) }

    /// The user's prefix is passed unchanged, including deliberate newlines.
    static func join(_ prefix: String, _ suffix: String) -> String {
        guard let last = prefix.last, let first = suffix.first else { return prefix + suffix }
        let separator = last.isWhitespace || first.isWhitespace || ".,;:!?，。！？、".contains(first) ? "" : " "
        return prefix + separator + suffix
    }

    mutating func update(_ text: String, timing: DictationTiming, confirmed: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let next = Piece(text, timing, confirmed: confirmed)
        guard let span = next.span else {
            // Untimed partials revise the open utterance. Keep a timestamped
            // checkpoint visible until a timed update or utterance final can
            // place the new words; don't erase it on a zero-timestamp reset.
            if let last = pieces.last, !last.confirmed {
                if last.span != nil && !confirmed { return }
                pieces.removeLast()
            }
            pieces.append(next)
            return
        }

        var earlier: [Piece] = [], later: [Piece] = []
        for previous in pieces {
            guard let old = previous.span else {
                // An untimed provisional hypothesis has no independent audio
                // interval to preserve when its timed revision arrives.
                if previous.confirmed { earlier.append(previous) }
                continue
            }
            if old.upperBound <= span.lowerBound { earlier.append(previous) }
            else if old.lowerBound >= span.upperBound { later.append(previous) }
            else if let prefix = previous.prefix(before: span.lowerBound) { earlier.append(prefix) }
        }
        pieces = earlier + [next] + later
    }
}
