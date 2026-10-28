import CryptoKit
import Foundation
import Security

/// RFC 7636 proof key for one authorization request.
///
/// The verifier is 32 bytes from `SecRandomCopyBytes`, base64url-encoded without padding, which gives
/// the 43-character minimum the RFC asks for. The challenge is `BASE64URL(SHA256(ASCII(verifier)))`.
struct PKCE: Sendable, CustomStringConvertible {
    static let method = "S256"
    static let verifierLength = 43...128

    let verifier: String
    let challenge: String

    init() throws {
        try self.init(verifier: SecureRandom.urlSafeString(byteCount: 32))
    }

    init(verifier: String) throws {
        guard Self.isValidVerifier(verifier) else { throw SecureRandom.Failure.invalidVerifier }
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// 43–128 characters from the unreserved set `[A-Z] [a-z] [0-9] - . _ ~`.
    static func isValidVerifier(_ candidate: String) -> Bool {
        verifierLength.contains(candidate.utf8.count) && candidate.utf8.allSatisfy(isUnreserved)
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    /// Never prints the verifier: it is the secret half of the proof.
    var description: String { "PKCE(method: \(Self.method), verifier: redacted)" }
}

/// Unguessable values for one sign-in: `state` binds the browser redirect to this flow, `nonce`
/// binds the returned id_token to it.
enum SecureRandom {
    enum Failure: Error, Equatable {
        case randomUnavailable(OSStatus)
        case invalidVerifier
    }

    static func bytes(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else { throw Failure.randomUnavailable(status) }
        return Data(buffer)
    }

    static func urlSafeString(byteCount: Int) throws -> String {
        try bytes(byteCount).base64URLEncodedString()
    }

    /// 16 bytes → 22 base64url characters.
    static func state() throws -> String { try urlSafeString(byteCount: 16) }

    /// 16 bytes → 22 base64url characters.
    static func nonce() throws -> String { try urlSafeString(byteCount: 16) }
}

extension Data {
    /// RFC 4648 §5 alphabet, no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url with or without padding (JWT segments arrive without it).
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
