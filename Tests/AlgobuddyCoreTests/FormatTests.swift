import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Format")
struct FormatTests {
    @Test("a count agrees with its unit in number")
    func countAgrees() {
        #expect(Format.countLabel(1, "block", hidden: false) == "1 block")
        #expect(Format.countLabel(3, "block", hidden: false) == "3 blocks")
        #expect(Format.countLabel(0, "proposal", hidden: false) == "0 proposals")
    }

    /// The unit stays, so the row still says what it counts. The plural, so a
    /// mask over one block reads the same as a mask over many.
    @Test("a hidden count keeps its unit, in the plural")
    func hiddenCount() {
        #expect(Format.countLabel(1, "block", hidden: true) == "•••••• blocks")
        #expect(Format.countLabel(12, "proposal", hidden: true) == "•••••• proposals")
    }
}
