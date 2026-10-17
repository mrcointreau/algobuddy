import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Algorand address")
struct AlgorandAddressTests {
    /// A real mainnet block proposer, so the checksum is known-good.
    static let valid = "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ"

    @Test("decodes a real address")
    func decodes() throws {
        let address = try AlgorandAddress(Self.valid)
        #expect(address.publicKey.count == 32)
    }

    @Test("round-trips back to the same string")
    func roundTrip() throws {
        #expect(try AlgorandAddress(Self.valid).stringValue == Self.valid)
    }

    /// The point of validating the checksum at all: one mistyped character
    /// leaves a well-formed address that algod refuses with a bare 400.
    @Test("rejects a single-character typo")
    func rejectsTypo() throws {
        var typo = Array(Self.valid)
        typo[3] = typo[3] == "S" ? "T" : "S"
        #expect(throws: AlgorandAddress.AddressError.checksumMismatch) {
            try AlgorandAddress(String(typo))
        }
    }

    @Test("rejects wrong length")
    func rejectsLength() {
        #expect(throws: (any Error).self) { try AlgorandAddress("ABC") }
    }

    @Test("rejects characters outside the base32 alphabet")
    func rejectsAlphabet() {
        let bad = String(Self.valid.dropLast()) + "1"  // The base32 alphabet has no 0, 1, 8 or 9.
        #expect(throws: (any Error).self) { try AlgorandAddress(bad) }
    }

    @Test("accepts surrounding whitespace and lowercase")
    func normalises() throws {
        let messy = "  " + Self.valid.lowercased() + "\n"
        #expect(try AlgorandAddress(messy).stringValue == Self.valid)
    }

    @Test("base32 round-trips arbitrary 36-byte payloads")
    func base32RoundTrip() throws {
        let bytes = (0..<36).map { UInt8($0 &* 7 &+ 3) }
        let decoded = try Base32.decode(Base32.encode(bytes))
        #expect(Array(decoded.prefix(36)) == bytes)
    }
}
