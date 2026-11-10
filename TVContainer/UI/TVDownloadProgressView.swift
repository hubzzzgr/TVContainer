import SwiftUI

struct TVDownloadProgressView: View {
    let progress: TVDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction, total: 1)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(.blue)
            .frame(height: 12)
            HStack(spacing: 16) {
                Text("Downloaded").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(progress.received.formatted()).frame(width: 190, alignment: .trailing)
                    Text("/")
                    Text(progress.total?.formatted() ?? "—").frame(width: 190, alignment: .trailing)
                    Text("bytes")
                }
                Text(progress.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 22, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
