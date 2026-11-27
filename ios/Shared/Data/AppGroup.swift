import Foundation

enum AppGroup {
    static let id = "group.io.github.leo9481.zenbrowser"
    static let defaults = UserDefaults(suiteName: id) ?? .standard

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
    }
}
