import Foundation
import Testing
import FlyingFox
@testable import PocketdKit

/// The part of a download that only exists because the session is a background
/// one.
///
/// A default session could belong to the transfer that created it, and the old
/// code let it: one session per `FileDownloader`, invalidated when that
/// download finished. A background session cannot be owned that way. The system
/// keys the out-of-process transfer to the identifier, a second live session
/// with an identifier already in use terminates the app, and callbacks arrive
/// for whichever transfer the system feels like — including, after a relaunch,
/// for one this process never started. What is checked here is that the
/// callbacks reach the right download, that a finished one lets go, and that a
/// transfer nobody is left listening to still delivers its bytes.
///
/// Serialized for the reason `DownloadTests` is: the system runs four
/// background transfers at a time and staggers the rest by ten seconds.
@Suite("Background download session", .serialized)
struct DownloadSessionTests {

    /// A session of this test's own. Sessions are keyed globally by identifier,
    /// so two tests sharing one would share a routing table, which is the thing
    /// under test.
    private func isolatedSession() -> BackgroundDownloadSession {
        BackgroundDownloadSession.session(identifier: "dev.pocketd.tests.\(UUID().uuidString)")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Two paths with two different bodies, so a test can tell whose bytes
    /// landed where. Tests that move one file leave `second` alone.
    /// Serialised against every other download suite. See DownloadSerialization.
    private func withServer(
        first: Data,
        second: Data = Data(),
        _ body: (URL) async throws -> Void
    ) async throws {
        await DownloadSerialization.shared.acquire()
        do {
            try await unlockedWithServer(first: first, second: second, body)
        } catch {
            await DownloadSerialization.shared.release()
            throw error
        }
        await DownloadSerialization.shared.release()
    }

    private func unlockedWithServer(
        first: Data,
        second: Data = Data(),
        _ body: (URL) async throws -> Void
    ) async throws {
        let server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        await server.appendRoute("GET /first.bin") { _ in
            HTTPResponse(statusCode: .ok, headers: [.contentType: "application/octet-stream"], body: first)
        }
        await server.appendRoute("GET /second.bin") { _ in
            HTTPResponse(statusCode: .ok, headers: [.contentType: "application/octet-stream"], body: second)
        }
        let running = Task { try? await server.run() }
        try await server.waitUntilListening(timeout: 5)
        defer { running.cancel() }
        let port = try #require(await server.resolvedPort())
        try await body(URL(string: "http://127.0.0.1:\(port)")!)
        await server.stop(timeout: 1)
    }

    /// Runs one download to completion and answers where it landed.
    ///
    /// Polled against a deadline rather than awaited on a continuation, and
    /// that is deliberate. A callback routed to the wrong download leaves this
    /// one waiting forever, and a continuation that never resumes hangs the run
    /// instead of failing it — `.timeLimit` writes the overrun down and then
    /// goes on waiting for a test that will never return, and a test that hangs
    /// reports nothing.
    ///
    /// A minute, because the deadline is there to catch a transfer that will
    /// never arrive rather than a slow one. These payloads are kilobytes, but
    /// the system runs four background transfers at a time and holds the rest
    /// back by ten seconds and more while the rest of the package is
    /// downloading too: at twenty seconds that turned up as a failing test.
    private func install(
        _ downloader: FileDownloader,
        from url: URL,
        timeout: Duration = .seconds(60)
    ) async throws -> URL {
        let outcome = Outcome()
        downloader.start(request: URLRequest(url: url), resumeData: nil) { outcome.record($0) }
        await waitUntil("the download to finish", timeout: timeout) { outcome.result != nil }
        guard let result = outcome.result else { throw DownloadNeverFinished() }
        return try result.get()
    }

    private struct DownloadNeverFinished: Error {}

    /// Written by the completion handler on URLSession's queue, read from the
    /// test's own.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<URL, any Error>?

        func record(_ result: Result<URL, any Error>) {
            lock.lock()
            stored = result
            lock.unlock()
        }

        var result: Result<URL, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Polls rather than sleeps a fixed amount: the assertion is about a state
    /// being reached, and a fixed sleep either flakes or wastes the time.
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(60),
        _ condition: @Sendable () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// The progress a downloader was told about. Written on URLSession's queue
    /// and read from the test's, which is why it is not a plain `var`.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var highWaterMark: Int64 = 0

        func observe(_ written: Int64) {
            lock.lock()
            highWaterMark = Swift.max(highWaterMark, written)
            lock.unlock()
        }

        var bytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return highWaterMark
        }
    }

    /// Whether a callback that answers nothing ever ran at all.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }

    // MARK: One session, shared

    @Test("asking twice for an identifier gives back the session that exists")
    func sessionsAreUniquePerIdentifier() {
        let identifier = "dev.pocketd.tests.\(UUID().uuidString)"
        let first = BackgroundDownloadSession.session(identifier: identifier)
        let second = BackgroundDownloadSession.session(identifier: identifier)

        // Not tidiness. Constructing a second live URLSession with an
        // identifier already in use is not an error the app can catch and
        // recover from — it terminates the process.
        #expect(first === second)
        #expect(BackgroundDownloadSession.session(identifier: identifier + ".other") !== first)
    }

    @Test("the transfer runs on a background session, not a default one")
    func theSessionIsABackgroundSession() {
        let identifier = "dev.pocketd.tests.\(UUID().uuidString)"
        let session = BackgroundDownloadSession.session(identifier: identifier)

        // The bug the whole arrangement exists for. On a default configuration
        // this is nil, and the transfer dies the moment iOS suspends the app —
        // which for a download that takes minutes is the ordinary case, not an
        // edge one.
        // Asserted on the DECISION rather than on this process's session.
        //
        // This used to read the session it was handed, and that stopped being
        // able to answer the question: a test runner has no bundle identifier,
        // so nothing will ever relaunch it, so it deliberately gets an
        // ephemeral session. Reading that session back proved only that the
        // test process had taken the test-process branch.
        //
        // The guarantee that actually matters is that a real app gets a real
        // background session, and that is what these two lines check.
        #expect(
            BackgroundDownloadSession
                .configuration(identifier: identifier, canBeRelaunched: true)
                .identifier == identifier,
            "a process iOS can relaunch must get a background session"
        )
        #expect(
            BackgroundDownloadSession
                .configuration(identifier: identifier, canBeRelaunched: false)
                .identifier == nil,
            "a process nothing will relaunch must not wait on the system's queue"
        )
    }

    @Test("two downloads sharing one session each get their own bytes")
    func concurrentDownloadsAreRoutedApart() async throws {
        let small = Data(repeating: 0x11, count: 64 << 10)
        let large = Data(repeating: 0x22, count: 512 << 10)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(first: small, second: large) { baseURL in
            let session = isolatedSession()
            let smallProgress = ProgressLog()
            let largeProgress = ProgressLog()

            let smallDownloader = FileDownloader(
                destination: directory.appendingPathComponent("small.gguf"),
                resumeDataURL: directory.appendingPathComponent("small.resume"),
                session: session
            ) { written, _ in smallProgress.observe(written) }
            let largeDownloader = FileDownloader(
                destination: directory.appendingPathComponent("large.gguf"),
                resumeDataURL: directory.appendingPathComponent("large.resume"),
                session: session
            ) { written, _ in largeProgress.observe(written) }

            async let smallResult = install(smallDownloader, from: baseURL.appendingPathComponent("first.bin"))
            async let largeResult = install(largeDownloader, from: baseURL.appendingPathComponent("second.bin"))
            let (smallURL, largeURL) = try await (smallResult, largeResult)

            #expect(try Data(contentsOf: smallURL) == small)
            #expect(try Data(contentsOf: largeURL) == large)
            // Progress is the half that fails quietly. A routing table keyed by
            // anything two transfers share would leave both files right and
            // still report one download's byte counts on the other's bar.
            #expect(smallProgress.bytes == Int64(small.count))
            #expect(largeProgress.bytes == Int64(large.count))
        }
    }

    @Test("a finished download stops being routed")
    func finishedDownloadsLetGo() async throws {
        let payload = Data(repeating: 0x33, count: 64 << 10)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(first: payload) { baseURL in
            let session = isolatedSession()
            let downloader = FileDownloader(
                destination: directory.appendingPathComponent("weights.gguf"),
                resumeDataURL: directory.appendingPathComponent("weights.resume"),
                session: session
            ) { _, _ in }
            _ = try await install(downloader, from: baseURL.appendingPathComponent("first.bin"))

            // The session is never invalidated now, and URLSession keeps its
            // delegate for as long as it lives, so a download that finished
            // without dropping its routing entry would hold its buffers and its
            // completion handler for the rest of the process.
            #expect(session.routedTaskIdentifiers.isEmpty)
        }
    }

    // MARK: Transfers that outlive the download that started them

    @Test("a transfer that finishes with nobody listening still lands where it belongs")
    func orphanedTransfersAreInstalled() async throws {
        let payload = Data(repeating: 0x44, count: 128 << 10)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withServer(first: payload) { baseURL in
            let session = isolatedSession()
            let placement = DownloadPlacement(
                destination: directory.appendingPathComponent("adopted.gguf"),
                resumeDataURL: directory.appendingPathComponent("adopted.resume")
            )

            // Exactly the shape of what the delegate is handed after iOS
            // relaunches the app for a transfer that completed while it was
            // gone: a task carrying a placement, and no downloader anywhere in
            // the process that has ever heard of it. Without the placement the
            // system deletes these bytes when the callback returns and the user
            // downloads four gigabytes a second time.
            let task = session.urlSession.downloadTask(
                with: baseURL.appendingPathComponent("first.bin")
            )
            task.taskDescription = placement.encoded
            task.resume()

            await waitUntil("the orphaned transfer to be installed") {
                FileManager.default.fileExists(atPath: placement.destination.path)
            }
            let installed = try Data(contentsOf: placement.destination)
            #expect(installed == payload)
        }
    }

    @Test("a task with no placement of ours is not given a destination")
    func unplacedTasksAreLeftAlone() {
        // Anything else in the app may put a task on this session one day, and
        // a relaunch hands the delegate whatever was in flight. Guessing a
        // destination from a description that is not one of ours would write a
        // stranger's bytes over a model file.
        #expect(DownloadPlacement(encoded: nil) == nil)
        #expect(DownloadPlacement(encoded: "") == nil)
        #expect(DownloadPlacement(encoded: "a plain task description") == nil)
        #expect(
            DownloadPlacement(encoded: #"{"destination":"file:///tmp/weights.gguf"}"#) == nil,
            "half a placement is not one: without the resume path the poison blob would survive"
        )
    }

    // MARK: The app's half

    @Test("background events for a session we do not own are answered anyway")
    func foreignBackgroundEventsAreAnswered() async {
        // iOS freezes the app again the moment this handler is called and kills
        // it if it never is, so "not one of ours" cannot mean "ignore".
        let answered = Flag()
        BackgroundDownloads.handleEvents(forSession: "com.example.someone.elses.session") {
            answered.raise()
        }
        await waitUntil("the handler to be called", timeout: .seconds(5)) { answered.isRaised }
    }
}

