import Foundation

/// Downloads one large file with progress, resuming where it left off.
///
/// This exists because the obvious implementation is unusably slow. Iterating
/// `URLSession.bytes` one `UInt8` at a time measures **0.15 MB/s on an M-series
/// Mac**, and it is CPU-bound in the async-sequence machinery rather than
/// waiting on the network — 42 minutes for a 386 MB model and over three hours
/// for a 2 GB one. A download task writes through the kernel instead, and
/// resumes with URLSession's own resume data, which carries the validators that
/// make a resume correct across the redirect Hugging Face issues to its CDN.
///
/// The transfer runs on a background session. That is not a refinement: a
/// multi-gigabyte GGUF takes minutes, leaving the app is what a person does
/// while they wait, and on a default session iOS suspending the app killed the
/// transfer — so the normal case was a download that died. The cost is that the
/// session cannot belong to this object. There is one per process, shared by
/// every transfer, and `BackgroundDownloadSession` is what hands each callback
/// back to the download that asked for it.
final class FileDownloader: @unchecked Sendable {
    /// Guards every mutable field below. The delegate callbacks arrive on
    /// URLSession's queue while `start` and `cancel` are called from the actor.
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var completion: (@Sendable (Result<URL, any Error>) -> Void)?

    private let placement: DownloadPlacement
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let session: BackgroundDownloadSession

    init(
        destination: URL,
        resumeDataURL: URL,
        session: BackgroundDownloadSession = .shared,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.placement = DownloadPlacement(destination: destination, resumeDataURL: resumeDataURL)
        self.session = session
        self.onProgress = onProgress
    }

    func start(
        request: URLRequest,
        resumeData: Data?,
        completion: @escaping @Sendable (Result<URL, any Error>) -> Void
    ) {
        lock.lock()
        self.completion = completion
        let task = resumeData.map { session.urlSession.downloadTask(withResumeData: $0) }
            ?? session.urlSession.downloadTask(with: request)
        // The one piece of this download that survives the process. A transfer
        // can finish while the app is not running, and the delegate is then
        // called in a relaunched app that never started it, so where the bytes
        // belong has to travel on the task rather than sit in memory here.
        task.taskDescription = placement.encoded
        self.task = task
        lock.unlock()

        // Registered before `resume`, so no callback can arrive for a task the
        // routing table has never heard of — and outside the lock, because the
        // delegate takes the session's lock first and this one second. Held
        // across the call, the two orders would deadlock.
        session.register(self, for: task)
        task.resume()
    }

    /// Cancels and persists resume data so the next attempt continues rather
    /// than starting the transfer over.
    func cancelSavingResumeData() {
        lock.lock()
        let task = self.task
        lock.unlock()

        guard let task else { return }
        task.cancel { [placement] data in
            if let data {
                try? data.write(to: placement.resumeDataURL, options: .atomic)
            }
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        let taskIdentifier = task?.taskIdentifier
        self.task = nil
        lock.unlock()

        // This used to invalidate the session, to break the retain cycle
        // URLSession holds on its delegate. A background session must not be
        // invalidated here: it is shared with every other transfer in the
        // process, and it cannot simply be rebuilt afterwards either, because a
        // second session with an identifier already in use terminates the app.
        // Dropping the routing entry is what releases this downloader now —
        // without it every finished download's buffers and completion handler
        // would live as long as the process.
        if let taskIdentifier {
            session.unregister(taskIdentifier)
        }
        completion?(result)
    }
}

// MARK: - The work a finished transfer needs, with or without a downloader

extension FileDownloader {
    func observeProgress(written: Int64, expected: Int64) {
        onProgress(written, expected)
    }

    func finishInstalling(from location: URL, response: URLResponse?) {
        do {
            let installed = try Self.install(from: location, to: placement, response: response)
            finish(.success(installed))
        } catch {
            finish(.failure(error))
        }
    }

    func failed(with error: any Error) {
        Self.recordInterruption(error, for: placement)
        finish(.failure(error))
    }

