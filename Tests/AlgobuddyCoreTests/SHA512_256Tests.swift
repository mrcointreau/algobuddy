import Foundation
import Testing

@testable import AlgobuddyCore

/// Vectors generated with OpenSSL (`openssl dgst -sha512-256`). The `abc`
/// digest is also the published FIPS 180-4 example.
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
    /// 112-byte boundary where an extra compression block is required, and
    /// around the 128-byte block itself. The input is that many "a" bytes.
    @Test(
        "padding boundaries",
        arguments: [
            (0, "c672b8d1ef56ed28ab87c3622c5114069bdd3ad7b8f9737498d0c01ecef0967a"),
            (1, "455e518824bc0601f9fb858ff5c37d417d67c2f8e0df2babe4808858aea830f8"),
            (55, "f6513468f05e7cec7d52fc337ef79dfa7c82520268d3aeba4002ead9a5642916"),
            (111, "0239e429f98d0ed61ee8e2a7c30afe98c1c3a80ce5dff62a107e9c538f7632ce"),
            (112, "9216b5303edb66504570bee90e48ea5beaa5e9fe9f760bbd3e0460559fc005f6"),
            (113, "d0ac79bea5bc97ac80c77c7cbbe92811ba9997eb0ce3c9888f9cef8362d187cd"),
            (127, "2fe3b2a6ee7e12f6fe4ba82166541ad9b4ed882c493581cbe300d68f3757b778"),
            (128, "b88f97e274f9c1d49f181c8cbd01a9c74930ad055a46ac4499a1d601f1c80bf2"),
            (129, "fb9035c9009ed4a60e37510339ebdb1c771339f30aa581d5dea3690a524c23f1"),
            (255, "3c07343720a65d00043af3a6514586dde8602a68b7cebde6bd8ffa48ba37afef"),
        ])
    func lengths(length: Int, digest: String) {
        #expect(SHA512_256.hash([UInt8](repeating: 0x61, count: length)).hexString == digest)
    }
}
