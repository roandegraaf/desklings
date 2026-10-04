import Foundation
import SwiftUI
import Testing
@testable import Schermes

/// The poll scheduler, the reachability every guarded call reports into, the nap Retry now cuts
/// short, and the one agent-list fetch the whole app shares. Canned daemons only: no Keychain, no
/// defaults.

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private func reachable(_ daemon: Daemon, clock: Clock = Clock()) -> Session {
    let client = SchermesClient(baseURL: URL(string: "http://\(daemon.host)")!, urlSession: canned)
    return Session(credentials: Vault().credentials, dropAddress: {}, client: client, phase: .ready, now: { clock.now })
}

nonisolated private func offline(_ request: Recorded) -> Canned { Canned(failure: .cannotConnectToHost) }

// MARK: - Scheduler

@Test func eachPhaseHasItsOwnInterval() {
    #expect(PollSchedule.interval(base: .seconds(2), phase: .active) == .seconds(2))
    #expect(PollSchedule.interval(base: .seconds(2), phase: .inactive) == .seconds(10))
    #expect(PollSchedule.interval(base: .seconds(1), phase: .inactive) == .seconds(5))
}

@Test func theBackgroundPausesOnAPhoneAndSlowsOnAMac() {
    #expect(PollSchedule.interval(base: .seconds(2), phase: .background, pausesInBackground: true) == nil)
    #expect(PollSchedule.interval(base: .seconds(2), phase: .background, failures: 3, pausesInBackground: true) == nil)
    #expect(PollSchedule.interval(base: .seconds(2), phase: .background, pausesInBackground: false) == .seconds(10))
}

@Test func failuresDoubleTheWaitUpToAMinute() {
    let waits = (0...7).map { PollSchedule.interval(base: .seconds(2), phase: .active, failures: $0) }
    #expect(waits == [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    #expect(PollSchedule.interval(base: .seconds(2), phase: .inactive, failures: 1) == .seconds(20))
    #expect(PollSchedule.interval(base: .seconds(2), phase: .inactive, failures: 9) == .seconds(60))
    #expect(PollSchedule.interval(base: .seconds(2), phase: .active, failures: 1_000) == .seconds(60))
}

@Test func theCapNeverMakesASlowPollFaster() {
    #expect(PollSchedule.interval(base: .seconds(30), phase: .inactive, failures: 2) == .seconds(150))
}

@Test func theMacPhaseTakesTheAppInFrontAndTheWindowSeen() {
    #expect(PollPhase.of(scene: .active) == .active)
    #expect(PollPhase.of(scene: .active, frontmost: false) == .inactive)
    #expect(PollPhase.of(scene: .active, visible: false) == .inactive)
    #expect(PollPhase.of(scene: .inactive) == .inactive)
    #expect(PollPhase.of(scene: .background, frontmost: true, visible: true) == .background)
}

private final class Outcomes {
    var left: [Bool]
    var reported = 0
    init(_ left: [Bool]) { self.left = left }
}

@Test func aPollReportsFailuresButNotCancellations() async {
    let session = reachable(Daemon())
    let outcomes = Outcomes([false, false, true, false])
    let poll = Task {
        await session.poll(every: .milliseconds(1), .active, failed: { _ in outcomes.reported += 1 }) {
            guard !outcomes.left.isEmpty else { throw CancellationError() }
            if !outcomes.left.removeFirst() { throw URLError(.timedOut) }
        }
    }
    while !outcomes.left.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    try? await Task.sleep(for: .milliseconds(50))
    poll.cancel()
    await poll.value
    #expect(outcomes.reported == 3)
}

@Test func aPausedPollAsksNothingAtAll() async {
    let session = reachable(Daemon())
    var ticks = 0
    await session.poll(every: .seconds(2), .background, pausesInBackground: true) { ticks += 1 }
    #expect(ticks == 0)
}

@Test func theBannerShowsAFailedRefreshLast() {
    let session = reachable(Daemon())
    #expect(bannerHeight(session, stale: "the daemon answered 500") > 20)
}

// MARK: - Reachability

@Test func aNetworkFailureRaisesTheBannerAndASuccessClearsIt() async throws {
    let clock = Clock()
    let daemon = Daemon(offline)
    let session = reachable(daemon, clock: clock)
    #expect(session.reachability == .reachable)

    await #expect(throws: URLError.self) { try await session.run { try await $0.agents() } }
    guard case .unreachable(let since, let message) = session.reachability else {
        Issue.record("still reachable after \(URLError(.cannotConnectToHost))")
        return
    }
    #expect(since == clock.now)
    #expect(message == URLError(.cannotConnectToHost).localizedDescription)
    #expect(session.complaint(about: URLError(.cannotConnectToHost)) == nil)

    clock.now += 30
    await #expect(throws: URLError.self) { try await session.run { try await $0.needsYou() } }
    #expect(session.reachability == .unreachable(since: since, message: message))

    daemon.script { _ in Canned(json: "[]") }
    _ = try await session.run { try await $0.agents() }
    #expect(session.reachability == .reachable)
}

