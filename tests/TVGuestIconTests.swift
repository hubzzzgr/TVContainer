import XCTest
import UIKit
import SwiftUI

final class TVGuestIconTests: XCTestCase {
    @MainActor
    func testCardArtworkPreview() throws {
        func artwork(_ size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let symbol = UIImage(systemName: "appletv")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: (size.width - 120) / 2, y: (size.height - 80) / 2, width: 120, height: 80))
            }
        }
        let square = TVGuest(id: "square", name: "Square App", bundleID: "test.square", version: "4.54.01",
                             icon: artwork(CGSize(width: 240, height: 240)))
        let television = TVGuest(id: "wide", name: "Apple TV App", bundleID: "test.wide", version: "1.0.2",
                                 icon: artwork(CGSize(width: 400, height: 240)))
        let renderer = ImageRenderer(content:
            TVAppFlowLayout {
                TVGuestCard(app: square)
                TVGuestCard(app: television)
            }
            .frame(width: 700).padding(40).background(Color.black)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
        )
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Guest cards with square and widescreen artwork"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func withBundle(_ work: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "org.tvcontainer.icon-test.\(UUID().uuidString)", "CFBundleName": "Guest"]
        try (info as NSDictionary).write(to: root.appendingPathComponent("Info.plist"))
        let source = Bundle(for: Self.self).url(forResource: "Assets", withExtension: "car")!
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("Assets.car"))
        try work(root)
    }

    func testDeclaredCatalogArtwork() throws {
        try withBundle { root in
            let image = TVGuestIcon.load(bundleURL: root, info: ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "FixtureArtwork"]]])
            XCTAssertNotNil(image)
            XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        }
    }

    func testLayeredArtworkFromGuestCatalog() throws {
        try withBundle { root in
            let image = TVGuestIcon.load(bundleURL: root, info: ["CFBundleIconName": "GuestIconArtwork"])
            XCTAssertNotNil(image)
        }
    }

    func testDiscoverCatalogIconWhenMetadataIsMissing() throws {
        try withBundle { root in
            XCTAssertNotNil(TVGuestIcon.load(bundleURL: root, info: [:]))
        }
    }

    func testLoosePNGArtwork() throws {
        try withBundle { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("Assets.car"))
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
            let data = renderer.pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            try data.write(to: root.appendingPathComponent("LegacyIcon.png"))
            XCTAssertNotNil(TVGuestIcon.load(bundleURL: root, info: ["CFBundleIconFiles": ["LegacyIcon.png"]]))
        }
    }
}
