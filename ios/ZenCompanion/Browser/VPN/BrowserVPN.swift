import Foundation
import Network
import Observation
import Security
import WebKit

/// The browser-only VPN: the browser's traffic, and only the browser's, goes
/// through one of the reader's WireGuard servers (Proton VPN configs).
///
/// Servers are grouped in profiles ("Italy", "US", ...): one profile is in
/// use at a time, and its servers are the fallbacks for each other.
///
/// The tunnel runs in the app (go/zbwg: wireguard-go in user space) behind a
/// SOCKS5 proxy on 127.0.0.1 with a random password, and WebKit's data stores
/// are pointed at that proxy. The profile's servers are tried in order until
/// one carries traffic; a server that stops answering hands over to the next.
/// If none answers, the VPN turns itself off and says so.
///
/// While it is on but not connected, pages don't load at all: the proxy
/// points nowhere rather than letting traffic out without the tunnel.
@MainActor
@Observable
final class BrowserVPN {
    static let shared = BrowserVPN()

    struct Server: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        /// The WireGuard config's text. Holds a private key: Keychain only.
        var config: String
    }

    /// A named set of servers, tried in their order.
    struct Profile: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var servers: [Server] = []
    }

    enum Status: Equatable {
        case off
        case connecting(String)
        case connected(String)
    }

    private(set) var profiles: [Profile] = []
    /// The profile in use. Kept in UserDefaults: an id, not a secret.
    private(set) var activeProfileID: UUID? {
        didSet { UserDefaults.standard.set(activeProfileID?.uuidString, forKey: Self.profileKey) }
    }
    private(set) var status: Status = .off
    /// Set when every server failed and the VPN turned itself off.
    var allFailedMessage: String?

    var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            enabledChanged()
        }
    }

    /// Stored, so views watching `isEnabled` update.
    private var enabled = UserDefaults.standard.bool(forKey: BrowserVPN.enabledKey)

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    /// The servers of the profile in use.
    var servers: [Server] { activeProfile?.servers ?? [] }

    /// Profiles that can be switched to: the ones with servers.
    var usableProfiles: [Profile] { profiles.filter { !$0.servers.isEmpty } }

    private static let enabledKey = "browserVPN.enabled"
    private static let profileKey = "browserVPN.profile"
    private let proxyUser = UUID().uuidString
    private let proxyPass = UUID().uuidString
    private var port: Int?
    private var connectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// The server in use, so a failover starts with the one after it.
    private var currentIndex = 0

    private init() {
        profiles = Self.loadProfiles()
        activeProfileID = UserDefaults.standard.string(forKey: Self.profileKey).flatMap(UUID.init(uuidString:))
        if activeProfile?.id != activeProfileID { activeProfileID = activeProfile?.id }
    }

    /// At launch: brings the tunnel up if the VPN was left on.
    func start() {
        guard isEnabled else { return }
        enabledChanged()
    }

    // MARK: - Profiles

    @discardableResult
    func addProfile(name: String) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(name: trimmed.isEmpty ? "Profile \(profiles.count + 1)" : trimmed)
        profiles.append(profile)
        if activeProfileID == nil { activeProfileID = profile.id }
        saveProfiles()
        return profile
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: id) else { return }
        profiles[i].name = trimmed
        saveProfiles()
    }

    func removeProfile(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let wasActive = activeProfile?.id == id
        profiles.remove(at: i)
        saveProfiles()
        if wasActive {
            activeProfileID = profiles.first?.id
            activeServersChanged()
        }
    }

    func moveProfile(_ id: UUID, by offset: Int) {
        guard let i = index(of: id), profiles.indices.contains(i + offset) else { return }
        profiles.swapAt(i, i + offset)
        saveProfiles()
    }

    /// Makes a profile the one in use; reconnects when the VPN is on.
    func selectProfile(_ id: UUID) {
        guard index(of: id) != nil, activeProfile?.id != id else { return }
        activeProfileID = id
        activeServersChanged()
    }

    /// From the browser menu: use this profile, and turn the VPN on.
    func use(_ id: UUID) {
        guard let i = index(of: id), !profiles[i].servers.isEmpty else { return }
        if activeProfile?.id != id {
            activeProfileID = id
            if isEnabled { enabledChanged() }
        }
        if !isEnabled { isEnabled = true }
    }

    private func index(of id: UUID) -> Int? {
        profiles.firstIndex { $0.id == id }
    }

    // MARK: - Servers

    func addServer(to profileID: UUID, name: String, config: String) -> String? {
        let text = config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("[Interface]"), text.contains("[Peer]"), text.contains("PrivateKey") else {
            return "That isn't a WireGuard config."
        }
        guard let i = index(of: profileID) else { return "That profile is gone." }
        profiles[i].servers.append(Server(name: name, config: text))
        saveProfiles()
        return nil
    }

    func removeServer(_ serverID: UUID, from profileID: UUID) {
        guard let i = index(of: profileID) else { return }
        profiles[i].servers.removeAll { $0.id == serverID }
        saveProfiles()
        if profileID == activeProfile?.id { activeServersChanged() }
    }

    func moveServer(_ serverID: UUID, in profileID: UUID, by offset: Int) {
        guard let i = index(of: profileID),
              let j = profiles[i].servers.firstIndex(where: { $0.id == serverID }),
              profiles[i].servers.indices.contains(j + offset) else { return }
        profiles[i].servers.swapAt(j, j + offset)
        saveProfiles()
    }

    /// The profile in use changed, or lost servers: reconnect, or turn off
    /// when nothing is left to connect to.
    private func activeServersChanged() {
        if servers.isEmpty {
            if isEnabled { isEnabled = false }
        } else if isEnabled {
            enabledChanged()
        }
    }

    // MARK: - Connecting

    private func enabledChanged() {
        connectTask?.cancel()
        monitorTask?.cancel()
        if isEnabled, !servers.isEmpty {
            allFailedMessage = nil
            // Nothing leaves without the tunnel while it comes up.
            applyProxy(port: nil)
            let previous = connectTask
            connectTask = Task {
                // The old attempt lets go of the tunnel before this one starts.
                await previous?.value
                await connect(startingAt: 0)
            }
        } else {
            status = .off
            port = nil
            removeProxy()
            let previous = connectTask
            connectTask = Task {
                // Stopped after any attempt still starting a tunnel.
                await previous?.value
                await Task.detached { zbwg_stop() }.value
            }
        }
    }

    /// Tries each server in order, from `first` round to the one before it.
    private func connect(startingAt first: Int) async {
        let list = servers
        guard !list.isEmpty else { return }
        for step in 0..<list.count {
            if Task.isCancelled { return }
            let index = (first + step) % list.count
            let server = list[index]
            status = .connecting(server.name)
            if let port = await Self.bringUp(server.config, user: proxyUser, pass: proxyPass) {
                if Task.isCancelled { return }
                currentIndex = index
                self.port = port
                applyProxy(port: port)
                status = .connected(server.name)
                startMonitor()
                return
            }
        }
        if Task.isCancelled { return }
        // None answered: off, and said so.
        let profile = activeProfile.map { " in \u{201C}\($0.name)\u{201D}" } ?? ""
        allFailedMessage = "None of the VPN servers\(profile) answered, so the browser VPN was turned off. Pages load without it now."
        enabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        status = .off
        port = nil
        removeProxy()
        await Task.detached { zbwg_stop() }.value
    }

    /// Starts the tunnel and checks it carries traffic (a name looked up
    /// through it). The proxy's port, or nil.
    private nonisolated static func bringUp(_ config: String, user: String, pass: String) async -> Int? {
        await Task.detached(priority: .userInitiated) { () -> Int? in
            let port = config.withCString { c in
                user.withCString { u in pass.withCString { p in
                    zbwg_start(UnsafeMutablePointer(mutating: c), UnsafeMutablePointer(mutating: u), UnsafeMutablePointer(mutating: p))
                } }
            }
            guard port > 0 else {
                if let error = zbwg_last_error() {
                    NSLog("Browser VPN: %@", String(cString: error))
                    zbwg_free(error)
                }
                return nil
            }
            for _ in 0..<2 {
                let answered = "www.apple.com".withCString { zbwg_check(UnsafeMutablePointer(mutating: $0), 5000) }
                if answered == 1 { return Int(port) }
            }
            zbwg_stop()
            return nil
        }.value
    }

    /// Every 30 seconds: a server whose last handshake is older than three
    /// minutes (or never) has stopped answering; the next one takes over.
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, case .connected = self.status else { return }
                let age = await Task.detached { zbwg_last_handshake() }.value
                if age < 0 || age > 180 {
                    self.applyProxy(port: nil)
                    let next = self.currentIndex + 1
                    self.connectTask = Task { await self.connect(startingAt: next) }
                    return
                }
            }
        }
    }

    // MARK: - WebKit

    /// Points a data store at the tunnel's proxy (or nowhere, while it comes
    /// up). Called for every store the browser uses.
    func configure(_ store: WKWebsiteDataStore) {
        guard isEnabled else {
            store.proxyConfigurations = []
            return
        }
        store.proxyConfigurations = [proxyConfiguration(port: port)]
    }

    private var stores: [WKWebsiteDataStore] {
        [WKWebsiteDataStore.default()] + PrivateBrowsing.liveStores
    }

    private func applyProxy(port: Int?) {
        let configuration = proxyConfiguration(port: port)
        for store in stores { store.proxyConfigurations = [configuration] }
    }

    private func removeProxy() {
        for store in stores { store.proxyConfigurations = [] }
    }

    /// The tunnel's proxy; port 9 (discard, nothing listens) while there's no tunnel.
    private func proxyConfiguration(port: Int?) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port ?? 9)) ?? 9)
        var configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        configuration.applyCredential(username: proxyUser, password: proxyPass)
        return configuration
    }

    // MARK: - Keychain

    private static func keychain(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.leo9481.zenbrowser.vpn",
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(_ account: String) -> Data? {
        var query = keychain(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func loadProfiles() -> [Profile] {
        if let data = readKeychain("profiles") {
            return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
        }
        // A plain server list, from before profiles: one profile holding it.
        guard let data = readKeychain("servers"),
              let servers = try? JSONDecoder().decode([Server].self, from: data),
              !servers.isEmpty else { return [] }
        let profiles = [Profile(name: "My servers", servers: servers)]
        if writeKeychain("profiles", profiles) {
            SecItemDelete(keychain("servers") as CFDictionary)
        }
        return profiles
    }

    private func saveProfiles() {
        Self.writeKeychain("profiles", profiles)
    }

    @discardableResult
    private static func writeKeychain(_ account: String, _ profiles: [Profile]) -> Bool {
        guard let data = try? JSONEncoder().encode(profiles) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(keychain(account) as CFDictionary, attributes as CFDictionary) == errSecSuccess { return true }
        var entry = keychain(account)
        entry.merge(attributes) { $1 }
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }
}
