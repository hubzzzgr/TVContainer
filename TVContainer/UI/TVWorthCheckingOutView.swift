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
        guard let code = filter.outputImage else { return nil }
        // A four-module quiet zone is part of the image itself, so scanners can
        // also decode exported artwork independently of the surrounding view.
        let background = CIImage(color: CIColor.white).cropped(to: code.extent.insetBy(dx: -4, dy: -4))
        let output = code.composited(over: background).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct TVProjectRecommendations: View {
    var compact = false
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 28) {
                project(name: "LiveContainer", description: "original project (big thanks)", url: TVProjectLinks.liveContainer)
                    .frame(width: (geometry.size.width - 57) / 2)
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: compact ? 560 : 760)
                project(name: "SideTVStore", description: "My other project: install apple tv apps directly from your iphone without a mac or PC",
                        url: TVProjectLinks.sideTVStore)
                    .frame(width: (geometry.size.width - 57) / 2)
            }
        }
        .frame(height: compact ? 560 : 760)
    }

    private func project(name: String, description: String, url: URL) -> some View {
        VStack(spacing: compact ? 18 : 24) {
            (Text(name).font(.title.bold()) + Text(" - \(description)").font(.title3).foregroundColor(.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 140 : 210, alignment: .top)
            if let image = TVQRCode.image(for: url) {
                Image(uiImage: image).renderingMode(.original)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: compact ? 240 : 320, height: compact ? 240 : 320)
                    .padding(compact ? 16 : 24).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code linking to \(url.absoluteString)")
            } else {
                Text("QR code unavailable").frame(width: compact ? 272 : 368, height: compact ? 272 : 368)
            }
            Text(url.absoluteString).font(.system(size: 20))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineLimit(2).frame(height: 54)
        }
        .padding(compact ? 24 : 32)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 560 : 760, alignment: .top)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .focusable()
        .accessibilityElement(children: .combine)
    }
}

struct TVWorthCheckingOutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Worth checking out").font(.largeTitle.bold())
                TVProjectRecommendations(compact: true)
            }
            .padding(40)
        }
    }
}
