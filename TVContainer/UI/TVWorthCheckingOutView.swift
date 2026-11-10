import SwiftUI
import CoreImage.CIFilterBuiltins

enum TVProjectLinks {
    static let liveContainer = URL(string: "https://github.com/LiveContainer/LiveContainer")!
    static let sideTVStore = URL(string: "https://github.com/hubzzzgr/SideStore-tvOS")!
}

enum TVQRCode {
    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct TVProjectRecommendations: View {
    var body: some View {
        HStack(alignment: .top, spacing: 44) {
            project(name: "LiveContainer", description: "original project (big thanks)", url: TVProjectLinks.liveContainer)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 650)
            project(name: "SideTVStore", description: "My other project: install apple tv apps directly from your iphone without a mac or PC",
                    url: TVProjectLinks.sideTVStore)
        }
    }

    private func project(name: String, description: String, url: URL) -> some View {
        VStack(spacing: 24) {
            (Text(name).font(.title.bold()) + Text(" - \(description)").font(.title3).foregroundColor(.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .top)
            if let image = TVQRCode.image(for: url) {
                Image(uiImage: image).renderingMode(.original)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 320, height: 320)
                    .padding(44).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code linking to \(url.absoluteString)")
            } else {
                Text("QR code unavailable").frame(width: 408, height: 408)
            }
            Text(url.absoluteString).font(.system(size: 20))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineLimit(2).frame(height: 54)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .focusable()
        .accessibilityElement(children: .combine)
    }
}

struct TVWorthCheckingOutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack {
                    Text("Worth checking out").font(.largeTitle.bold())
                    Spacer()
                    Button("Back", systemImage: "chevron.left") { dismiss() }
                }
                TVProjectRecommendations()
            }
            .padding(64)
        }
        .onExitCommand { dismiss() }
    }
}
