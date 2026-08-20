import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Absenteeism")
struct AbsenceTests {
    // Live mainnet values captured at round 64,030,276.
    static let accountStake = MicroAlgos(149_734_756_595)  // ≈ 149,734.76 ALGO
    static let totalOnlineStake = MicroAlgos(1_886_826_685_238_820)  // ≈ 1.887B ALGO
    static let lastSeen: UInt64 = 64_030_256
    static let currentRound: UInt64 = 64_030_276

    @Test("matches hand-computed values for a live account")
    func realAccount() throws {
        let assessment = try #require(
            Absence.assess(
                accountStake: Self.accountStake,
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: Self.lastSeen,
                currentRound: Self.currentRound,
                params: .v40))

        // 20 × 1,886,826,685,238,820 / 149,734,756,595 = 252,022
        #expect(assessment.allowableLag == 252_022)
        #expect(assessment.roundsSinceLastSeen == 20)
        #expect(assessment.headroomRounds == 252_002)
        #expect(!assessment.isAbsent)
        #expect(assessment.ratio < 0.001)

        // ≈ 8.2 days at nominal round time.
        let days = assessment.headroom(roundTime: 2.8) / 86_400
        #expect(days > 8.0 && days < 8.4)
    }

    /// The counterintuitive shape worth surfacing in the UI: tolerance is
    /// inversely proportional to stake, so a bigger staker is suspended sooner.
    @Test("larger stake means less tolerance")
    func stakeShortensTolerance() throws {
        let small = try #require(
            Absence.assess(
                accountStake: MicroAlgos(30_000_000_000),
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1_000, currentRound: 1_001, params: .v40))
        let large = try #require(
            Absence.assess(
                accountStake: MicroAlgos(3_000_000_000_000),
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1_000, currentRound: 1_001, params: .v40))

        #expect(large.allowableLag < small.allowableLag)
    }

    @Test("flags an account past the limit")
    func absent() throws {
        let assessment = try #require(
            Absence.assess(
                accountStake: Self.accountStake,
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1_000,
                currentRound: 1_000 + 252_023,
                params: .v40))
        #expect(assessment.isAbsent)
        #expect(assessment.headroomRounds < 0)
        #expect(assessment.ratio > 1.0)
    }

    @Test("exactly at the boundary is not yet absent")
    func boundary() throws {
        let assessment = try #require(
            Absence.assess(
                accountStake: Self.accountStake,
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1_000,
                currentRound: 1_000 + 252_022,
                params: .v40))
        // Source condition is `lastSeen + allowableLag < current`, so equality passes.
        #expect(!assessment.isAbsent)
    }

    /// go-algorand explicitly treats a never-seen account as not absent, rather
    /// than as maximally overdue. Getting this backwards would fire a critical
    /// alert at every freshly registered account.
    @Test(
        "never-seen and zero-stake accounts are exempt",
        arguments: [
            (UInt64(0), UInt64(149_734_756_595)),
            (UInt64(64_030_256), UInt64(0)),
        ])
    func exemptions(lastSeen: UInt64, stake: UInt64) {
        #expect(
            Absence.assess(
                accountStake: MicroAlgos(stake),
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: lastSeen,
                currentRound: Self.currentRound,
                params: .v40) == nil)
    }

    @Test("a dust-sized stake overflows the lag bound and is skipped")
    func hugeLag() {
        // allowableLag would exceed UInt32.max, which source treats as not absent.
        #expect(
            Absence.assess(
                accountStake: MicroAlgos(1),
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1,
                currentRound: Self.currentRound,
                params: .v40) == nil)
    }

    /// Rounds come from a user-configured endpoint: a garbage current round
    /// near UInt64.max must degrade the numbers, never trap.
    @Test("absurd rounds clamp instead of trapping")
    func absurdRoundsClamp() throws {
        let assessment = try #require(
            Absence.assess(
                accountStake: Self.accountStake,
                totalOnlineStake: Self.totalOnlineStake,
                lastSeen: 1,
                currentRound: UInt64.max,
                params: .v40))
        #expect(assessment.isAbsent)
        #expect(assessment.headroomRounds < 0)
    }

    @Test("muldiv keeps full width and reports overflow instead of trapping")
    func muldiv() {
        #expect(Absence.muldiv(20, 1_886_826_685_238_820, 149_734_756_595) == 252_022)
        #expect(Absence.muldiv(10, 100, 5) == 200)
        #expect(Absence.muldiv(1, 1, 0) == nil)
        // Product exceeds 64 bits but the quotient still fits.
        #expect(Absence.muldiv(UInt64.max, 4, 8) == UInt64.max / 2)
        // Quotient cannot fit.
        #expect(Absence.muldiv(UInt64.max, UInt64.max, 1) == nil)
    }
}
