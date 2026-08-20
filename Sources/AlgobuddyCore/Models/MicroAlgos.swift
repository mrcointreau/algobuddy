import Foundation

/// A quantity of microAlgos. Algorand amounts are always integral µALGO on the
/// wire; keeping them as `UInt64` avoids the rounding that creeps in when
/// balances are stored as `Double`.
public struct MicroAlgos: Hashable, Sendable, Codable, Comparable {
    public let raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    public static let zero = MicroAlgos(0)
    public static let perAlgo: UInt64 = 1_000_000

    /// Lossy, for display only. Never round-trip a balance through this.
    public var algos: Double { Double(raw) / Double(Self.perAlgo) }

    public static func < (lhs: MicroAlgos, rhs: MicroAlgos) -> Bool { lhs.raw < rhs.raw }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension MicroAlgos: CustomStringConvertible {
    public var description: String {
        let whole = raw / Self.perAlgo
        let fraction = raw % Self.perAlgo
        guard fraction > 0 else { return "\(whole) ALGO" }

        var digits = String(format: "%06u", fraction)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits) ALGO"
    }
}
