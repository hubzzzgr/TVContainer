import UIKit

struct TVGuest: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
    let icon: UIImage?

    var artworkAspectRatio: CGFloat {
        guard let icon, icon.size.width > 0, icon.size.height > 0 else { return 5 / 3 }
        return icon.size.width / icon.size.height
    }
}
