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
final class FileDownloader: NSObject, @unchecked Sendable {
    /// Guards every mutable field below. The delegate callbacks arrive on
    /// URLSession's queue while `start` and `cancel` are called from the actor.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var completion: (@Sendable (Result<URL, any Error>) -> Void)?

    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    /// Where to leave resume data if the transfer is interrupted.
    private let resumeDataURL: URL

    init(
        destination: URL,
        resumeDataURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.onProgress = onProgress
        super.init()
    }

    func start(
        request: URLRequest,
        resumeData: Data?,
        completion: @escaping @Sendable (Result<URL, any Error>) -> Void
    ) {
        lock.lock()
        self.completion = completion
        let configuration = URLSessionConfiguration.default
        // The whole point is a multi-gigabyte transfer over a phone's Wi-Fi;
        // the default 60-second resource timeout would abort every one of them.
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        self.task = task
        lock.unlock()

        task.resume()
    }

    /// Cancels and persists resume data so the next attempt continues rather
    /// than starting the transfer over.
    func cancelSavingResumeData() {
        lock.lock()
        let task = self.task
        lock.unlock()

        guard let task else { return }
        task.cancel { [resumeDataURL] data in
            if let data {
                try? data.write(to: resumeDataURL, options: .atomic)
            }
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        // Breaks the retain cycle URLSession holds on its delegate. Without
        // this the downloader, its session and its buffers outlive every
        // completed download.
        session?.finishTasksAndInvalidate()
        completion?(result)
    }
}

extension FileDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is valid only for the duration of this call, so the move
        // has to happen here and synchronously — hopping to an actor first
        // loses the file.
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw ModelStoreError.httpStatus(response.statusCode)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeDataURL)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }  // success already reported by didFinishDownloadingTo
        // A cancellation carries resume data; keep it so the retry continues.
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeDataURL, options: .atomic)
        }
        finish(.failure(error))
    }
}
