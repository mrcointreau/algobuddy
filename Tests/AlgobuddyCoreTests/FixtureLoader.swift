import Foundation

/// Fixtures are real captured responses: mainnet block headers, a live account,
/// a ledger supply snapshot. Recording them means CI validates the parsers
/// against the wire format without needing network access or a node.
enum Fixture {
    enum FixtureError: Error { case missing(String) }

    static func data(_ name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
