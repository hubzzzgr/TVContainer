import CryptoKit
import TVServices
import UIKit

@MainActor
enum TVTopShelfPublisher {
    static func publish(_ guests: [TVGuest]) {
        guard let directory = TVTopShelfCatalog.directory() else { return }
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let entries = try guests.compactMap { guest -> TVTopShelfEntry? in
                guard guest.id.hasSuffix(".app"), UUID(uuidString: String(guest.id.dropLast(4))) != nil else { return nil }
                let data = artwork(for: guest)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let name = "\(hash).png"
                let imageURL = directory.appendingPathComponent(name)
                if !files.fileExists(atPath: imageURL.path) { try data.write(to: imageURL, options: .atomic) }
                return TVTopShelfEntry(id: guest.id, title: guest.name, artwork: name)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(entries)
            let manifest = directory.appendingPathComponent(TVTopShelfCatalog.filename)
            guard (try? Data(contentsOf: manifest)) != data else { return }
            try data.write(to: manifest, options: .atomic)
            TVTopShelfContentProvider.topShelfContentDidChange()

            let artwork = Set(entries.map(\.artwork))
            for file in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "png" && !artwork.contains(file.lastPathComponent) {
                try? files.removeItem(at: file)
            }
        } catch {
            NSLog("TVContainer could not update Top Shelf content.")
        }
    }

    private static func artwork(for guest: TVGuest) -> Data {
        let size = CGSize(width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 0.09, green: 0.14, blue: 0.23, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let icon = guest.icon, icon.size.width > 0, icon.size.height > 0 {
                let scale = min(size.width / icon.size.width, size.height / icon.size.height)
                let width = icon.size.width * scale
                let height = icon.size.height * scale
                icon.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
            } else {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingTail
                (guest.name as NSString).draw(in: CGRect(x: 24, y: 150, width: 592, height: 64), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ])
            }
        }
    }
}
