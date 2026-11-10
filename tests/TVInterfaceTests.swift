import XCTest
import SwiftUI
import Vision

final class TVInterfaceTests: XCTestCase {
    func testQRCodeDestinations() throws {
        for url in [TVProjectLinks.liveContainer, TVProjectLinks.sideTVStore] {
            let image = try XCTUnwrap(TVQRCode.image(for: url)?.cgImage)
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            XCTAssertEqual(request.results?.first?.payloadStringValue, url.absoluteString)
        }
    }

    @MainActor
    func testRecommendationsPreview() throws {
        let content = VStack(alignment: .leading, spacing: 40) {
            Text("Worth checking out").font(.largeTitle.bold())
            TVProjectRecommendations()
        }
        .padding(64).frame(width: 1920).background(Color(red: 0.025, green: 0.04, blue: 0.08))
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Worth checking out - two project QR codes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProgressPreviewHasStableDimensions() throws {
        let states = [TVDownloadProgress(received: 1, total: 2_147_483_648),
                      TVDownloadProgress(received: 2_000_000_000, total: 2_147_483_648),
                      TVDownloadProgress(received: 400_000)]
        var size: CGSize?
        for (index, progress) in states.enumerated() {
            let content = TVDownloadProgressView(progress: progress)
                .frame(width: 1000).padding(40).background(.black)
                .foregroundStyle(.white).environment(\.colorScheme, .dark)
            let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
            if let size { XCTAssertEqual(image.size, size) }
            size = image.size
            let attachment = XCTAttachment(image: image)
            attachment.name = "Download progress state \(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
