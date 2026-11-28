import CryptoKit
import Foundation
import UIKit

/// A device on the Firefox account that can receive tabs.
struct SendTabDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// "desktop", "mobile", "tablet", … as the device reports itself.
    let type: String
    let lastSeen: Date?
    /// The device's send-tab keys, as published (encrypted with the account's Sync key).
    fileprivate let keysPayload: String

    var symbolName: String {
        switch type {
        case "mobile": return "iphone"
        case "tablet": return "ipad"
        case "tv": return "tv"
        case "vr": return "visionpro"
        default: return "laptopcomputer"
        }
    }
}

/// A tab another device sent to this one.
struct ReceivedTab: Sendable {
    let url: URL
    let title: String
}

enum SendTabError: LocalizedError {
    case notSignedIn
    case deviceKeysUnreadable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with your Firefox account to send tabs."
        case .deviceKeysUnreadable:
            return "That device's keys can't be read. Open Firefox or Zen on it once, then try again."
        case .server(let message):
            return message
        }
    }
}

/// Firefox's "Send Tab to Device" over Firefox Account device commands, the
/// same protocol Firefox and Zen use (see mozilla/application-services,
/// fxa-client `commands/send_tab.rs`):
///
/// - This app registers itself as a device on the account and publishes its
///   send-tab keys (a P-256 key and an auth secret), encrypted with the
///   account's Sync key, under the `open-uri` command. Desktop Zen then lists
///   it in "Send to device".
/// - To send, it reads the target device's published keys, encrypts the tab
///   for them (Web Push aes128gcm) and asks the account server to deliver it.
/// - Tabs sent here wait on the server; the app collects them when it comes
///   to the front (it has no Mozilla push credentials).
///
/// Shared by the app and the share extension through the App Group.
actor SendTabService {
    static let shared = SendTabService()

    static let command = "https://identity.mozilla.com/cmd/open-uri"

    private let client = FxAClient()

    /// What this device keeps: its keys, its device record and how far it has
    /// read the commands sent to it.
    private struct State: Codable {
        var privateKey: Data
        var authSecret: Data
        var deviceID: String?
        /// Which session registered the device: a new sign-in is a new device.
        var sessionHash: String?
        var registeredAt: Date?
        var commandIndex: Int = 0
    }

    /// In the Keychain, like the account itself (the private key is a secret),
    /// shared with the share extension through the keychain access group.
    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.leo9481.zenbrowser.sendtab",
        kSecAttrAccount as String: "device"
    ]

    private func loadState() -> State? {
        var query = Self.keychain
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(Self.keychain as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var entry = Self.keychain
        entry.merge(attributes) { $1 }
        SecItemAdd(entry as CFDictionary, nil)
    }

    private func account() throws -> AccountSnapshot {
        guard let account = AccountStore.load(), !account.isDemo else { throw SendTabError.notSignedIn }
        return account
    }

    private static func hash(_ text: String) -> String {
        FxACrypto.hex(Data(SHA256.hash(data: Data(text.utf8))))
    }

    // MARK: - Registering

    /// Registers this app as a device that receives tabs, once per session and
    /// again each day, so the record keeps its keys and name.
    func registerIfNeeded() async throws {
        let account = try account()
        let fresh = State(
            privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation,
            authSecret: try SyncCrypto.secureRandomBytes(16)
        )
        var state = loadState() ?? fresh
        let session = Self.hash(account.sessionTokenHex)
        if state.sessionHash == session, state.deviceID != nil,
           let at = state.registeredAt, Date().timeIntervalSince(at) < 24 * 3600 {
            return
        }
        if state.sessionHash != session {
            // A new session has no device yet; what came before was another device.
            state.deviceID = nil
            state.commandIndex = 0
        }
        let keys = try publishedKeys(state: state, kBHex: account.kBHex)
        let name = await MainActor.run { "Z-Browser on \(UIDevice.current.model)" }
        var body: [String: Any] = [
            "name": name,
            "type": "mobile",
            "availableCommands": [Self.command: keys]
        ]
        if let id = state.deviceID { body["id"] = id }
        let response: Any
        do {
            response = try await client.deviceAPI(path: "account/device", method: "POST", sessionTokenHex: account.sessionTokenHex, json: body)
        } catch where state.deviceID != nil {
            // The record may be gone (removed on another device): start a new one.
            body["id"] = nil
            response = try await client.deviceAPI(path: "account/device", method: "POST", sessionTokenHex: account.sessionTokenHex, json: body)
        }
        guard let id = (response as? [String: Any])?["id"] as? String else {
            throw SendTabError.server("The account didn't accept this device.")
        }
        state.deviceID = id
        state.sessionHash = session
        state.registeredAt = Date()
        save(state)
    }

    /// This device's public keys, encrypted with the account's Sync key the
    /// way Firefox publishes them: `{"kid", "IV", "hmac", "ciphertext"}` as a string.
    private func publishedKeys(state: State, kBHex: String) throws -> String {
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: state.privateKey)
        let plain: [String: String] = [
            "publicKey": privateKey.publicKey.x963Representation.base64URLNoPad,
            "authSecret": state.authSecret.base64URLNoPad
        ]
        let kB = try FxACrypto.unhex(kBHex)
        let sealed = try SyncCrypto.encryptBSO(
            plaintext: try JSONSerialization.data(withJSONObject: plain),
            keys: SyncCrypto.syncKeyBundle(fromKB: kB)
        )
        guard var envelope = try JSONSerialization.jsonObject(with: Data(sealed.utf8)) as? [String: Any] else {
            throw SendTabError.server("Couldn't prepare this device's keys.")
        }
        envelope["kid"] = FxACrypto.hex(FxACrypto.clientStateBytes(kB: kB))
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Sending

    /// The account's other devices that receive tabs, most recently used first.
    func devices() async throws -> [SendTabDevice] {
        let account = try account()
        try? await registerIfNeeded()
        let response = try await client.deviceAPI(path: "account/devices", method: "GET", sessionTokenHex: account.sessionTokenHex)
        guard let list = response as? [[String: Any]] else { return [] }
        return list.compactMap { item -> SendTabDevice? in
            guard (item["isCurrentDevice"] as? Bool) != true,
                  let id = item["id"] as? String,
                  let commands = item["availableCommands"] as? [String: Any],
                  let keys = commands[Self.command] as? String
            else { return nil }
            let seen = (item["lastAccessTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return SendTabDevice(
                id: id,
                name: (item["name"] as? String) ?? "Device",
                type: (item["type"] as? String) ?? "desktop",
                lastSeen: seen,
                keysPayload: keys
            )
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    /// Sends one tab to `device`.
    func send(url: URL, title: String, to device: SendTabDevice) async throws {
        let account = try account()
        // Delivered from a registered device, so the other end can say where it came from.
        try? await registerIfNeeded()
        let kB = try FxACrypto.unhex(account.kBHex)

        // The device's keys: decrypted with the account's Sync key.
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(device.keysPayload.utf8)) as? [String: Any],
              let kid = envelope["kid"] as? String,
              kid.lowercased() == FxACrypto.hex(FxACrypto.clientStateBytes(kB: kB)),
              let plain = try? SyncCrypto.decryptBSO(payloadJSON: device.keysPayload, keys: SyncCrypto.syncKeyBundle(fromKB: kB)),
              let keys = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let publicKey = (keys["publicKey"] as? String).flatMap(Data.init(base64URL:)),
              let authSecret = (keys["authSecret"] as? String).flatMap(Data.init(base64URL:))
        else { throw SendTabError.deviceKeysUnreadable }

        let payload: [String: Any] = [
            "entries": [["title": title, "url": url.absoluteString, "private": false]],
            "flowID": Self.randomID(),
            "streamID": Self.randomID()
        ]
        let encrypted = try WebPushECE.encrypt(
            try JSONSerialization.data(withJSONObject: payload),
            receiverKey: publicKey,
            authSecret: authSecret
        )
        _ = try await client.deviceAPI(
            path: "account/devices/invoke_command",
            method: "POST",
            sessionTokenHex: account.sessionTokenHex,
            json: [
                "command": Self.command,
                "target": device.id,
                "payload": ["encrypted": encrypted.base64URLNoPad]
            ]
        )
    }

    private static func randomID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<12).map { _ in letters.randomElement()! })
    }

    // MARK: - Receiving

    /// The tabs other devices sent here since the last look, oldest first.
    func receive() async throws -> [ReceivedTab] {
        let account = try account()
        try await registerIfNeeded()
        guard var state = loadState() else { return [] }
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: state.privateKey)
        var tabs: [ReceivedTab] = []
        // A few pages at most per look; anything left waits for the next.
        for _ in 0..<5 {
            let response = try await client.deviceAPI(
                path: "account/device/commands?index=\(state.commandIndex + 1)",
                method: "GET",
                sessionTokenHex: account.sessionTokenHex
            )
            guard let object = response as? [String: Any] else { break }
            for message in (object["messages"] as? [[String: Any]]) ?? [] {
                guard let data = message["data"] as? [String: Any],
                      data["command"] as? String == Self.command,
                      let payload = data["payload"] as? [String: Any],
                      let encrypted = (payload["encrypted"] as? String).flatMap(Data.init(base64URL:)),
                      let plain = try? WebPushECE.decrypt(encrypted, privateKey: privateKey, authSecret: state.authSecret),
                      let body = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
                      let entries = body["entries"] as? [[String: Any]]
                else { continue }
                // Firefox sends one entry per tab; the last is the page itself.
                if let entry = entries.last,
                   let link = (entry["url"] as? String).flatMap(URL.init(string:)),
                   let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    tabs.append(ReceivedTab(url: link, title: (entry["title"] as? String) ?? ""))
                }
            }
            if let index = (object["index"] as? NSNumber)?.intValue, index > state.commandIndex {
                state.commandIndex = index
            }
            save(state)
            if (object["last"] as? Bool) != false { break }
        }
        return tabs
    }
}