    /// Moves a finished transfer's bytes to where they belong.
    ///
    /// Static because the relaunch path has no downloader to call. When iOS
    /// restarts the app for a transfer that completed while it was gone, the
    /// only thing left that knows the destination is the placement the task
    /// carried, and that path has to do exactly what this one does rather than
    /// grow a second copy that drifts away from it.
    static func install(from location: URL, to placement: DownloadPlacement, response: URLResponse?) throws -> URL {
        do {
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw ModelStoreError.httpStatus(response.statusCode)
            }
            // Before the bytes are moved anywhere, and on the relaunch path
            // as much as the foreground one. Installing first and checking
            // later would leave a truncated model sitting where a load will
            // find it, and the failure that produces is not an error message —
            // it is llama.cpp taking the process down.
            try verifyLength(of: location, against: placement, response: response)

            try? FileManager.default.removeItem(at: placement.destination)
            try FileManager.default.createDirectory(
                at: placement.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: placement.destination)
            try? FileManager.default.removeItem(at: placement.resumeDataURL)
            return placement.destination
        } catch {
            // A resume blob that produced a failed transfer is poison: it is
            // replayed on every subsequent attempt, so the model would be
            // permanently unreachable with no way for the user to clear it.
            try? FileManager.default.removeItem(at: placement.resumeDataURL)
            throw error
        }
    }

    /// Refuses a file that is shorter than it was promised to be.
    ///
    /// Two sources, and the stricter one wins. The response's own
    /// `expectedContentLength` is authoritative when present but is -1 on a
    /// resumed transfer and whenever the server sent no length; the catalogue
    /// figure carried on the placement covers that case. When neither is
    /// available this cannot check anything and says so by doing nothing —
    /// which is the honest outcome, not a pass.
    ///
    /// Deliberately only rejects SHORT files. A file longer than expected is
    /// left to `ModelStore.verifiedSize`, which has the catalogue entry in
    /// front of it and can tell "the catalogue is stale" from "this is wrong".
    static func verifyLength(
        of location: URL,
        against placement: DownloadPlacement,
        response: URLResponse?
    ) throws {
        let actual = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? nil
        guard let actual else { return }

        var expected: Int64?
        if let length = response?.expectedContentLength, length > 0 { expected = length }
        if let catalogued = placement.expectedBytes, catalogued > 0 {
            expected = expected.map { Swift.max($0, catalogued) } ?? catalogued
        }
        guard let expected, actual < expected else { return }

        throw ModelStoreError.incompleteDownload(
            model: placement.destination.deletingPathExtension().lastPathComponent,
            expected: expected,
            actual: actual
        )
    }

    /// Leaves the resume data an interrupted transfer produced where the next
    /// attempt will find it.
    static func recordInterruption(_ error: any Error, for placement: DownloadPlacement) {
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            // A cancellation carries resume data; keep it so the retry continues.
            try? data.write(to: placement.resumeDataURL, options: .atomic)
        } else if nsError.code != NSURLErrorCancelled {
            // No resume data and not a cancellation: whatever is on disk is
            // stale, and replaying it would fail the same way forever. Deleting
            // unconditionally would be wrong — cancelSavingResumeData writes
            // from task.cancel(byProducingResumeData:)'s own callback, which is
            // unordered with respect to this one, so an unconditional delete can
            // land after a good blob and turn every user Cancel into a restart.
            try? FileManager.default.removeItem(at: placement.resumeDataURL)
        }
    }
}

/// Where a transfer's bytes belong, in a form that outlives the app.
///
/// A background transfer can finish while the app is not running. iOS relaunches
/// it and calls the delegate for a task this process never started, so anything
/// needed to finish the job has to have travelled with the task rather than sat
/// in memory. `taskDescription` is the only channel that does that: URLSession
/// hands it back across a relaunch unchanged.
struct DownloadPlacement: Codable, Equatable, Sendable {
    var destination: URL
    var resumeDataURL: URL
    /// What the catalogue says this file weighs, carried so the relaunch path
    /// can check it.
    ///
    /// `ModelStore.verifiedSize` guards the foreground path against a short
    /// file, and a GGUF short by a chunk does not fail politely at the reader —
    /// it takes llama.cpp, and the process with it. The relaunch path never
    /// reaches that guard: iOS restarts the app, hands the delegate a finished
    /// transfer and a destination, and there is no `ModelStore` call in that
    /// story at all. So the number travels with the task.
    ///
    /// Optional because a caller may genuinely not know — an unknown size must
    /// mean "cannot check", never "passed".
    var expectedBytes: Int64?

