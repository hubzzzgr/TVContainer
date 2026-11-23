import Foundation

struct TVTopShelfEntry: Codable {
    let id: String
    let title: String
    let artwork: String

    var launchURL: URL? {
        var components = URLComponents()
        components.scheme = "tvcontainer"
        components.host = "top-shelf"
        components.queryItems = [URLQueryItem(name: "app", value: id)]
        return components.url
    }
}

enum TVTopShelfCatalog {
    static let filename = "InstalledApps.json"

    static func directory() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TVTopShelfAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return root.appendingPathComponent("Library/Caches/TVContainerTopShelf", isDirectory: true)
    }
}
