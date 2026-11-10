import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Deterministic vector artwork exported into Apple's layered tvOS icon format.
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

func png(_ url: URL, width: Int, height: Int, background: Bool, foreground: Bool) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    if background {
        let colors = [CGColor(red: 0.025, green: 0.10, blue: 0.28, alpha: 1),
                      CGColor(red: 0.025, green: 0.43, blue: 0.85, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])
    }
    if foreground {
        let scale = min(CGFloat(width) / 400, CGFloat(height) / 240)
        context.translateBy(x: (CGFloat(width) - 400 * scale) / 2, y: (CGFloat(height) - 240 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.setLineWidth(7)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
        context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 67, width: 208, height: 131), cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.strokePath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(red: 0.035, green: 0.16, blue: 0.38, alpha: 0.85))
        context.addPath(CGPath(roundedRect: CGRect(x: 87, y: 55, width: 208, height: 131), cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.drawPath(using: .fillStroke)
        context.setLineWidth(7)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 171, y: 42)); context.addLine(to: CGPoint(x: 211, y: 42)); context.strokePath()
        context.move(to: CGPoint(x: 191, y: 55)); context.addLine(to: CGPoint(x: 191, y: 42)); context.strokePath()
        context.setFillColor(CGColor(red: 0.23, green: 0.93, blue: 1, alpha: 1))
        context.move(to: CGPoint(x: 174, y: 92)); context.addLine(to: CGPoint(x: 174, y: 149))
        context.addLine(to: CGPoint(x: 220, y: 120)); context.closePath(); context.fillPath()
    }
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
            try png(images.appendingPathComponent("Layer@\(scale)x.png"), width: width * scale, height: height * scale,
                    background: layer == "Back", foreground: layer == "Front")
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
    try png(shelf.appendingPathComponent("Shelf@\(scale)x.png"), width: 1920 * scale, height: 720 * scale, background: true, foreground: true)
}
print("Generated layered Apple TV Home Screen icon and Top Shelf artwork.")
