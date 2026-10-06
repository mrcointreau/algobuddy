import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Watch list")
struct WatchListTests {
    /// A real mainnet proposer, so the checksum is known-good.
    static let first = "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ"
    /// A second account, built from its own key so that it carries a genuine
    /// checksum: 58 invented characters would be rejected before any rule here
    /// was reached.
    static let second: String = {
        let key = [UInt8](repeating: 7, count: AlgorandAddress.publicKeyLength)
        return Base32.encode(key + SHA512_256.hash(key).suffix(AlgorandAddress.checksumLength))
    }()

    // MARK: - Reading a stored list

    /// The watch a user already has must survive an update to a version that
    /// keeps a list, with nothing lost and nothing asked of them.
    @Test("a lone stored address reads back as a one-element list")
    func singleBecomesList() {
        #expect(WatchList.restore(list: nil, single: Self.first) == [Self.first])
    }

    @Test("the stored list is read in order")
    func listInOrder() {
        let stored = [Self.second, Self.first]
        #expect(WatchList.restore(list: stored, single: nil) == stored)
    }

    @Test("the list wins over a lone address")
    func listWins() {
        #expect(WatchList.restore(list: [Self.second], single: Self.first) == [Self.second])
    }

    /// A list emptied on purpose stays empty. Falling back to the lone value
    /// here would resurrect a watch the user removed.
    @Test("an emptied list is not answered with the lone address")
    func emptiedListStands() {
        #expect(WatchList.restore(list: [], single: Self.first).isEmpty)
    }

    @Test("nothing stored is an empty list")
    func nothingStored() {
        #expect(WatchList.restore(list: nil, single: nil).isEmpty)
        #expect(WatchList.restore(list: nil, single: "").isEmpty)
        #expect(WatchList.restore(list: ["  "], single: nil).isEmpty)
    }

    // MARK: - Resolving edited rows

    @Test("rows resolve in the order they are listed")
    func resolvesInOrder() throws {
        let resolved = try WatchList.resolve([Self.second, Self.first])
        #expect(resolved.map(\.stringValue) == [Self.second, Self.first])
    }

    /// A row added and not yet typed into must not stop the completed rows from
    /// being watched.
    @Test("a blank row is skipped, not refused")
    func skipsBlankRow() throws {
        let resolved = try WatchList.resolve([Self.first, "   ", ""])
        #expect(resolved.map(\.stringValue) == [Self.first])
    }

    /// Compared as addresses rather than as text, so a repeat pasted in another
    /// case is still one account.
    @Test("a repeated address is kept once, at its first position")
    func dropsRepeats() throws {
        let resolved = try WatchList.resolve([
            Self.first, Self.second, " " + Self.first.lowercased(),
        ])
        #expect(resolved.map(\.stringValue) == [Self.first, Self.second])
    }

    /// What lets an edit in progress leave a running watch alone: the caller
    /// gets an error rather than a shorter list that silently drops a row.
    @Test("an unparseable row throws rather than being dropped")
    func throwsOnBadRow() {
        var typo = Array(Self.first)
        typo[3] = typo[3] == "S" ? "T" : "S"
        #expect(throws: AlgorandAddress.AddressError.checksumMismatch) {
            try WatchList.resolve([Self.second, String(typo)])
        }
    }

    @Test("no rows is an empty list")
    func noRows() throws {
        #expect(try WatchList.resolve([]).isEmpty)
        #expect(try WatchList.resolve([""]).isEmpty)
    }
}
