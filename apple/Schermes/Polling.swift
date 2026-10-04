import SwiftUI

/// How much a poll's screen is in front of the owner. On a Mac a window stays `.active` behind
/// other apps and under other windows, so there it also takes the app being in front and the
/// window being visible.
enum PollPhase: Hashable, Sendable {
    case active
    case inactive
    case background

    static func of(scene: ScenePhase, frontmost: Bool = true, visible: Bool = true) -> PollPhase {
        switch scene {
        case .background: .background
        case .active where frontmost && visible: .active
        default: .inactive
        }
    }
}

/// The wait between two runs of a poll. Inactive is five times slower, which keeps a 2 s poll at
/// 10 s: the daemon reads the console's `x-schermes-attending` as fresh for 30 s. Failures double
/// the wait up to a minute, never below the phase's own, and one success puts it back.
enum PollSchedule {
    static let slowdown = 5
    static let cap: Duration = .seconds(60)

    /// An iPhone stops asking in the background. A Mac window minimised or behind others keeps
    /// asking slowly, because that poll is what announces a turn finishing there.
    #if os(iOS)
    static let pausesInBackground = true
    #else
    static let pausesInBackground = false
    #endif

    /// `nil` is paused: the poll ends, and starts again when the phase changes.
    static func interval(
        base: Duration, phase: PollPhase, failures: Int = 0, pausesInBackground: Bool = pausesInBackground
    ) -> Duration? {
        let calm: Duration
        switch phase {
        case .active: calm = base
        case .inactive: calm = base * slowdown
        case .background:
            if pausesInBackground { return nil }
            calm = base * slowdown
        }
        guard failures > 0 else { return calm }
        let backedOff = calm * (1 << min(failures, 10))
        return max(calm, min(backedOff, cap))
    }
}

extension Session {
    /// A poll's failure for a screen's one error slot, which it takes only when it is free.
    func note(_ error: any Error, in slot: inout String?) {
        guard slot == nil, let complaint = complaint(about: error) else { return }
        slot = complaint
    }

    /// Runs `tick` until cancelled or paused, waiting what `PollSchedule` says between runs. A
    /// failure goes to `failed` and backs the next wait off; a cancellation does neither.
    func poll(
        every base: Duration,
        _ phase: PollPhase,
        failed: (any Error) -> Void = { _ in },
        pausesInBackground: Bool = PollSchedule.pausesInBackground,
        _ tick: () async throws -> Void
    ) async {
        guard PollSchedule.interval(base: base, phase: phase, pausesInBackground: pausesInBackground) != nil else { return }
        var failures = 0
        while !Task.isCancelled {
            do {
                try await tick()
                failures = 0
            } catch where error.isCancellation {
            } catch {
                failures += 1
                failed(error)
            }
            guard !Task.isCancelled,
                  let wait = PollSchedule.interval(
                      base: base, phase: phase, failures: failures, pausesInBackground: pausesInBackground
                  )
            else { return }
            await nap(for: wait)
        }
    }
}

/// A poll's task id: whatever it polls for, and the phase, so a change of either restarts it.
struct PollKey<Value: Equatable>: Equatable {
    var value: Value
    var phase: PollPhase
}

extension EnvironmentValues {
    /// The console's phase, handed down so the chat's polls slow with it.
    @Entry var pollPhase: PollPhase = .active
}

/// The one poll of `/api/agents` and Needs you for the whole app: the console's sidebar and
/// inspector, the Mac's menu bar and its desktop windows all read this. Callers that ask in the
/// same moment share one request, and an ask soon after the last one is answered from it.
@Observable
final class AgentFeed {
    private(set) var agents: [Agent] = []
    private(set) var needs: [NeedsYouItem] = []
    /// At least one list has arrived, so an agent missing from it is really gone.
    private(set) var loaded = false
    /// Set by the console: the owner is at this device, which keeps their phone quiet.
    @ObservationIgnored var attending = false
    /// The menu bar panel is open.
    var shown = false

    @ObservationIgnored private let session: Session
    @ObservationIgnored private let looks: AgentLooks?
    @ObservationIgnored private var inFlight: Task<Void, any Error>?
    @ObservationIgnored private var fetchedAt: ContinuousClock.Instant?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(session: Session, looks: AgentLooks? = nil) {
        self.session = session
        self.looks = looks
    }

    /// `ifOlderThan` lets a poll skip a fetch another caller has just made. Zero always asks,
    /// which is what an action's follow-up wants.
    func refresh(ifOlderThan age: Duration = .zero) async throws {
        if let inFlight { return try await inFlight.value }
        if age > .zero, let fetchedAt, ContinuousClock.now - fetchedAt < age { return }
        let task = Task { try await fetch() }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        try await task.value
    }

    private func fetch() async throws {
        let attending = attending
        let rows = try await session.run { try await $0.agents(attending: attending) }
        if agents != rows { agents = rows }
        looks?.adopt(rows)
        let pending = try await session.run { try await $0.needsYou() }
        if needs != pending { needs = pending }
        fetchedAt = .now
        if !loaded { loaded = true }
    }

    func drop(_ id: String) {
        needs.removeAll { $0.id == id }
    }

    /// The Mac's own loop, for when the console window is closed and the menu bar is all that is
    /// left. While the console polls, this one's asks are mostly answered from its fetches.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled, let self {
                let phase: PollPhase = shown ? .active : .inactive
                let base: Duration = .seconds(2)
                if session.phase == .ready {
                    do {
                        try await refresh(ifOlderThan: (PollSchedule.interval(base: base, phase: phase) ?? base) * 0.75)
                        failures = 0
                    } catch where error.isCancellation {
                    } catch {
                        failures += 1
                    }
                }
                await session.nap(for: PollSchedule.interval(base: base, phase: phase, failures: failures) ?? base)
            }
        }
    }
}

#if os(macOS)
/// Whether the window holding this view can be seen at all: not minimised, on another Space or
/// covered whole by other windows.
struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var watching: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.map(NotificationCenter.default.removeObserver)
            watching = nil
            guard let window else { return }
            watching = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            changed(window.occlusionState.contains(.visible))
        }
    }
}
#endif
