import Foundation

struct TVDownloadProgress: Sendable, Equatable {
    let received: Int64
    let total: Int64?

    init(received: Int64 = 0, total: Int64? = nil) {
        self.received = max(0, received)
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
    }

    var fraction: Double? {
        total.map { min(1, Double(received) / Double($0)) }
    }

    // Choose one unit from the complete download size so the counter does not
    // switch units while a known-length download is in progress.
    var unitIndex: Int {
        var size = total ?? received
        var index = 0
        while size >= 1_000 && index < 6 {
            size /= 1_000
            index += 1
        }
        return index
    }

    var unit: String { ["B", "KB", "MB", "GB", "TB", "PB", "EB"][unitIndex] }
    var receivedText: String { formattedSize(received) }
    var totalText: String { total.map(formattedSize) ?? "—" }

    private func formattedSize(_ bytes: Int64) -> String {
        let value = Double(bytes) / pow(1_000, Double(unitIndex))
        return value.formatted(.number.precision(.fractionLength(unitIndex == 0 ? 0 : 2)))
    }
}