@Suite("Background install integrity")
struct BackgroundInstallIntegrityTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketd-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a short file is refused before it is installed")
    func shortFileIsRefused() throws {
        // The relaunch path never reaches ModelStore.verifiedSize: iOS restarts
        // the app, hands the delegate a finished transfer and a destination,
        // and there is no ModelStore call anywhere in that story. Without a
        // check here, a truncated GGUF lands exactly where a load will find it
        // — and a GGUF short by a chunk does not fail politely at the reader,
        // it takes llama.cpp and the process with it.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloaded = dir.appendingPathComponent("partial.bin")
        try Data(repeating: 0xAB, count: 900).write(to: downloaded)

        let placement = DownloadPlacement(
            destination: dir.appendingPathComponent("model.gguf"),
            resumeDataURL: dir.appendingPathComponent("model.resume"),
            expectedBytes: 1_000
        )

        #expect(throws: ModelStoreError.self) {
            try FileDownloader.install(from: downloaded, to: placement, response: nil)
        }
        #expect(FileManager.default.fileExists(atPath: placement.destination.path) == false,
                "a refused file must not be left where a load would find it")
    }

    @Test("a complete file installs")
    func completeFileInstalls() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloaded = dir.appendingPathComponent("whole.bin")
        try Data(repeating: 0xAB, count: 1_000).write(to: downloaded)
        let placement = DownloadPlacement(
            destination: dir.appendingPathComponent("model.gguf"),
            resumeDataURL: dir.appendingPathComponent("model.resume"),
            expectedBytes: 1_000
        )

        let installed = try FileDownloader.install(from: downloaded, to: placement, response: nil)
        #expect(installed == placement.destination)
        #expect(FileManager.default.fileExists(atPath: placement.destination.path))
    }

    @Test("an unknown expected size cannot check, and must not pretend to pass")
    func unknownSizeDoesNotBlock() throws {
        // The honest outcome when there is nothing to compare against is to
        // install and let ModelStore's own guard speak. Refusing here would
        // break every download whose server sends no length.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloaded = dir.appendingPathComponent("unknown.bin")
        try Data(repeating: 0x01, count: 10).write(to: downloaded)
        let placement = DownloadPlacement(
            destination: dir.appendingPathComponent("model.gguf"),
            resumeDataURL: dir.appendingPathComponent("model.resume"),
            expectedBytes: nil
        )
        _ = try FileDownloader.install(from: downloaded, to: placement, response: nil)
        #expect(FileManager.default.fileExists(atPath: placement.destination.path))
    }
}
