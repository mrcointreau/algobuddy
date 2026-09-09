import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Portfolio summary")
struct PortfolioSummaryTests {
    /// 3 s exactly, so a headroom in rounds reads as a round number of seconds.
    let roundTime: TimeInterval = 3

    func address(_ byte: UInt8) -> AlgorandAddress {
        let key = [UInt8](repeating: byte, count: AlgorandAddress.publicKeyLength)
        return try! AlgorandAddress(
            Base32.encode(key + SHA512_256.hash(key).suffix(AlgorandAddress.checksumLength)))
    }

    func account(
        _ address: AlgorandAddress, status: AccountState.Status = .online, amount: UInt64
    ) -> AccountState {
        AccountState(
            address: address.stringValue,
            status: status,
            amount: MicroAlgos(amount),
            round: 64_030_100,
            incentiveEligible: true,
            lastProposed: 64_030_050,
            lastHeartbeat: nil,
            participation: nil)
    }

    func absence(headroomRounds: Int64) -> AbsenceAssessment {
        AbsenceAssessment(
            allowableLag: 100_000,
            roundsSinceLastSeen: 0,
            headroomRounds: headroomRounds,
            ratio: 0.5,
            isAbsent: headroomRounds < 0)
    }

    func keyExpiry(roundsRemaining: UInt64) -> KeyExpiry {
        KeyExpiry(
            participation: AccountState.Participation(
                voteFirstValid: 0, voteLastValid: 64_030_100 + roundsRemaining,
                voteKeyDilution: 1_667),
            currentRound: 64_030_100)
    }

    func rewards(
        proposals24h: Int = 0, proposals7d: Int = 0, earned24h: UInt64 = 0, earned7d: UInt64 = 0,
        isTruncated: Bool = false
    ) -> RewardsSummary {
        var summary = RewardsSummary()
        summary.proposals24h = proposals24h
        summary.proposals7d = proposals7d
        summary.earned24h = MicroAlgos(earned24h)
        summary.earned7d = MicroAlgos(earned7d)
        summary.isTruncated = isTruncated
        return summary
    }

    @Test("an empty portfolio counts nothing and promises nothing")
    func empty() {
        let summary = PortfolioSummary(entries: [], roundTime: roundTime)
        #expect(summary.accountCount == 0)
        #expect(summary.onlineAccounts == 0)
        #expect(summary.totalStake == .zero)
        // Nil rather than zero: zero would read as a deadline that has arrived.
        #expect(summary.closestAbsenceHeadroom == nil)
        #expect(summary.closestKeyExpiry == nil)
    }

    /// A portfolio is as healthy as its worst account, so the countdown worth
    /// showing is the one that runs out first, not an average or a sum.
    @Test("the countdowns take the closest deadline")
    func closestDeadlines() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(
                    address: address(1), account: account(address(1), amount: 1),
                    absence: absence(headroomRounds: 10_000),
                    keyExpiry: keyExpiry(roundsRemaining: 500)),
                AccountUpdate(
                    address: address(2), account: account(address(2), amount: 1),
                    absence: absence(headroomRounds: 200),
                    keyExpiry: keyExpiry(roundsRemaining: 900_000)),
            ],
            roundTime: roundTime)

        #expect(summary.closestAbsenceHeadroom == 600)  // 200 rounds at 3 s
        #expect(summary.closestKeyExpiry == 1_500)  // 500 rounds at 3 s
    }

    /// An account already past its limit is the one thing the portfolio most
    /// needs to say, so a negative headroom must win rather than be discarded
    /// for being smaller than nothing.
    @Test("a headroom already past zero still wins")
    func negativeHeadroomWins() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(address: address(1), absence: absence(headroomRounds: 10_000)),
                AccountUpdate(address: address(2), absence: absence(headroomRounds: -50)),
            ],
            roundTime: roundTime)

        #expect(summary.closestAbsenceHeadroom == -150)
    }

    @Test("stake and proposals are summed across accounts")
    func sums() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(
                    address: address(1), account: account(address(1), amount: 30_000_000),
                    rewards: rewards(
                        proposals24h: 2, proposals7d: 9, earned24h: 8_000_000,
                        earned7d: 31_000_000)),
                AccountUpdate(
                    address: address(2), account: account(address(2), amount: 12_000_000),
                    rewards: rewards(
                        proposals24h: 1, proposals7d: 4, earned24h: 4_000_000,
                        earned7d: 17_000_000)),
            ],
            roundTime: roundTime)

        #expect(summary.totalStake == MicroAlgos(42_000_000))
        #expect(summary.proposals24h == 3)
        #expect(summary.proposals7d == 13)
        #expect(summary.earned24h == MicroAlgos(12_000_000))
        #expect(summary.earned7d == MicroAlgos(48_000_000))
    }

    @Test("only Online accounts are counted as online")
    func onlineCount() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(address: address(1), account: account(address(1), amount: 1)),
                AccountUpdate(
                    address: address(2),
                    account: account(address(2), status: .offline, amount: 2)),
                AccountUpdate(
                    address: address(3),
                    account: account(address(3), status: .notParticipating, amount: 4)),
            ],
            roundTime: roundTime)

        #expect(summary.accountCount == 3)
        #expect(summary.onlineAccounts == 1)
        #expect(summary.totalStake == MicroAlgos(7))
    }

    /// An account whose fetch failed says nothing about itself this cycle, so
    /// counting it would report a portfolio smaller and quieter than it is.
    @Test("an account with no data contributes nothing")
    func failedAccountIsNotCounted() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(address: address(1), account: account(address(1), amount: 5)),
                AccountUpdate(
                    address: address(2),
                    failure: PollFailure(stage: .account, message: "unreachable")),
            ],
            roundTime: roundTime)

        #expect(summary.accountCount == 1)
        #expect(summary.totalStake == MicroAlgos(5))
    }

    /// A floor presented as a total under-reports the portfolio, so the caveat
    /// has to travel with the summed figures.
    @Test("one truncated history makes the totals a floor")
    func truncationSpreads() {
        let summary = PortfolioSummary(
            entries: [
                AccountUpdate(address: address(1), rewards: rewards(proposals7d: 3)),
                AccountUpdate(
                    address: address(2), rewards: rewards(proposals7d: 1, isTruncated: true)),
            ],
            roundTime: roundTime)

        #expect(summary.isTruncated)
        #expect(summary.proposals7d == 4)
    }
}
