import Foundation

/// Links the share extension could not hand to the app directly: the app
/// opens them as new tabs the next time it comes to the front.
enum PendingOpens {
    private static let key = "share.pendingOpens"

    static func add(_ url: URL) {
        var list = AppGroup.defaults.stringArray(forKey: key) ?? []
        list.append(url.absoluteString)
        // A handful at most: these are links someone meant to open soon.
        AppGroup.defaults.set(Array(list.suffix(20)), forKey: key)
    }

    /// The waiting links, oldest first; taking them clears the list.
    static func take() -> [URL] {
        let list = AppGroup.defaults.stringArray(forKey: key) ?? []
        guard !list.isEmpty else { return [] }
        AppGroup.defaults.removeObject(forKey: key)
        return list.compactMap(URL.init(string:))
    }
}
