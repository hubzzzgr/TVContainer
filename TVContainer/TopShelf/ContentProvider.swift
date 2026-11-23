import Foundation
import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let directory = TVTopShelfCatalog.directory(),
              let data = try? Data(contentsOf: directory.appendingPathComponent(TVTopShelfCatalog.filename)),
              let entries = try? JSONDecoder().decode([TVTopShelfEntry].self, from: data) else {
            completionHandler(nil)
            return
        }
        let items = entries.compactMap { entry -> TVTopShelfSectionedItem? in
            guard let url = entry.launchURL,
                  URL(fileURLWithPath: entry.artwork).lastPathComponent == entry.artwork,
                  entry.artwork.hasSuffix(".png") else { return nil }
            let image = directory.appendingPathComponent(entry.artwork)
            guard FileManager.default.fileExists(atPath: image.path) else { return nil }
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.title
            item.imageShape = .hdtv
            item.setImageURL(image, for: .screenScale1x)
            item.setImageURL(image, for: .screenScale2x)
            let launch = TVTopShelfAction(url: url)
            item.displayAction = launch
            item.playAction = launch
            return item
        }
        guard !items.isEmpty else { completionHandler(nil); return }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Installed Apps"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }
}
