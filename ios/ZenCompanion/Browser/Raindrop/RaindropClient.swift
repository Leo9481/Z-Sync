import Foundation
import Observation
import SwiftUI

/// A Raindrop.io collection, with where it sits in the tree.
struct RaindropCollection: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let count: Int
    /// nil for a root collection.
    let parentID: Int?

    /// Raindrop's built-in collections (not in any API answer).
    static let all = 0
    static let unsorted = -1
}

/// One saved bookmark.
struct Raindrop: Identifiable, Hashable, Sendable {
    let id: Int
    let link: URL
    let title: String
    let domain: String
    let collectionID: Int?
}

enum RaindropError: LocalizedError {
    case noToken
    case badToken
    case server(Int, String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noToken: return "Add your Raindrop test token in Settings → Raindrop."
        case .badToken: return "Raindrop didn't accept the token. Check it in Settings → Raindrop."
        case .server(let status, let message): return "Raindrop: \(message) (HTTP \(status))"
        case .rateLimited: return "Raindrop is busy (too many requests). Try again in a minute."
        }
    }
}

/// Raindrop.io's REST API (https://developer.raindrop.io), with the person's
/// own test token: each person makes an app in Raindrop and pastes its test
/// token, so the app carries no secret. Test tokens don't expire.
enum RaindropAPI {
    static let base = URL(string: "https://api.raindrop.io/rest/v1/")!

