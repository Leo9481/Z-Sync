import Foundation
import Network
import Observation
import Security
import WebKit

/// The browser-only VPN: the browser's traffic, and only the browser's, goes
/// through one of the reader's WireGuard servers (Proton VPN configs).
///
/// The tunnel runs in the app (go/zbwg: wireguard-go in user space) behind a
/// SOCKS5 proxy on 127.0.0.1 with a random password, and WebKit's data stores
/// are pointed at that proxy. The servers are tried in order until one
/// carries traffic; a server that stops answering hands over to the next. If
/// none answers, the VPN turns itself off and says so.
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

    enum Status: Equatable {
        case off
        case connecting(String)
        case connected(String)
    }

    private(set) var servers: [Server] = []
    private(set) var status: Status = .off
    /// Set when every server failed and the VPN turned itself off.
    var allFailedMessage: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            enabledChanged()
        }
    }

    private static let enabledKey = "browserVPN.enabled"
    private let proxyUser = UUID().uuidString
    private let proxyPass = UUID().uuidString
    private var port: Int?
    private var connectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// The server in use, so a failover starts with the one after it.
    private var currentIndex = 0

    private init() {
        servers = Self.loadServers()
    }

    /// At launch: brings the tunnel up if the VPN was left on.
    func start() {
        guard isEnabled else { return }
        enabledChanged()
    }

    // MARK: - Servers

    func addServer(name: String, config: String) -> String? {
        let text = config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("[Interface]"), text.contains("[Peer]"), text.contains("PrivateKey") else {
            return "That isn't a WireGuard config."
        }
        servers.append(Server(name: name, config: text))
        saveServers()
        return nil
    }

    func removeServers(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
        if servers.isEmpty, isEnabled { isEnabled = false }
    }

    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        saveServers()
    }

    // MARK: - Connecting

    private func enabledChanged() {
        connectTask?.cancel()
        monitorTask?.cancel()
        if isEnabled, !servers.isEmpty {
            // Nothing leaves without the tunnel while it comes up.
            applyProxy(port: nil)
            connectTask = Task { await connect(startingAt: 0) }
        } else {
            status = .off
            port = nil
            removeProxy()
            Task.detached { zbwg_stop() }
        }
    }

    /// Tries each server in order, from `first` round to the one before it.
    private func connect(startingAt first: Int) async {
        let list = servers
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
        allFailedMessage = "None of your VPN servers answered, so the browser VPN was turned off. Pages load without it now."
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

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.leo9481.zenbrowser.vpn",
        kSecAttrAccount as String: "servers",
    ]

    private static func loadServers() -> [Server] {
        var query = keychain
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([Server].self, from: data)) ?? []
    }

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(Self.keychain as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var entry = Self.keychain
        entry.merge(attributes) { $1 }
        SecItemAdd(entry as CFDictionary, nil)
    }
}
