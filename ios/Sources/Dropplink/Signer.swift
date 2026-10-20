import CryptoKit
import Foundation

/// Request signing, exactly as `contract/hmac/vectors.json`:
/// `hex(HMAC_SHA256(key = UTF-8 secret, msg = timestamp + "\n" + hex(SHA256(body bytes))))`.
enum Signer {
    static func signature(secret: String, timestamp: String, body: Data) -> String {
        let signingString = timestamp + "\n" + sha256Hex(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingString.utf8), using: key)
        return hex(mac)
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Lower-case hex, as the server documents.
    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
