import UIKit

enum TVGuestIcon {
    private static var cache: [URL: UIImage] = [:]

    static func load(bundleURL: URL, info: NSDictionary) -> UIImage? {
        if let cached = cache[bundleURL] { return cached }
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        var names: [String] = []
        func append(_ value: Any?) {
            if let name = value as? String, !name.isEmpty { names.append(name) }
            if let values = value as? [String] { names.append(contentsOf: values.reversed()) }
        }
        // The tvOS icon name usually points into Assets.car or a layered .lsr,
        // rather than the loose PNGs used by older iPhone bundles.
        for key in ["CFBundleIcons~appletv", "CFBundleIcons~tv", "CFBundleIcons"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                append(primary["CFBundleIconName"])
                append(primary["CFBundleIconFiles"])
                append(primary["CFBundleIconFile"])
            }
        }
        for key in ["CFBundleIconName", "CFBundleIconFiles", "CFBundleIconFile"] { append(info[key]) }
        names += ["App Icon - Small", "App Icon", "AppIcon", "AppIcon-small", "Icon"]
        names += TVInstaller.iconAssetNames(at: bundleURL)
        if let resources = try? FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            names += resources.filter {
                ["png", "lsr"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.lowercased().contains("icon")
            }.map(\.lastPathComponent)
        }
        var tried = Set<String>()
        for name in names where tried.insert(name).inserted {
            // Supplying the guest bundle is essential: Image(name) searches the
            // launcher's catalog, and imageWithContentsOfFile cannot decode CARs.
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) ??
                UIImage(contentsOfFile: bundleURL.appendingPathComponent(name).path) {
                cache[bundleURL] = image
                return image
            }
        }
        return nil
    }
}
