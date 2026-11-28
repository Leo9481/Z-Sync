import CryptoKit
import Foundation

/// Web Push message encryption (RFC 8291) in the "aes128gcm" content coding
/// (RFC 8188): what Firefox's Send Tab uses for the tab it sends.
///
/// One record only: a sent tab is a few hundred bytes.
enum WebPushECE {
    enum Failure: Error {
        case badKey
        case badMessage
    }

    /// The record size written into the header. Readers accept any size at
    /// least as large as the one record; Firefox writes 4096.
    private static let recordSize = 4096

    /// Encrypts `plaintext` for the receiver's P-256 public key (65 bytes,
    /// uncompressed) and 16-byte auth secret.
    static func encrypt(_ plaintext: Data, receiverKey: Data, authSecret: Data) throws -> Data {
        guard let receiver = try? P256.KeyAgreement.PublicKey(x963Representation: receiverKey) else {
            throw Failure.badKey
        }
        let sender = P256.KeyAgreement.PrivateKey()
        let senderKey = sender.publicKey.x963Representation
        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        let salt = try SyncCrypto.secureRandomBytes(16)
        let (key, nonce) = keyAndNonce(
            shared: shared,
            authSecret: authSecret,
            receiverKey: receiverKey,
            senderKey: senderKey,
            salt: salt
        )
        // The last (only) record ends with the delimiter 0x02 and no padding.
        var padded = plaintext
        padded.append(0x02)
        let size = max(recordSize, padded.count + 16)
        let sealed = try AES.GCM.seal(padded, using: key, nonce: AES.GCM.Nonce(data: nonce))

        var out = Data()
        out.append(salt)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(size).bigEndian, Array.init))
        out.append(UInt8(senderKey.count))
        out.append(senderKey)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypts a message sent to `privateKey` with `authSecret`.
    static func decrypt(_ message: Data, privateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let bytes = [UInt8](message)
        guard bytes.count > 21 else { throw Failure.badMessage }
        let salt = Data(bytes[0..<16])
        let idLength = Int(bytes[20])
        let headerLength = 21 + idLength
        guard idLength == 65, bytes.count > headerLength + 16 else { throw Failure.badMessage }
        let senderKey = Data(bytes[21..<headerLength])
        guard let sender = try? P256.KeyAgreement.PublicKey(x963Representation: senderKey) else {
            throw Failure.badKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: sender)
        let (key, nonce) = keyAndNonce(
            shared: shared,
            authSecret: authSecret,
            receiverKey: privateKey.publicKey.x963Representation,
            senderKey: senderKey,
            salt: salt
        )
        let body = Data(bytes[headerLength...])
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        var padded = [UInt8](try AES.GCM.open(box, using: key))
        // Padding is zeros after the delimiter (0x02 for the last record).
        while let last = padded.last, last == 0 { padded.removeLast() }
        guard let delimiter = padded.last, delimiter == 0x02 || delimiter == 0x01 else {
            throw Failure.badMessage
        }
        padded.removeLast()
        return Data(padded)
    }

    /// RFC 8291 section 3.4 and RFC 8188 section 2.2.
    private static func keyAndNonce(
        shared: SharedSecret,
        authSecret: Data,
        receiverKey: Data,
        senderKey: Data,
        salt: Data
    ) -> (SymmetricKey, Data) {
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(receiverKey)
        keyInfo.append(senderKey)
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: keyInfo,
            outputByteCount: 32
        )
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16
        )
        let nonce = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12
        )
        return (cek, nonce.withUnsafeBytes { Data($0) })
    }
}

extension Data {
    /// Base64url without padding, as Firefox Accounts writes it.
    var base64URLNoPad: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads base64url, with or without padding.
    init?(base64URL string: String) {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}
