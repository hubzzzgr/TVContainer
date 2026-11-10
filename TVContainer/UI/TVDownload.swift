import Foundation

struct TVFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Stream to disk and enforce limits during transfer, including chunked responses.
final class TVDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let progress: @Sendable (TVDownloadProgress) -> Void
    private var lastProgressTime: TimeInterval = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()
    private var cancelled = false
    private init(limit: Int64, progress: @escaping @Sendable (TVDownloadProgress) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    static func fetch(_ url: URL, limit: Int64,
                      progress: @escaping @Sendable (TVDownloadProgress) -> Void = { _ in }) async throws -> URL {
        let download = TVDownload(limit: limit, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { download.begin(url, continuation: $0) }
        } onCancel: { download.cancel() }
    }
    private func begin(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.downloadTask(with: url)
        task?.resume()
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            failure = TVFailure("The download exceeds the allowed size.")
            downloadTask.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressTime >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgressTime = now
            progress(TVDownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw TVFailure("The server did not return a download. Check the URL and its access permissions.")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, Int64(size) <= limit else { throw TVFailure("The downloaded file is empty or too large.") }
            progress(TVDownloadProgress(received: Int64(size), total: downloadTask.response?.expectedContentLength))
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: saved)
            continuation?.resume(returning: saved)
            continuation = nil
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let continuation {
            continuation.resume(throwing: failure ?? error ?? TVFailure("The download failed."))
            self.continuation = nil
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
