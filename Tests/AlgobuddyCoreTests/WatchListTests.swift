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
    /// The first address with one character changed, so its checksum fails.
    static let typo: String = {
        var characters = Array(Self.first)
        characters[3] = characters[3] == "S" ? "T" : "S"
        return String(characters)
    }()

    // MARK: - Reading a stored list

    /// A lone stored address names exactly one watched account, so it reads
    /// back as that account alone, with nothing lost and nothing asked.
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

    /// Rows as typed, holding no account yet.
    func rows(_ texts: [String]) -> [WatchList.Row] {
        texts.map { WatchList.Row(text: $0) }
    }

    @Test("rows resolve in the order they are listed")
    func resolvesInOrder() {
        let resolved = WatchList.resolve(rows([Self.second, Self.first]))
        #expect(resolved.map(\.stringValue) == [Self.second, Self.first])
    }

    /// A row added and not yet typed into must not stop the completed rows from
    /// being watched.
    @Test("a blank row is skipped, not refused")
    func skipsBlankRow() {
        let resolved = WatchList.resolve(rows([Self.first, "   ", ""]))
        #expect(resolved.map(\.stringValue) == [Self.first])
    }

    /// Compared as addresses rather than as text, so a repeat pasted in another
    /// case is still one account.
    @Test("a repeated address is kept once, at its first position")
    func dropsRepeats() {
        let resolved = WatchList.resolve(
            rows([Self.first, Self.second, " " + Self.first.lowercased()]))
        #expect(resolved.map(\.stringValue) == [Self.first, Self.second])
    }

    /// What lets an edit in progress leave a running watch alone: the row
    /// keeps the account it held, in its place, until its text names another.
    @Test("a half-typed row keeps the account it held")
    func halfTypedRowKeepsItsAccount() throws {
        let held = try AlgorandAddress(Self.first)
        let resolved = WatchList.resolve([
            WatchList.Row(text: Self.typo, held: held), WatchList.Row(text: Self.second),
        ])
        #expect(resolved.map(\.stringValue) == [Self.first, Self.second])
    }

    /// A row that never held an account stands for none until it is valid, and
    /// the rows beside it are watched regardless.
    @Test("a half-typed new row watches nothing and holds back no other row")
    func halfTypedNewRowHoldsBackNothing() {
        let resolved = WatchList.resolve(rows([Self.second, Self.typo]))
        #expect(resolved.map(\.stringValue) == [Self.second])
    }

    /// A finished edit replaces the account, and clearing a row removes it.
    @Test("a row's text wins over what it held, and a cleared row watches nothing")
    func textWinsAndClearingRemoves() throws {
        let held = try AlgorandAddress(Self.first)
        #expect(WatchList.Row(text: Self.second, held: held).watched?.stringValue == Self.second)
        #expect(WatchList.Row(text: "  ", held: held).watched == nil)
    }

    @Test("no rows is an empty list")
    func noRows() {
        #expect(WatchList.resolve([]).isEmpty)
        #expect(WatchList.resolve(rows([""])).isEmpty)
    }

    /// Settings marks the rows that resolving drops as repeats, so the two
    /// agree even when the first row names its account only by what it holds.
    @Test("the repeats are the rows that resolving drops")
    func repeatsAreTheDroppedRows() throws {
        let held = try AlgorandAddress(Self.first)
        let rows = [
            WatchList.Row(text: Self.typo, held: held),
            WatchList.Row(text: Self.second),
            WatchList.Row(text: " " + Self.first.lowercased()),
            WatchList.Row(text: Self.typo),
            WatchList.Row(text: Self.second),
        ]
        #expect(WatchList.repeats(rows) == [2, 4])
        #expect(WatchList.resolve(rows).map(\.stringValue) == [Self.first, Self.second])
    }
}
