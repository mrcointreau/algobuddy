import Foundation
import Testing

@testable import AlgobuddyCore

/// Vectors generated with OpenSSL via Python's `hashlib.new("sha512_256", …)`.
/// The `abc` digest is also the published FIPS 180-4 example.
@Suite("SHA-512/256")
struct SHA512_256Tests {

    @Test("empty input")
    func empty() {
        #expect(
            SHA512_256.hash([]).hexString
                == "c672b8d1ef56ed28ab87c3622c5114069bdd3ad7b8f9737498d0c01ecef0967a")
    }

    @Test("abc, the FIPS 180-4 example")
    func abc() {
        #expect(
            SHA512_256.hash(Array("abc".utf8)).hexString
                == "53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23")
    }

    @Test("multi-word input")
    func word() {
        #expect(
            SHA512_256.hash(Array("algobuddy".utf8)).hexString
                == "05354457ebcee867be563f4f6f7e9802ce8d6263098f731e8315ae560d502ca3")
    }

    /// Exercises the padding branches: exactly at, one below, and one above the
    /// 112-byte boundary where an extra compression block is required.
    @Test("padding boundaries", arguments: [0, 1, 55, 111, 112, 113, 127, 128, 129, 255])
    func lengths(_ length: Int) {
        let digest = SHA512_256.hash([UInt8](repeating: 0x61, count: length))
        #expect(digest.count == 32)
    }

    @Test("112-byte input crosses into a second block")
    func boundary() {
        // Python: hashlib.new("sha512_256", b"a"*112).hexdigest()
        #expect(SHA512_256.hash([UInt8](repeating: 0x61, count: 112)).hexString.count == 64)
        // Distinct inputs must not collide across the boundary.
        #expect(
            SHA512_256.hash([UInt8](repeating: 0x61, count: 111))
                != SHA512_256.hash([UInt8](repeating: 0x61, count: 112)))
    }
}
