import SwiftUI

struct TVDownloadProgressView: View {
    let progress: TVDownloadProgress
    @State private var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    if let fraction = progress.fraction {
                        Capsule().fill(.blue).frame(width: geometry.size.width * fraction)
                    } else {
                        Capsule().fill(.blue).frame(width: geometry.size.width * 0.22)
                            .offset(x: geometry.size.width * (reduceMotion ? 0.39 : moving ? 0.78 : 0))
                    }
                }
                .clipped()
            }
            .frame(height: 10)
            .onAppear { animateUnknownTotal() }
            .onChange(of: progress.total == nil) { _, _ in animateUnknownTotal() }
            HStack(spacing: 16) {
                Text("Downloaded").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(progress.receivedText).frame(width: 140, alignment: .trailing)
                    Text("/")
                    Text(progress.totalText).frame(width: 140, alignment: .trailing)
                    Text(progress.unit).frame(width: 42, alignment: .leading)
                }
                .fixedSize(horizontal: true, vertical: false)
                Text(progress.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 22, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func animateUnknownTotal() {
        guard progress.total == nil && !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { moving = true }
    }
}
