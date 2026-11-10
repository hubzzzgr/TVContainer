import Foundation
import CoreGraphics
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [[String: Any]]
let attachments = manifest.flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
guard let page = attachments.first(where: {
    ($0["suggestedHumanReadableName"] as? String ?? "").contains("Worth checking out - two project QR codes")
}), let file = page["exportedFileName"] as? String,
let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(file) as CFURL, nil),
let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Rendered recommendations page is missing.")
}
let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
try Data(bytes: context.data!, count: image.width * image.height * 4).write(to: output)
try JSONSerialization.data(withJSONObject: ["width": image.width, "height": image.height])
    .write(to: output.appendingPathExtension("json"))