@Test func aDaemonsRefusalIsNotOffline() async {
    let daemon = Daemon { _ in Canned(status: 403, json: #"{"error":"not yours"}"#) }
    let session = reachable(daemon)
    await #expect(throws: SchermesError.self) { try await session.run { try await $0.agents() } }
    #expect(session.reachability == .reachable)
    #expect(session.complaint(about: SchermesError.daemon(status: 403, message: "not yours")) == "not yours")
}

@Test func aProxySayingTheDaemonIsDownIsOffline() async {
    let daemon = Daemon { _ in Canned(status: 502, json: "bad gateway") }
    let session = reachable(daemon)
    await #expect(throws: SchermesError.self) { try await session.run { try await $0.agents() } }
    #expect(session.reachability != .reachable)
}

@Test func aCancelledRequestChangesNothing() async {
    let daemon = Daemon { _ in Canned(failure: .cancelled) }
    let session = reachable(daemon)
    await #expect(throws: URLError.self) { try await session.run { try await $0.agents() } }
    #expect(session.reachability == .reachable)
    #expect(session.complaint(about: URLError(.cancelled)) == nil)
}

@Test func aFailureThatLandsAfterLogOutRaisesNothing() async throws {
    let gate = Turnstile2()
    let daemon = Daemon { _ in Canned(failure: .notConnectedToInternet) }
    let session = reachable(daemon)
    let call = Task {
        try await session.run { client in
            await gate.wait()
            return try await client.agents()
        }
    }
    await gate.arrived()
    session.logOut()
    await gate.open()
    await #expect(throws: (any Error).self) { try await call.value }
    #expect(session.reachability == .reachable)
}

@Test func theBannerDrawsOnlyWhileTheDaemonIsOutOfReach() async throws {
    let daemon = Daemon(offline)
    let session = reachable(daemon)
    #expect(bannerHeight(session) == 0)
    await #expect(throws: URLError.self) { try await session.run { try await $0.agents() } }
    #expect(bannerHeight(session) > 20)
    daemon.script { _ in Canned(json: "[]") }
    _ = try await session.run { try await $0.agents() }
    #expect(bannerHeight(session) == 0)
}

@Test func theBannerShowsAFailedActionUntilDismissed() {
    let session = reachable(Daemon())
    #expect(bannerHeight(session, failure: "the daemon refused it") > 20)
}

private func bannerHeight(_ session: Session, failure: String? = nil, stale: String? = nil) -> CGFloat {
    let renderer = ImageRenderer(
        content: TroubleBanner(session: session, failure: .constant(failure), stale: stale).frame(width: 400)
    )
    return renderer.cgImage.map { CGFloat($0.height) / renderer.scale } ?? 0
}

// MARK: - Nap

@Test func retryNowWakesAPollAsleepForAMinute() async {
    let session = reachable(Daemon())
    let started = ContinuousClock.now
    let napping = Task { await session.nap(for: .seconds(60)) }
    try? await Task.sleep(for: .milliseconds(50))
    session.retryNow()
    await napping.value
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test func cancellingEndsANap() async {
    let session = reachable(Daemon())
    let started = ContinuousClock.now
    let napping = Task { await session.nap(for: .seconds(60)) }
    try? await Task.sleep(for: .milliseconds(50))
    napping.cancel()
    await napping.value
    #expect(ContinuousClock.now - started < .seconds(5))

    let already = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await session.nap(for: .seconds(60))
    }
    await already.value
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test func theDaemonComingBackWakesEveryBackedOffPoll() async throws {
    let daemon = Daemon(offline)
    let session = reachable(daemon)
    await #expect(throws: URLError.self) { try await session.run { try await $0.agents() } }
    let started = ContinuousClock.now
    let napping = Task { await session.nap(for: .seconds(60)) }
    try? await Task.sleep(for: .milliseconds(50))
    daemon.script { _ in Canned(json: "[]") }
    _ = try await session.run { try await $0.agents() }
    await napping.value
    #expect(ContinuousClock.now - started < .seconds(5))
}

// MARK: - One agent list for the app

@Test func callersInTheSameMomentShareOneAgentListFetch() async throws {
    let daemon = Daemon { _ in Canned(json: "[]") }
    let feed = AgentFeed(session: reachable(daemon))
    async let first: Void = feed.refresh()
    async let second: Void = feed.refresh()
    async let third: Void = feed.refresh(ifOlderThan: .seconds(10))
    _ = try await (first, second, third)
    #expect(daemon.requests.filter { $0.path == "/api/agents" }.count == 1)
    #expect(daemon.requests.filter { $0.path == "/api/needs-you" }.count == 1)
    #expect(feed.loaded)
}

@Test func aPollSoonAfterAFetchIsAnsweredFromIt() async throws {
    let daemon = Daemon { _ in Canned(json: "[]") }
    let feed = AgentFeed(session: reachable(daemon))
    try await feed.refresh()
    try await feed.refresh(ifOlderThan: .seconds(10))
    #expect(daemon.requests.filter { $0.path == "/api/agents" }.count == 1)
    try await feed.refresh()
    #expect(daemon.requests.filter { $0.path == "/api/agents" }.count == 2)
}

@Test func theFeedSaysTheOwnerIsHereOnlyWhenTheConsoleSaysSo() async throws {
    let daemon = Daemon { _ in Canned(json: "[]") }
    let session = reachable(daemon)
    let feed = AgentFeed(session: session)
    try await feed.refresh()
    feed.attending = true
    try await feed.refresh()
    let lists = daemon.requests.filter { $0.path == "/api/agents" }
    #expect(lists.count == 2)
    #expect(lists.map { $0.headers["x-schermes-attending"] } == [nil, "1"])
}

@Test func aFeedThatCannotReachTheDaemonThrowsAndKeepsItsList() async throws {
    let daemon = Daemon { _ in Canned(json: "[]") }
    let feed = AgentFeed(session: reachable(daemon))
    try await feed.refresh()
    daemon.script(offline)
    await #expect(throws: URLError.self) { try await feed.refresh() }
    #expect(feed.loaded)
}

/// Holds a call until the test lets it go.
private actor Turnstile2 {
    private var waiting: CheckedContinuation<Void, Never>?
    private var watching: CheckedContinuation<Void, Never>?
    private var opened = false
    private var here = false

    func wait() async {
        here = true
        watching?.resume()
        watching = nil
        if opened { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func arrived() async {
        if here { return }
        await withCheckedContinuation { watching = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
