import XCTest
import UIKit

final class TVGuestIconTests: XCTestCase {
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
