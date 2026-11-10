import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Supplied artwork exported into Apple's layered tvOS icon format.
// The catalog is generated before XcodeGen so both archives and local Xcode
// builds get the same Home Screen, App Store, and Top Shelf resources.
let root = URL(fileURLWithPath: "build/TVContainerAssets.xcassets", isDirectory: true)
let fm = FileManager.default
let info: [String: Any] = ["author": "xcode", "version": 1]
func json(_ directory: URL, _ value: [String: Any]) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
}

func png(_ url: URL, width: Int, height: Int) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    // Keep the supplied artwork intact. Two identical opaque layers provide
    // the flat rendition in Apple's required layered icon container.
    context.setFillColor(CGColor(red: 0, green: 0.35, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let imageURL = URL(fileURLWithPath: "TVContainer/Artwork/TVContainerIcon.jpg")
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
          let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let canvasRatio = CGFloat(width) / CGFloat(height)
    // Home icons fill their almost-identical canvas; Top Shelf keeps the full
    // image centered so the wider banner does not crop the supplied TV design.
    let scale = canvasRatio > 2 ? min(CGFloat(width) / CGFloat(artwork.width), CGFloat(height) / CGFloat(artwork.height))
        : max(CGFloat(width) / CGFloat(artwork.width), CGFloat(height) / CGFloat(artwork.height))
    let size = CGSize(width: CGFloat(artwork.width) * scale, height: CGFloat(artwork.height) * scale)
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: (CGFloat(width) - size.width) / 2,
                                    y: (CGFloat(height) - size.height) / 2,
                                    width: size.width, height: size.height))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func stack(_ name: String, width: Int, height: Int, scales: [Int]) throws {
    let directory = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets/\(name).imagestack")
    try json(directory, ["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]])
    for layer in ["Front", "Back"] {
        let directory = directory.appendingPathComponent("\(layer).imagestacklayer")
        try json(directory, ["info": info])
        let images = directory.appendingPathComponent("Content.imageset")
        try json(images, ["info": info, "images": scales.map { ["idiom": "tv", "scale": "\($0)x", "filename": "Layer@\($0)x.png"] }])
        for scale in scales {
            try png(images.appendingPathComponent("Layer@\(scale)x.png"), width: width * scale, height: height * scale)
        }
    }
}

try json(root, ["info": info])
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try json(brand, ["info": info, "assets": [
    ["idiom": "tv", "size": "400x240", "filename": "App Icon - Small.imagestack", "role": "primary-app-icon"],
    ["idiom": "tv", "size": "1280x768", "filename": "App Icon - Large.imagestack", "role": "primary-app-icon"],
    ["idiom": "tv", "size": "1920x720", "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"]
]])
try stack("App Icon - Small", width: 400, height: 240, scales: [1, 2])
try stack("App Icon - Large", width: 1280, height: 768, scales: [1])
let shelf = brand.appendingPathComponent("Top Shelf Image.imageset")
try json(shelf, ["info": info, "images": [1, 2].map { ["idiom": "tv", "scale": "\($0)x", "filename": "Shelf@\($0)x.png"] }])
for scale in [1, 2] {
    try png(shelf.appendingPathComponent("Shelf@\(scale)x.png"), width: 1920 * scale, height: 720 * scale)
}
print("Generated layered Apple TV Home Screen icon and Top Shelf artwork.")