    init(destination: URL, resumeDataURL: URL, expectedBytes: Int64? = nil) {
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.expectedBytes = expectedBytes
    }

    /// Nil for a task carrying no placement of ours, which the delegate has to
    /// leave alone rather than invent a destination for.
    init?(encoded: String?) {
        guard let encoded,
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8))
        else { return nil }
        self = decoded
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The one background URLSession this process is allowed, and the table that
/// puts each delegate callback back in front of the download that asked for it.
///
/// A background session is not a per-transfer object the way a default session
/// can be. The system keys the out-of-process transfer to the identifier, and
/// creating a second live session with an identifier already in use terminates
/// the app — so every download shares one, which is why the delegate is this
/// object rather than `FileDownloader`, and why a finished download unregisters
/// instead of invalidating.
final class BackgroundDownloadSession: NSObject, @unchecked Sendable {
    /// Every session handed out so far, so that asking twice for an identifier
    /// returns the one that exists instead of building the second one that
    /// would crash the app.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: BackgroundDownloadSession] = [:]

    static let shared = BackgroundDownloadSession.session(identifier: defaultIdentifier)

    static func session(identifier: String) -> BackgroundDownloadSession {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[identifier] { return existing }
        let created = BackgroundDownloadSession(identifier: identifier)
        registry[identifier] = created
        return created
    }

    /// The same string on every launch, because that is what reconnects a
    /// relaunched app to a transfer that continued without it.
    ///
    /// The fallback is not cosmetic. No bundle identifier means there is no app
    /// here — a command-line tool, or the test runner — and nothing will ever
    /// relaunch one of those. A fixed string would then only let each run
    /// inherit the previous run's unfinished transfers and deliver them into
    /// temporary directories that were deleted hours ago, so those processes
    /// get an identifier that dies with them.
    static let defaultIdentifier: String = {
        if let bundle = Bundle.main.bundleIdentifier {
            return "\(bundle).model-downloads"
        }
        return "dev.pocketd.model-downloads.\(UUID().uuidString)"
    }()

    /// Not `let` because the session's delegate is `self`, which does not exist
    /// until `super.init` has run.
    private(set) var urlSession: URLSession!

    private let lock = NSLock()
    private var handlers: [Int: FileDownloader] = [:]
    private var eventsFinished: (@Sendable () -> Void)?

    private init(identifier: String) {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // The whole point is a multi-gigabyte transfer over a phone's Wi-Fi;
        // the default 60-second resource timeout would abort every one of them.
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        // `waitsForConnectivity` is gone rather than forgotten: the session it
        // was set on was a default one, and URLSession ignores the property on a
        // background session, which waits for connectivity whatever it says.
        //
        // A discretionary transfer is one the system may hold back until the
        // device is charging on Wi-Fi, which — for a download someone is
        // watching a progress bar for — is indistinguishable from nothing
        // happening. iOS makes a transfer discretionary anyway when the app was
        // already in the background at the moment it started, which is the one
        // case where the delay is the right answer.
        configuration.isDiscretionary = false
        // Without this iOS has no reason to wake the app when the transfer
        // lands, and the finished file sits in the system's staging area until
        // it is swept — a download that completed and never arrived.
        configuration.sessionSendsLaunchEvents = true

        // Serial, as the per-download session this replaces was. The delegate
        // moves the finished file from inside `didFinishDownloadingTo`, and a
        // concurrent queue would let the completion callback for the same task
        // run against it.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        super.init()
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Routes `task`'s callbacks to `downloader` until it finishes.
    ///
    /// Keyed by task identifier, which URLSession keeps unique within a session
    /// across a relaunch too: a session that comes back holding tasks 1 and 2
    /// numbers the next one it is handed 3. Without that an adopted transfer
    /// could collide with a fresh one and deliver its bytes to the wrong file.
    func register(_ downloader: FileDownloader, for task: URLSessionTask) {
        lock.lock()
        handlers[task.taskIdentifier] = downloader
        lock.unlock()
    }

    func unregister(_ taskIdentifier: Int) {
        lock.lock()
        handlers[taskIdentifier] = nil
        lock.unlock()
    }

    /// The transfers this session is routing right now.
    ///
    /// Only the tests read it, and what they are watching for is a leak:
    /// URLSession keeps its delegate — this object — alive for the life of the
    /// process, so a download that finished without dropping its routing entry
    /// keeps its buffers and its completion handler alive with it.
    var routedTaskIdentifiers: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.keys.sorted()
    }

