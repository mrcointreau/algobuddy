import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Account names")
struct AccountNamesTests {
    static let first = try! AlgorandAddress(
        "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ")
    /// Built from its own key, so the checksum holds.
    static let second: AlgorandAddress = {
        let key = [UInt8](repeating: 7, count: AlgorandAddress.publicKeyLength)
        return try! AlgorandAddress(
            Base32.encode(key + SHA512_256.hash(key).suffix(AlgorandAddress.checksumLength)))
    }()

    @Test("a name is trimmed, and an empty one means no name")
    func trimsAndTreatsEmptyAsNone() {
        #expect(AccountNames.name(from: "  Home node \n") == "Home node")
        #expect(AccountNames.name(from: "") == nil)
        #expect(AccountNames.name(from: " \t ") == nil)
    }

    /// Counted in characters, so a name of emoji is cut where it reads as cut,
    /// and a cut that lands after a space leaves no trailing space behind.
    @Test("a name is cut to 32 characters")
    func limitsLength() {
        let exact = String(repeating: "b", count: 32)
        #expect(AccountNames.name(from: exact) == exact)
        // Trimmed before the cut, so surrounding spaces take none of the 32.
        #expect(AccountNames.name(from: "   " + exact + "  ") == exact)
        #expect(AccountNames.name(from: String(repeating: "a", count: 40))?.count == 32)
        // A flag is two Unicode scalars, so a cut by scalars would keep 16.
        #expect(AccountNames.name(from: String(repeating: "🇮🇹", count: 40))?.count == 32)
        let spaced = String(repeating: "c", count: 31) + " d"
        #expect(AccountNames.name(from: spaced) == String(repeating: "c", count: 31))
    }

    @Test("an account goes by its name, or by the fallback without one")
    func labelFallsBack() {
        let names = AccountNames([(account: Self.first, name: "Home")])
        #expect(names.label(for: Self.first, otherwise: "3XBS…N2WQ") == "Home")
        #expect(names.label(for: Self.second, otherwise: "short address") == "short address")
    }

    @Test("names are keyed by address, so reordering the list moves none")
    func keyedByAddress() {
        let forward = AccountNames([
            (account: Self.first, name: "Home"), (account: Self.second, name: "Office"),
        ])
        let reversed = AccountNames([
            (account: Self.second, name: "Office"), (account: Self.first, name: "Home"),
        ])
        #expect(forward == reversed)
        #expect(
            forward.stored == [Self.first.stringValue: "Home", Self.second.stringValue: "Office"])
    }

    @Test("a name leaves the list with its address")
    func prunedWithTheList() {
        let both = AccountNames([
            (account: Self.first, name: "Home"), (account: Self.second, name: "Office"),
        ])
        let afterRemoval = AccountNames([(account: Self.second, name: "Office")])
        #expect(both.name(for: Self.first) == "Home")
        #expect(afterRemoval.name(for: Self.first) == nil)
        #expect(afterRemoval.stored == [Self.second.stringValue: "Office"])
    }

    /// The first row of a repeated address is the one the list watches, so its
    /// name is the one that stands, even when it is empty.
    @Test("a row without an account names nothing, and the first of a repeat stands")
    func rowsWithoutAccountsAndRepeats() {
        let names = AccountNames([
            (account: nil, name: "Orphan"),
            (account: Self.first, name: "  "),
            (account: Self.first, name: "Later"),
            (account: Self.second, name: "Office"),
            (account: Self.second, name: "Repeat"),
        ])
        #expect(names.stored == [Self.second.stringValue: "Office"])
    }

    @Test("stored names read back, without the entries no list could have written")
    func readsBackStorage() {
        let names = AccountNames(stored: [
            Self.first.stringValue: " Home ",
            Self.second.stringValue: "",
            Self.first.stringValue.lowercased(): "Not canonical",
            "not an address": "Nope",
        ])
        #expect(names.stored == [Self.first.stringValue: "Home"])
        #expect(AccountNames(stored: names.stored) == names)
    }
}
