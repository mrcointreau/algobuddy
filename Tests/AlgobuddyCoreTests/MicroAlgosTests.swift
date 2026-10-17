import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("MicroAlgos")
struct MicroAlgosTests {
    /// The balance alert names the payout bounds through this text.
    @Test("a whole amount reads without a fraction")
    func wholeAmount() {
        #expect(MicroAlgos.zero.description == "0 ALGO")
        #expect(MicroAlgos(30_000_000_000).description == "30000 ALGO")
    }

    @Test("a fraction keeps its significant digits only")
    func fraction() {
        #expect(MicroAlgos(1_500_000).description == "1.5 ALGO")
        #expect(MicroAlgos(1_234_567).description == "1.234567 ALGO")
        #expect(MicroAlgos(1).description == "0.000001 ALGO")
    }

    @Test("algos divides by a million")
    func algos() {
        #expect(MicroAlgos(2_500_000).algos == 2.5)
    }
}
