import Foundation

/// A validated Algorand address.
///
/// The wire form is 58 characters of unpadded RFC 4648 base32 encoding 36
/// bytes: a 32-byte Ed25519 public key followed by a 4-byte checksum, which is
/// the last 4 bytes of `SHA-512/256(publicKey)`.
///
/// Validating the checksum matters more here than it looks: a mistyped address
/// silently monitors an account that does not exist, and the user would see a
/// permanently healthy-looking dashboard for a node that is actually suspended.
public struct AlgorandAddress: Hashable, Sendable {
    public static let stringLength = 58
    public static let publicKeyLength = 32
    public static let checksumLength = 4

    /// The 32-byte Ed25519 public key. Challenge bit-matching operates on these
    /// raw bytes, not on the base32 text.
    public let publicKey: [UInt8]

    public init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == Self.stringLength else {
            throw AddressError.badLength(trimmed.count)
        }
        let decoded = try Base32.decode(trimmed)
        guard decoded.count >= Self.publicKeyLength + Self.checksumLength else {
            throw AddressError.badLength(decoded.count)
        }
        let key = Array(decoded[0..<Self.publicKeyLength])
        let checksum = Array(
            decoded[Self.publicKeyLength..<(Self.publicKeyLength + Self.checksumLength)])
        let expected = Array(SHA512_256.hash(key).suffix(Self.checksumLength))
        guard checksum == expected else { throw AddressError.checksumMismatch }
        self.publicKey = key
    }

    public var stringValue: String {
        let checksum = SHA512_256.hash(publicKey).suffix(Self.checksumLength)
        return Base32.encode(publicKey + checksum)
    }

    public enum AddressError: Error, Equatable, Sendable {
        case badLength(Int)
        case invalidCharacter(Character)
        case checksumMismatch
    }
}

extension AlgorandAddress: CustomStringConvertible {
    public var description: String { stringValue }
}

/// Unpadded RFC 4648 base32, the encoding Algorand addresses use.
enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ string: String) throws -> [UInt8] {
        var buffer: UInt32 = 0
        var bits = 0
        var out = [UInt8]()
        out.reserveCapacity(string.count * 5 / 8)

        for character in string {
            guard let index = alphabet.firstIndex(of: character) else {
                throw AlgorandAddress.AddressError.invalidCharacter(character)
            }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits - 8)))
                bits -= 8
            }
        }
        return out
    }

    static func encode(_ bytes: [UInt8]) -> String {
        var buffer: UInt32 = 0
        var bits = 0
        var out = String()
        out.reserveCapacity((bytes.count * 8 + 4) / 5)

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return out
    }
}
