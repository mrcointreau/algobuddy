import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Challenge")
struct ChallengeTests {
    static let address = try! AlgorandAddress(
        "3XBSYFKN4BT5HYBJ7V6VVJUYHYUVD5P7CAR77ZMCJSCK4LHLZLHDLYN2WQ")

    // MARK: - bitsMatch

    @Test("compares only the leading n bits")
    func leadingBits() {
        #expect(Challenge.bitsMatch([0xFF], [0xF8], 5))  // top 5 bits both 11111
        #expect(!Challenge.bitsMatch([0xFF], [0xF0], 5))  // differ in bit 4
        #expect(Challenge.bitsMatch([0x00], [0x07], 5))  // low 3 bits ignored
        #expect(Challenge.bitsMatch([0xAB, 0xCD], [0xAB, 0xFF], 8))
        #expect(!Challenge.bitsMatch([0xAB, 0xCD], [0xAC, 0xCD], 8))
    }

    @Test("zero bits always match")
    func zeroBits() {
        #expect(Challenge.bitsMatch([0x00], [0xFF], 0))
    }

    @Test("does not read past the end of either sequence")
    func bounds() {
        #expect(!Challenge.bitsMatch([], [0xFF], 5))
        #expect(!Challenge.bitsMatch([0xFF], [], 5))
        #expect(!Challenge.bitsMatch([0xAB], [0xAB], 16))
    }

    // MARK: - Challenge rounds

    @Test("challenge round is the last multiple of the interval")
    func rounds() {
        #expect(Challenge.challengeRound(for: 64_030_276, params: .v40) == 64_030_000)
        #expect(Challenge.challengeRound(for: 1_000, params: .v40) == 1_000)
        #expect(Challenge.challengeRound(for: 1_999, params: .v40) == 1_000)
        // Before the first interval there is no challenge to answer.
        #expect(Challenge.challengeRound(for: 999, params: .v40) == nil)
    }

    // MARK: - Evaluation

    /// A seed sharing its leading byte with the address is guaranteed to match
    /// on any `challengeBits <= 8`.
    static func matchingSeed() -> Data {
        Data([address.publicKey[0]] + [UInt8](repeating: 0, count: 31))
    }

    static func nonMatchingSeed() -> Data {
        Data([address.publicKey[0] ^ 0x80] + [UInt8](repeating: 0, count: 31))
    }

    @Test("challenged and silent is a failing state")
    func failing() throws {
        let state = try #require(
            Challenge.evaluate(
                address: Self.address,
                seed: Self.matchingSeed(),
                challengeRound: 64_030_000,
                currentRound: 64_030_100,
                lastSeen: 64_029_500,  // before the challenge
                params: .v40))

        #expect(state.isChallenged)
        #expect(!state.hasAnswered)
        #expect(state.isFailing)
        #expect(state.phase == .grace)
        #expect(state.roundsUntilDeadline == 100)

        // Half the grace period is already spent, leaving under five minutes at
        // nominal round time.
        let minutes = state.timeUntilDeadline(roundTime: 2.8) / 60
        #expect(minutes > 4 && minutes < 5)
    }

    @Test("activity at or after the challenge round counts as answered")
    func answered() throws {
        let state = try #require(
            Challenge.evaluate(
                address: Self.address, seed: Self.matchingSeed(),
                challengeRound: 64_030_000, currentRound: 64_030_100,
                lastSeen: 64_030_000, params: .v40))
        #expect(state.hasAnswered)
        #expect(!state.isFailing)
    }

    @Test("an unmatched address is never failing, however stale")
    func notChallenged() throws {
        let state = try #require(
            Challenge.evaluate(
                address: Self.address, seed: Self.nonMatchingSeed(),
                challengeRound: 64_030_000, currentRound: 64_030_100,
                lastSeen: 1, params: .v40))
        #expect(!state.isChallenged)
        #expect(!state.isFailing)
    }

    @Test("past the grace period the account is suspendable")
    func enforcing() throws {
        let state = try #require(
            Challenge.evaluate(
                address: Self.address, seed: Self.matchingSeed(),
                challengeRound: 64_030_000, currentRound: 64_030_300,
                lastSeen: 64_029_000, params: .v40))
        #expect(state.phase == .enforcing)
        #expect(state.isFailing)
        #expect(state.roundsUntilDeadline < 0)
    }

    /// go-algorand only enforces a failed challenge while
    /// `currentRound <= challengeRound + 2 x grace`; past that no proposer can
    /// suspend for it, so the app must stop claiming it could.
    @Test("a challenge past its enforcement window evaluates to nothing")
    func enforcementWindowCloses() {
        let state = Challenge.evaluate(
            address: Self.address, seed: Self.matchingSeed(),
            challengeRound: 64_030_000, currentRound: 64_030_401,
            lastSeen: 64_029_000, params: .v40)
        #expect(state == nil)
    }
}

@Suite("Key expiry")
struct KeyExpiryTests {
    @Test("counts down to vote-last-valid")
    func countdown() {
        let participation = AccountState.Participation(
            voteFirstValid: 63_308_451, voteLastValid: 66_085_593, voteKeyDilution: 1_667)
        let expiry = KeyExpiry(participation: participation, currentRound: 64_030_276)

        #expect(expiry.roundsRemaining == 2_055_317)
        #expect(!expiry.hasExpired)

        let days = expiry.timeRemaining(roundTime: 2.8) / 86_400
        #expect(days > 66 && days < 67)
    }

    @Test("detects an expired window")
    func expired() {
        let participation = AccountState.Participation(
            voteFirstValid: 1, voteLastValid: 100, voteKeyDilution: 10)
        let expiry = KeyExpiry(participation: participation, currentRound: 101)
        #expect(expiry.hasExpired)
        #expect(expiry.roundsRemaining == -1)
    }

    /// Rounds come from a user-configured endpoint and are not trusted to be
    /// sane: an inverted validity window or an absurd round count must degrade
    /// the numbers, never trap.
    @Test("malformed validity windows clamp instead of trapping")
    func malformedValidityClamps() {
        let inverted = KeyExpiry(
            participation: AccountState.Participation(
                voteFirstValid: 100, voteLastValid: 50, voteKeyDilution: 1),
            currentRound: UInt64.max)
        #expect(inverted.totalRounds == 0)
        #expect(inverted.roundsRemaining < 0)
        #expect(inverted.hasExpired)
    }
}
