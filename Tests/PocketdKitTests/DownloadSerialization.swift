import Foundation

/// One at a time, across every suite that moves real bytes.
///
/// `.serialized` on a suite orders the tests inside it and says nothing about
/// other suites, so the three download suites ran concurrently with each other
/// and with a hundred more. That matters here and nowhere else in this package,
/// because a background `URLSession` is not a per-test object: the system keys
/// the out-of-process transfer to its identifier and there is exactly one of
/// those for the whole process. Three suites asking the same daemon to move
/// megabytes at once queue behind each other inside iOS, and a test waiting its
/// turn hits a time limit and reports a failure that is really a scheduling
/// artefact.
///
/// The symptom was diagnostic: "two downloads sharing one session each get
/// their own bytes" passed in 3.2 seconds run alone and failed after 60 in the
/// full suite, on identical code. So this is not a flake to be papered over
/// with a longer timeout — it is a real shared resource that needs a real lock,
/// and the lock belongs in the tests because the constraint belongs to the OS.
actor DownloadSerialization {
    static let shared = DownloadSerialization()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other download test is running, then claims the slot.
    ///
    /// Acquire/release rather than a closure-taking `exclusive { }`, because
    /// under Swift 6's strict concurrency a test body is not `Sendable` and
    /// cannot cross an actor boundary. Passing the work in would need the
    /// closure marked `sending`, which would then forbid it from capturing the
    /// suite's own `self` — which every one of these helpers does.
    func acquire() async {
        while busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
    }

    /// Hands the slot to whoever is next.
    ///
    /// Every caller must reach this on the failure path too, or the first
    /// failing download test hangs every one queued behind it — which would
    /// turn one red test into a suite that never finishes.
    func release() {
        busy = false
        if !waiting.isEmpty {
            waiting.removeFirst().resume()
        }
    }
}