    /// The lock is released before the caller touches the downloader, because
    /// the downloader takes its own lock and `FileDownloader.start` takes the
    /// two in the opposite order.
    private func handler(for taskIdentifier: Int) -> FileDownloader? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[taskIdentifier]
    }

    /// Holds what iOS handed the app delegate until the last callback is out.
    ///
    /// iOS relaunches the app to deliver a background session's finished
    /// transfers and gives it a completion handler it must call once they have
    /// all arrived; the app is frozen again the moment it does, and killed if it
    /// never does. It is stored here because the delegate method that knows when
    /// the callbacks have run is on this object, while the AppDelegate that is
    /// handed the handler lives in the app target.
    func onEventsFinished(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        // Chained, not replaced. iOS kills an app that is handed one of these
        // and never calls it, and a second relaunch arriving before the first
        // round's callbacks have drained used to overwrite the first handler
        // and lose it forever. Both get called, once, in the order they
        // arrived.
        if let existing = eventsFinished {
            eventsFinished = { existing(); handler() }
        } else {
            eventsFinished = handler
        }
        lock.unlock()
    }
}

extension BackgroundDownloadSession: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        handler(for: downloadTask.taskIdentifier)?
            .observeProgress(written: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is valid only for the duration of this call, so the move
        // has to happen here and synchronously — hopping to an actor first
        // loses the file. That holds for the adopted case below as well, which
        // is why it does the move itself instead of handing the URL onward.
        if let handler = handler(for: downloadTask.taskIdentifier) {
            handler.finishInstalling(from: location, response: downloadTask.response)
        } else if let placement = DownloadPlacement(encoded: downloadTask.taskDescription) {
            // A transfer that finished while the app was not running. There is
            // nobody left to report to — the download that started it belonged
            // to a process that is gone — but the bytes are complete and real,
            // and the alternative is letting the system delete them when this
            // method returns and asking the user to fetch four gigabytes twice.
            _ = try? FileDownloader.install(
                from: location, to: placement, response: downloadTask.response
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }  // success already reported by didFinishDownloadingTo
        if let handler = handler(for: task.taskIdentifier) {
            handler.failed(with: error)
        } else if let placement = DownloadPlacement(encoded: task.taskDescription) {
            // The relaunch case again: nobody to tell, but the resume data is
            // worth as much to the next attempt as it would have been to this
            // one, and the same rule decides whether to keep or clear it.
            FileDownloader.recordInterruption(error, for: placement)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = eventsFinished
        eventsFinished = nil
        lock.unlock()

        // UIKit documents this as a main-thread call, and the delegate queue is
        // not the main thread.
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}

/// The app target's half of a background download.
public enum BackgroundDownloads {
    /// Call from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// Touching `shared` is the part that matters: building the session with the
    /// identifier iOS named is what reconnects the relaunched app to the
    /// transfers that finished without it, and until something does, the
    /// delegate callbacks carrying those files are never delivered.
    public static func handleEvents(
        forSession identifier: String,
        completion: @escaping @Sendable () -> Void
    ) {
        guard identifier == BackgroundDownloadSession.defaultIdentifier else {
            // Some other session's events. Calling the handler straight back is
            // still right — iOS kills an app that is given one and never calls
            // it — but nothing here can say anything about that transfer.
            completion()
            return
        }
        BackgroundDownloadSession.shared.onEventsFinished(completion)
    }
}
