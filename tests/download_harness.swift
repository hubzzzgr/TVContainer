import Foundation

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TVDownloadProgress] = []
    func record(_ value: TVDownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }
    func snapshot() -> [TVDownloadProgress] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@main struct DownloadTests {
    static func main() async throws {
        for (size, unit) in [(999 as Int64, "B"), (1_000, "KB"), (999_999, "KB"),
                             (1_000_000, "MB"), (1_000_000_000, "GB"), (1_000_000_000_000, "TB")] {
            let start = TVDownloadProgress(received: 0, total: size)
            let end = TVDownloadProgress(received: size, total: size)
            assert(start.unit == unit && end.unit == unit)
            assert(start.totalText == end.totalText)
            assert(end.receivedText == end.totalText)
        }
        assert(TVDownloadProgress(received: 1_500, total: 2_000_000).receivedText == (0.0).formatted(.number.precision(.fractionLength(2))))
        assert(TVDownloadProgress(received: 1_500, total: nil).unit == "KB")
        assert(TVDownloadProgress(received: 1_500, total: nil).totalText == "—")
        assert(TVDownloadProgress(received: Int64.max).unit == "EB")
        let base = URL(string: CommandLine.arguments[1])!
        let size: Int64 = 2 * 1024 * 1024
        let known = ProgressRecorder()
        let file = try await TVDownload.fetch(base.appendingPathComponent("known"), limit: size + 1) { known.record($0) }
        let data = try Data(contentsOf: file)
        assert(Int64(data.count) == size)
        try FileManager.default.removeItem(at: file)
        let updates = known.snapshot()
        assert(updates.count >= 2)
        assert(updates.first!.received > 0 && updates.first!.received < size)
        assert(updates.last == TVDownloadProgress(received: size, total: size))
        assert(zip(updates, updates.dropFirst()).allSatisfy { pair in pair.0.received <= pair.1.received })

        let unknown = ProgressRecorder()
        let unknownFile = try await TVDownload.fetch(base.appendingPathComponent("unknown"), limit: size + 1) { unknown.record($0) }
        try FileManager.default.removeItem(at: unknownFile)
        assert(unknown.snapshot().last?.received == size)
        assert(unknown.snapshot().allSatisfy { $0.total == nil && $0.fraction == nil })

        do {
            _ = try await TVDownload.fetch(base.appendingPathComponent("known"), limit: 1024)
            fatalError("Oversized download was accepted")
        } catch is TVFailure {}
        do {
            _ = try await TVDownload.fetch(base.appendingPathComponent("missing"), limit: size + 1)
            fatalError("HTTP error was accepted")
        } catch is TVFailure {}

        let cancelled = Task { try await TVDownload.fetch(base.appendingPathComponent("slow"), limit: size + 1) }
        try await Task.sleep(nanoseconds: 150_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancellation was ignored")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {}
        print("Download tests passed: B/KB/MB/GB/TB units, stable known-size units, unknown totals, incremental progress, size limit, HTTP failure, cancellation.")
    }
}