    private static func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        token: String? = nil
    ) async throws -> [String: Any] {
        guard let token = token ?? RaindropToken.load() else { throw RaindropError.noToken }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300: return object
        case 401, 403: throw RaindropError.badToken
        case 429: throw RaindropError.rateLimited
        default:
            let message = (object["errorMessage"] as? String) ?? (object["error"] as? String) ?? "request failed"
            throw RaindropError.server(status, message)
        }
    }

    /// The account's name, to show the token works. `token` checks a token
    /// before it is saved.
    static func userName(token: String? = nil) async throws -> String {
        let object = try await request("user", token: token)
        let user = object["user"] as? [String: Any]
        return (user?["fullName"] as? String) ?? (user?["email"] as? String) ?? "Raindrop"
    }

    /// Every collection, root and nested.
    static func collections() async throws -> [RaindropCollection] {
        async let roots = request("collections")
        async let children = request("collections/childrens")
        let items = ((try await roots)["items"] as? [[String: Any]] ?? [])
            + ((try await children)["items"] as? [[String: Any]] ?? [])
        // The nested list can repeat collections the root list has: each
        // collection once, keeping the copy that says where it sits.
        var seen = Set<Int>()
        let parsed = items.compactMap { item -> RaindropCollection? in
            guard let id = (item["_id"] as? NSNumber)?.intValue else { return nil }
            let parent = ((item["parent"] as? [String: Any])?["$id"] as? NSNumber)?.intValue
            return RaindropCollection(
                id: id,
                title: (item["title"] as? String) ?? "Untitled",
                count: (item["count"] as? NSNumber)?.intValue ?? 0,
                parentID: parent
            )
        }
        var chosen: [Int: RaindropCollection] = [:]
        var order: [Int] = []
        for collection in parsed {
            if seen.insert(collection.id).inserted { order.append(collection.id) }
            if let kept = chosen[collection.id], kept.parentID != nil { continue }
            chosen[collection.id] = collection
        }
        return order.compactMap { chosen[$0] }
    }

    /// One page (50 at most) of a collection's bookmarks, newest first.
    static func raindrops(in collection: Int, page: Int) async throws -> [Raindrop] {
        let object = try await request(
            "raindrops/\(collection)",
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "perpage", value: "50"),
                URLQueryItem(name: "sort", value: "-created")
            ]
        )
        return ((object["items"] as? [[String: Any]]) ?? []).compactMap(raindrop(from:))
    }

    private static func raindrop(from item: [String: Any]) -> Raindrop? {
        guard let id = (item["_id"] as? NSNumber)?.intValue,
              let link = (item["link"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return Raindrop(
            id: id,
            link: link,
            title: (item["title"] as? String) ?? link.absoluteString,
            domain: (item["domain"] as? String) ?? (link.host ?? ""),
            collectionID: ((item["collection"] as? [String: Any])?["$id"] as? NSNumber)?.intValue
        )
    }

    /// Saves a page; Raindrop fills in its cover and description itself.
    /// Returns the new bookmark's id.
    @discardableResult
    static func save(_ url: URL, title: String, to collection: Int) async throws -> Int {
        var body: [String: Any] = [
            "link": url.absoluteString,
            "collection": ["$id": collection],
            "pleaseParse": [String: Any]()
        ]
        if !title.isEmpty { body["title"] = title }
        let object = try await request("raindrop", method: "POST", body: body)
        guard let id = ((object["item"] as? [String: Any])?["_id"] as? NSNumber)?.intValue else {
            throw RaindropError.server(200, "no bookmark in the answer")
        }
        return id
    }

    /// Moves a bookmark to Raindrop's Trash (it can be restored there).
    static func remove(_ id: Int) async throws {
        _ = try await request("raindrop/\(id)", method: "DELETE")
    }

    /// The ids of bookmarks already saved for `url`, if any.
    static func savedIDs(for url: URL) async throws -> [Int] {
        let object = try await request("import/url/exists", method: "POST", body: ["urls": [url.absoluteString]])
        return ((object["ids"] as? [NSNumber]) ?? []).map(\.intValue)
    }
}

/// The test token, in the Keychain.
enum RaindropToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.leo9481.zenbrowser.raindrop",
        kSecAttrAccount as String: "token"
    ]

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var entry = query
        entry.merge(attributes) { $1 }
        SecItemAdd(entry as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// What the app shows about Raindrop: connected or not, the account, the
/// collections and where the quick-save button saves.
@MainActor
@Observable
final class RaindropSettings {
    static let shared = RaindropSettings()

    private(set) var isConnected = RaindropToken.load() != nil
    private(set) var accountName: String? = UserDefaults.standard.string(forKey: "raindrop.accountName")
    private(set) var collections: [RaindropCollection] = []

    /// Where ☁ saves: Unsorted unless chosen.
    var defaultCollectionID: Int = UserDefaults.standard.object(forKey: "raindrop.defaultCollection") as? Int ?? RaindropCollection.unsorted {
        didSet { UserDefaults.standard.set(defaultCollectionID, forKey: "raindrop.defaultCollection") }
    }

    var defaultCollectionName: String {
        name(of: defaultCollectionID)
    }

    func name(of id: Int) -> String {
        if id == RaindropCollection.unsorted { return "Unsorted" }
        if id == RaindropCollection.all { return "All bookmarks" }
        return collections.first { $0.id == id }?.title ?? "Collection"
    }

    /// Checks the token with Raindrop, then keeps it.
    func connect(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = try await RaindropAPI.userName(token: trimmed)
        RaindropToken.save(trimmed)
        accountName = name
        UserDefaults.standard.set(name, forKey: "raindrop.accountName")
        isConnected = true
        await refreshCollections()
    }

    func disconnect() {
        RaindropToken.delete()
        isConnected = false
        accountName = nil
        collections = []
        UserDefaults.standard.removeObject(forKey: "raindrop.accountName")
    }

    func refreshCollections() async {
        guard isConnected, let list = try? await RaindropAPI.collections() else { return }
        collections = list
    }

    struct TreeEntry: Identifiable {
        let collection: RaindropCollection
        let depth: Int
        var id: Int { collection.id }
    }

    /// Collections in tree order with their depth, for menus.
    var collectionTree: [TreeEntry] {
        var out: [TreeEntry] = []
        // Each collection once, however the lists came back, and no loop
        // even if a collection were listed under itself.
        var placed = Set<Int>()
        func add(parent: Int?, depth: Int) {
            for collection in collections where collection.parentID == parent {
                guard placed.insert(collection.id).inserted else { continue }
                out.append(TreeEntry(collection: collection, depth: depth))
                add(parent: collection.id, depth: depth + 1)
            }
        }
        add(parent: nil, depth: 0)
        return out
    }
}

/// The collections as a menu that follows the tree: a collection with
/// sub-collections is a submenu that starts with "Save here", one without
/// is a single choice. Indenting a flat list with spaces doesn't read in a
/// menu, and two collections may share a name in different places.
struct RaindropCollectionMenu: View {
    /// nil for the top level.
    var parentID: Int? = nil
    let collections: [RaindropCollection]
    let choose: (Int) -> Void

    var body: some View {
        ForEach(collections.filter { $0.parentID == parentID }) { collection in
            if collections.contains(where: { $0.parentID == collection.id }) {
                Menu(collection.title) {
                    Button("Save here", systemImage: "tray.and.arrow.down") { choose(collection.id) }
                    Divider()
                    // A view inside its own body: erased, so its type can refer to itself.
                    AnyView(RaindropCollectionMenu(parentID: collection.id, collections: collections, choose: choose))
                }
            } else {
                Button(collection.title) { choose(collection.id) }
            }
        }
    }
}
