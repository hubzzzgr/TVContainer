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
}
