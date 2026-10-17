import Foundation

@testable import AlgobuddyCore

/// A clock the tests drive by hand, so nothing has to sleep.
final class TestClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_786_000_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

extension ChainPoller.Update {
    /// The entry of a poller configured with a single address. Spelling out
    /// `entries.first` at every assertion would bury what is being checked.
    var only: AccountUpdate? { entries.first }

    /// The entry for one of several watched addresses.
    func entry(for address: AlgorandAddress) -> AccountUpdate? {
        entries.first { $0.address == address }
    }
}

/// Routes requests by URL substring and records what was asked for, so tests
/// can assert on request *counts*: the difference between "fetches the
/// challenge seed once per window" and "fetches it every poll" is invisible
/// otherwise.
final class StubFetcher: HTTPFetching, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var routes: [(match: String, stub: Stub)] = []
    private var recorded: [String] = []
    private var failing = false

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requestCount(containing fragment: String) -> Int {
        requests.filter { $0.contains(fragment) }.count
    }

    func route(_ match: String, status: Int = 200, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll { $0.match == match }
        routes.append((match, Stub(status: status, body: body)))
    }

    func route(_ match: String, status: Int = 200, json: String) {
        route(match, status: status, body: Data(json.utf8))
    }

    func setFailing(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failing = value
    }

    struct Offline: Error {}

    func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int) {
        let key = url.absoluteString
        // `NSLock.lock()` is unavailable from async contexts under Swift 6.
        let (isFailing, match) = lock.withLock { () -> (Bool, Stub?) in
            recorded.append(key)
            return (failing, routes.first { key.contains($0.match) }?.stub)
        }

        if isFailing { throw Offline() }
        guard let match else { return (Data(), 404) }
        return (match.body, match.status)
    }
}

/// Holds the first request whose URL contains a fragment until released and
/// lets every later one through, so a test can act while that request is
/// suspended mid-flight. Letting later requests through is what turns a second,
/// concurrent one into a countable request rather than a deadlock.
final class FirstRequestGate: HTTPFetching, @unchecked Sendable {
    private let inner: StubFetcher
    private let fragment: String
    private let lock = NSLock()
    private var matchingRequests = 0
    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?
    private var cancelledWhileHeld = false

    /// Yields once the first matching request is being held, and finishes when
    /// the gate opens.
    let firstHeld: AsyncStream<Void>
    private let firstHeldContinuation: AsyncStream<Void>.Continuation

    init(_ inner: StubFetcher, holding fragment: String = "/v2/accounts/") {
        self.inner = inner
        self.fragment = fragment
        (firstHeld, firstHeldContinuation) = AsyncStream.makeStream()
    }

    /// The matching requests made so far, the held one included.
    var matchingRequestCount: Int { lock.withLock { matchingRequests } }

    /// Whether the held request's task was cancelled by the time the gate let
    /// it through. The request still goes on to the stub, which ignores
    /// cancellation.
    var heldRequestWasCancelled: Bool { lock.withLock { cancelledWhileHeld } }

    func open() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            let waiting = held
            held = nil
            return waiting
        }
        waiting?.resume()
        // Nothing is held from here on, so a test still waiting for a hold
        // goes on instead of hanging.
        firstHeldContinuation.finish()
    }

    func get(
        _ url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> (Data, Int) {
        let isFirstMatchingRequest = lock.withLock { () -> Bool in
            guard url.absoluteString.contains(fragment) else { return false }
            matchingRequests += 1
            return matchingRequests == 1
        }
        if isFirstMatchingRequest {
            await withCheckedContinuation { continuation in
                let proceed = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    held = continuation
                    return false
                }
                if proceed {
                    continuation.resume()
                } else {
                    firstHeldContinuation.yield()
                }
            }
            let cancelled = Task.isCancelled
            lock.withLock { cancelledWhileHeld = cancelled }
        }
        return try await inner.get(url, headers: headers, timeout: timeout)
    }
}

/// Runs `rescue` unless cancelled within `seconds`, so a regression that would
/// leave a test waiting forever on a held request fails that test instead of
/// hanging the suite. A time limit cannot do this: cancelling the test does not
/// end a wait on another task's result.
func watchdog(
    after seconds: Double = 10, _ rescue: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
    Task {
        try? await Task.sleep(for: .seconds(seconds))
        if !Task.isCancelled { await rescue() }
    }
}

enum JSONBuilder {
    static func account(
        address: String = "ADDR",
        round: UInt64,
        amount: UInt64 = 149_734_756_595,
        status: String = "Online",
        incentiveEligible: Bool = true,
        lastProposed: UInt64? = nil,
        lastHeartbeat: UInt64? = nil,
        voteFirstValid: UInt64? = nil,
        voteLastValid: UInt64? = nil
    ) -> String {
        var fields = [
            "\"address\":\"\(address)\"",
            "\"round\":\(round)",
            "\"amount\":\(amount)",
            "\"status\":\"\(status)\"",
        ]
        // algod serialises this with `omitempty`, so a non-eligible account has
        // no field at all. The stub mirrors the wire: false means absent.
        if incentiveEligible { fields.append("\"incentive-eligible\":true") }
        if let lastProposed { fields.append("\"last-proposed\":\(lastProposed)") }
        if let lastHeartbeat { fields.append("\"last-heartbeat\":\(lastHeartbeat)") }
        if let voteLastValid {
            fields.append(
                """
                "participation":{"vote-first-valid":\(voteFirstValid ?? 0),\
                "vote-last-valid":\(voteLastValid),"vote-key-dilution":1667}
                """)
        }
        return "{\(fields.joined(separator: ","))}"
    }

    static func supply(round: UInt64, onlineStake: UInt64 = 1_886_826_685_238_820) -> String {
        """
        {"current_round":\(round),"online-money":\(onlineStake),\
        "online-stake":\(onlineStake),"total-money":9759959021027149}
        """
    }

    static func blockHeader(
        round: UInt64?, seed: Data?, timestamp: Int64 = 1_786_565_360
    ) -> String {
        var fields = [String]()
        if let round { fields.append("\"rnd\":\(round)") }
        fields.append("\"ts\":\(timestamp)")
        if let seed { fields.append("\"seed\":\"\(seed.base64EncodedString())\"") }
        return "{\"block\":{\(fields.joined(separator: ","))}}"
    }

    static func blockHeaders(
        _ entries: [(round: UInt64, timestamp: Int64, payout: UInt64?)], proposer: String
    ) -> String {
        let blocks = entries.map { entry -> String in
            var fields = [
                "\"round\":\(entry.round)",
                "\"timestamp\":\(entry.timestamp)",
                "\"proposer\":\"\(proposer)\"",
            ]
            if let payout = entry.payout { fields.append("\"proposer-payout\":\(payout)") }
            return "{\(fields.joined(separator: ","))}"
        }
        return "{\"blocks\":[\(blocks.joined(separator: ","))]}"
    }
}
