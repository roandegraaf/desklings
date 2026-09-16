import CoreGraphics
import Foundation
import Testing
@testable import Schermes

/// The Swift port against bloub's own values. The bodies, dots, arcs and badges in
/// `bloubGoldenJSON` were produced by running bloub's TypeScript engine at the ported commit, so
/// those are not self-comparisons: a drift in the port fails here instead of quietly changing
/// the face. The eyes are the port's own: its life at rest has moved on from bloub's (glances, an
/// eased blink), so they are snapshots, rewritten by `rewriteTheEyeGoldensWhenAsked` whenever
/// that life is tuned on purpose.
///
/// Body points are the anchors of bloub's `closedPath`, which are exactly `toPoints` rounded to
/// two decimals — hence the 0.01 tolerances on anything that came through a path string.

private struct Goldens: Codable {
    struct Eye: Codable {
        let w: Double
        let h: Double
        let m: [Double]
        let alpha: Double
    }

    struct Dot: Codable {
        let x: Double
        let y: Double
        let r: Double
        let opacity: Double
        /// -1 stands in for "no depth haze"
        let depth: Double
        let tear: Int
        let rot: Double
    }

    struct Arc: Codable {
        let id: String
        let width: Double
        let opacity: Double
        let gx1: Double
        let gy1: Double
        let gx2: Double
        let gy2: Double
        let stops: [String]
        let front: [[Double]]
        let back: [[Double]]
    }

    struct Frame: Codable {
        let state: String
        let t: Double
        let body: [Double]
        let bodyAlpha: Double
        let dotsBehind: Bool
        var eyes: [Eye]
        let dots: [Dot]
        let arcs: [Arc]
        let notif: [Double]
        let notch: [Double]
    }

    struct Bodied: Codable {
        let t: Double
        let body: [Double]
    }

    struct Shaped: Codable {
        let shape: String
        let t: Double
        let body: [Double]
        var eyes: [[Double]]
    }

    struct Fit: Codable {
        let id: String
        var entries: [String: [Double]]
    }

    var frames: [Frame]
    let morphs: [Bodied]
    let fades: [Bodied]
    let chained: [Bodied]
    var shaped: [Shaped]
    var eyefit: [Fit]
}

private let goldens: Goldens = try! JSONDecoder()
    .decode(Goldens.self, from: Data(bloubGoldenJSON.utf8))

/// bloub names its shapes and expressions in French; the port names them in English.
private let shapeByBloubId: [String: BloubShapeId] = [
    "cercle": .circle, "galet": .pebble, "squircle": .squircle, "capsule": .capsule,
    "triangle": .triangle, "hexagone": .hexagon, "nuage": .cloud, "goutte": .droplet
]

private let expressionByBloubId: [String: BloubExpressionId] = [
    "neutre": .neutral, "attentif": .attentive, "surpris": .surprised, "excite": .excited,
    "heureux": .happy, "hilare": .laughing, "colere": .angry, "triste": .sad,
    "effraye": .scared, "mefiant": .wary, "confus": .confused, "curieux": .curious,
    "fier": .proud, "timide": .shy, "blase": .bored, "somnolent": .sleepy
]

private func state(_ name: String) -> BloubStateId {
    BloubStateId(rawValue: name)!
}

/// Flat x, y pairs against the engine's points.
private func expectBody(_ got: [CGPoint], _ want: [Double], _ label: String) {
    #expect(got.count * 2 == want.count, "\(label): \(got.count) points")
    for i in 0..<min(got.count, want.count / 2) {
        #expect(abs(got[i].x - want[i * 2]) < 0.01, "\(label) point \(i) x")
        #expect(abs(got[i].y - want[i * 2 + 1]) < 0.01, "\(label) point \(i) y")
    }
}

@Test func theBodyMatchesBloubOnEveryState() {
    for want in goldens.frames {
        let frame = BloubEngine(state: state(want.state)).sample(want.t)
        expectBody(frame.body, want.body, "\(want.state)@\(want.t)")
        #expect(abs(frame.bodyAlpha - want.bodyAlpha) < 0.001, "\(want.state)")
        #expect(frame.dotsBehind == want.dotsBehind, "\(want.state)")
    }
}

@Test func theEyesMatchTheSnapshotOnEveryState() {
    for want in goldens.frames {
        let frame = BloubEngine(state: state(want.state)).sample(want.t)
        let label = "\(want.state)@\(want.t)"
        #expect(frame.eyes.count == want.eyes.count, "\(label)")
        for (eye, reference) in zip(frame.eyes, want.eyes) {
            #expect(abs(eye.w / Bloub.radius - reference.w) < 0.001, "\(label) eye width")
            #expect(abs(eye.h / Bloub.radius - reference.h) < 0.001, "\(label) eye height")
            let m = eye.transform
            let got = [m.a, m.b, m.c, m.d, m.tx, m.ty]
            for (i, value) in got.enumerated() {
                #expect(abs(value - reference.m[i]) < 0.01, "\(label) matrix \(i)")
            }
            #expect(abs(eye.alpha - reference.alpha) < 0.001, "\(label) eye alpha")
        }
    }
}

@Test func theDotsMatchBloubOnEveryState() {
    for want in goldens.frames {
        let frame = BloubEngine(state: state(want.state)).sample(want.t)
        let label = "\(want.state)@\(want.t)"
        #expect(frame.dots.count == want.dots.count, "\(label)")
        for (dot, reference) in zip(frame.dots, want.dots) {
            #expect(abs(dot.x - reference.x) < 0.001, "\(label) dot x")
            #expect(abs(dot.y - reference.y) < 0.001, "\(label) dot y")
            #expect(abs(dot.r - reference.r) < 0.001, "\(label) dot r")
            #expect(abs(dot.opacity - reference.opacity) < 0.001, "\(label) dot opacity")
            #expect(abs((dot.depth ?? -1) - reference.depth) < 0.001, "\(label) dot depth")
            #expect(dot.teardrop == (reference.tear == 1), "\(label) dot shape")
            #expect(abs(dot.rot - reference.rot) < 0.001, "\(label) dot rotation")
        }
    }
}

@Test func theOrbitsMatchBloubIncludingTheirDepthSplitAndGradients() {
    for want in goldens.frames {
        let frame = BloubEngine(state: state(want.state)).sample(want.t)
        let label = "\(want.state)@\(want.t)"
        #expect(frame.arcs.count == want.arcs.count, "\(label)")
        for (arc, reference) in zip(frame.arcs, want.arcs) {
            #expect(arc.id == reference.id, "\(label)")
            #expect(abs(arc.width - reference.width) < 0.001, "\(label) \(arc.id) width")
            #expect(abs(arc.opacity - reference.opacity) < 0.001, "\(label) \(arc.id) opacity")
            #expect(abs(arc.gradientStart.x - reference.gx1) < 0.01, "\(label) \(arc.id) gradient")
            #expect(abs(arc.gradientStart.y - reference.gy1) < 0.01, "\(label) \(arc.id) gradient")
            #expect(abs(arc.gradientEnd.x - reference.gx2) < 0.01, "\(label) \(arc.id) gradient")
            #expect(abs(arc.gradientEnd.y - reference.gy2) < 0.01, "\(label) \(arc.id) gradient")
            #expect(arc.stops.map(\.hex) == reference.stops, "\(label) \(arc.id) stops")
            // The depth sort is what makes the rings read as orbits: a run count that drifts means
            // the front/back split moved.
            #expect(arc.front.count == reference.front.count, "\(label) \(arc.id) front runs")
            #expect(arc.back.count == reference.back.count, "\(label) \(arc.id) back runs")
            for (run, wantRun) in zip(arc.front + arc.back, reference.front + reference.back) {
                #expect(run.count * 2 == wantRun.count, "\(label) \(arc.id) run length")
                for i in 0..<min(run.count, wantRun.count / 2) {
                    #expect(abs(run[i].x - wantRun[i * 2]) < 0.01, "\(label) \(arc.id) x")
                    #expect(abs(run[i].y - wantRun[i * 2 + 1]) < 0.01, "\(label) \(arc.id) y")
                }
            }
        }
    }
}

@Test func theNotificationBadgeAndItsNotchMatchBloub() {
    for want in goldens.frames {
        let frame = BloubEngine(state: state(want.state)).sample(want.t)
        for (got, reference) in [(frame.notif, want.notif), (frame.notch, want.notch)] {
            guard let got else {
                #expect(reference.isEmpty, "\(want.state)")
                continue
            }
            #expect(abs(got.x - reference[0]) < 0.001, "\(want.state)")
            #expect(abs(got.y - reference[1]) < 0.001, "\(want.state)")
            #expect(abs(got.r - reference[2]) < 0.001, "\(want.state)")
        }
    }
}

@Test func aShapeMorphFollowsBloubFrameForFrame() {
    let engine = BloubEngine(state: .idle, shape: .circle)
    engine.setShape(.capsule, now: 1)
    for want in goldens.morphs {
        expectBody(engine.sample(want.t).body, want.body, "morph@\(want.t)")
    }
}

@Test func aStateFadeFollowsBloubFrameForFrame() {
    let engine = BloubEngine(state: .idle)
    engine.setState(.egg, now: 1)
    for want in goldens.fades {
        expectBody(engine.sample(want.t).body, want.body, "fade@\(want.t)")
    }
}

@Test func aStateChangeLandingInsideAFadeStartsFromTheFrozenPose() {
    let engine = BloubEngine(state: .idle)
    engine.setState(.wide, now: 0.5)
    engine.setState(.idle, now: 0.6)
    for want in goldens.chained {
        expectBody(engine.sample(want.t).body, want.body, "chained@\(want.t)")
    }
}

@Test func aCustomShapeCarriesItsOwnBodyAndEyeOffset() {
    for want in goldens.shaped {
        let shape = shapeByBloubId[want.shape]!
        let frame = BloubEngine(state: .idle, shape: shape, expression: .neutral).sample(want.t)
        expectBody(frame.body, want.body, "\(want.shape)")
        #expect(frame.eyes.count == want.eyes.count, "\(want.shape)")
        for (eye, reference) in zip(frame.eyes, want.eyes) {
            let m = eye.transform
            for (i, value) in [m.a, m.b, m.c, m.d, m.tx, m.ty].enumerated() {
                #expect(abs(value - reference[i]) < 0.01, "\(want.shape) matrix \(i)")
            }
        }
    }
}

/// The one table this port could silently get wrong: a missed lookup returns zero, which is a
/// valid-looking answer and puts the eye back through the edge of a capsule or a droplet.
/// `state|expression`, the expression in bloub's French and empty for a state with no resting face.
private func fitOffset(_ shape: BloubShapeId, _ key: String) -> CGPoint {
    let parts = key.split(separator: "|", omittingEmptySubsequences: false)
    return BloubEyefit.offset(
        shape: shape,
        state: state(String(parts[0])),
        expression: parts[1].isEmpty ? nil : expressionByBloubId[String(parts[1])]!
    )
}

/// The app turns these two faces to look right, where bloub had them looking left or ahead, so
/// the offsets fitted to them are the app's own.
private let turnedRight: Set = ["notify", "wide"]

@Test func theEyeOffsetTableMatchesBloubForEveryShapeAndExpression() {
    for fit in goldens.eyefit {
        for (key, want) in fit.entries where !turnedRight.contains(String(key.prefix { $0 != "|" })) {
            let got = fitOffset(shapeByBloubId[fit.id]!, key)
            #expect(abs(got.x - want[0]) < 0.0001, "\(fit.id) \(key) x")
            #expect(abs(got.y - want[1]) < 0.0001, "\(fit.id) \(key) y")
        }
    }
}

private func eyeMatrix(_ eye: BloubRenderedEye) -> [Double] {
    let m = eye.transform
    let values: [Double] = [m.a, m.b, m.c, m.d, m.tx, m.ty]
    return values.map { ($0 * 1_000_000).rounded() / 1_000_000 }
}

/// Rewrites the eye entries of `BloubGoldens.swift` from the engine as it is now; the bodies,
/// dots, arcs, badges and the eye-offset table are bloub's and are left alone. Run it on purpose,
/// after tuning the life at rest, with `TEST_RUNNER_SCHERMES_WRITE_GOLDENS=<path to the file>`.
/// That run still compares against the old snapshot and fails; the next plain run is the check.
@Test func rewriteTheEyeGoldensWhenAsked() throws {
    guard let path = ProcessInfo.processInfo.environment["SCHERMES_WRITE_GOLDENS"] else { return }
    func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
    var root = goldens

    for i in root.frames.indices {
        let frame = BloubEngine(state: state(root.frames[i].state)).sample(root.frames[i].t)
        root.frames[i].eyes = frame.eyes.map {
            Goldens.Eye(w: round6($0.w / Bloub.radius), h: round6($0.h / Bloub.radius), m: eyeMatrix($0), alpha: round6($0.alpha))
        }
    }
    for i in root.shaped.indices {
        let shape = shapeByBloubId[root.shaped[i].shape]!
        root.shaped[i].eyes = BloubEngine(state: .idle, shape: shape, expression: .neutral)
            .sample(root.shaped[i].t).eyes.map(eyeMatrix)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(root), as: UTF8.self)
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let opening = source.range(of: "let bloubGoldenJSON = \"\"\"\n")!
    try (source[..<opening.upperBound] + json + "\n\"\"\"\n").write(toFile: path, atomically: true, encoding: .utf8)
}

@Test func theGazeFlicksNowAndThenInsteadOfOnlySliding() {
    let engine = BloubEngine(state: .idle)
    var last: Double?
    var fastest = 0.0
    for tick in 0...(60 * 30) {
        let eyes = engine.sample(Double(tick) / 60).eyes
        let x = eyes.map { Double($0.transform.tx) }.reduce(0, +) / Double(eyes.count)
        if let last { fastest = max(fastest, abs(x - last)) }
        last = x
    }
    // the smooth drift moves the eyes a fifth of a unit a frame; a glance moves them one or more
    #expect(fastest > 1)
}

/// The eye-offset table was fitted to these peaks; a glance must fit inside them, not add to them.
@Test func theLifeAtRestStaysInsideTheFittedDriftBox() {
    for tick in 0...(100 * 60) {
        let life = bloubLiveliness(Double(tick) / 100)
        #expect(abs(life.dYaw) <= 5.5 + 1.6 + 1e-9)
        #expect(abs(life.dPitch) <= 4.2 + 1.3 + 1e-9)
    }
}

@Test func theEyeOffsetTableIsNotAllZeroOnTheShapesThatNeedIt() {
    // Guards the test above against a decoding accident that made every reference zero.
    for shape in [BloubShapeId.capsule, .triangle, .cloud, .droplet] {
        let offset = BloubEyefit.offset(shape: shape, state: .idle, expression: .neutral)
        #expect(offset != .zero, "\(shape) needs a correction")
    }
    #expect(BloubEyefit.offset(shape: .circle, state: .idle, expression: .neutral) == .zero)
    #expect(BloubEyefit.offset(shape: nil, state: .idle, expression: .neutral) == .zero)
}

@Test func samplingIsAPureFunctionOfTimeEvenAcrossAFade() {
    let engine = BloubEngine(state: .idle)
    engine.setState(.egg, now: 1)
    let midFade = engine.sample(1.2).body
    // read past the end of the fade, then read the old date back
    _ = engine.sample(3)
    #expect(engine.sample(1.2).body == midFade)
}

@Test func readingADateBeforeAStateChangeStillShowsTheStateBeingLeft() {
    let engine = BloubEngine(state: .idle)
    let before = engine.sample(0.5).body
    engine.setState(.egg, now: 1)
    #expect(engine.sample(0.5).body == before)
}

@Test func resetForgetsThePreviousStateWhereSetStateKeepsItToFadeIt() {
    let faded = BloubEngine(state: .idle)
    faded.setState(.egg, now: 0)
    let rewound = BloubEngine(state: .idle)
    rewound.reset(.egg, now: 0)
    #expect(faded.sample(0).body != rewound.sample(0).body)
    #expect(rewound.sample(0).body == BloubEngine(state: .egg).sample(0).body)
}

@Test func theBodyNeverLeavesTheViewBox() {
    for def in BloubStates.all {
        for t in [0.2, 0.9, 1.8, 3.0] {
            for point in BloubEngine(state: def.id).sample(t).body {
                #expect(abs(point.x) < Bloub.halfViewBox, "\(def.id)@\(t)")
                #expect(abs(point.y) < Bloub.halfViewBox, "\(def.id)@\(t)")
            }
        }
    }
}

@Test func theCatalogueIsTheFourteenStatesOfTheVideoPlusOneInterfaceTransition() {
    #expect(BloubStates.sequence.count == 14)
    #expect(Set(BloubStates.sequence).count == 14)
    #expect(BloubStateId.allCases.count == 15)
    #expect(BloubStateId.allCases.filter { !BloubStates.sequence.contains($0) } == [.swirl])
    #expect(BloubStates.all.count == 15)
}

@Test func everyAgentStateHasAFace() {
    // The switch is exhaustive, so this is really about the states keeping distinct faces where
    // the owner needs to tell them apart at a glance.
    let table = AgentState.allCases.map(\.bloub)
    #expect(table.count == AgentState.allCases.count)
    #expect(AgentState.thinking.bloub == .thinking)
    #expect(AgentState.using_computer.bloub == .orbit)
    #expect(AgentState.using_terminal.bloub == .comet)
    #expect(AgentState.waiting_for_user.bloub == .idle)
    #expect(AgentState.waiting_for_agent.bloub == .wide)
    #expect(AgentState.waiting_for_task_worker.bloub == .wide)
    #expect(AgentState.failed.bloub == .exclaim)
    #expect(AgentState.completed.bloub == .sleep)
    #expect(AgentState.idle.bloub == .idle)
}

@Test func anAgentNeverSeenBeforeGetsAStableLookFromItsName() {
    #expect(BloubIdentity.standard(for: "scout") == BloubIdentity.standard(for: "scout"))
    #expect(BloubIdentity.standard(for: "scout") != BloubIdentity.standard(for: "archivist"))
    // Not every name may land on a different shape, but the pair must not collapse to one look.
    let looks = Set(["scout", "archivist", "runner", "mole", "clerk", "pilot", "smith", "wren"]
        .map { BloubIdentity.standard(for: $0) })
    #expect(looks.count > 4)
}

@MainActor
@Test func aChosenLookSurvivesARoundTripThroughStorage() {
    let suite = "bloub-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let looks = AgentLooks(defaults: defaults)
    #expect(looks["scout"] == BloubIdentity.standard(for: "scout"))
    let chosen = BloubIdentity(shape: .droplet, color: .teal)
    looks["scout"] = chosen

    let reopened = AgentLooks(defaults: defaults)
    #expect(reopened["scout"] == chosen)
    #expect(reopened["archivist"] == BloubIdentity.standard(for: "archivist"))
}

@Test func theCometHoldsItsDotAndRibbonsForAsLongAsTheTerminalRuns() {
    let engine = BloubEngine(state: .comet)
    for now in [1.0, 5.0, 30.0] {
        let frame = engine.sample(now)
        #expect(frame.eyes.isEmpty, "\(now)")
        #expect(frame.arcs.count == BloubDecor.cometRibbons.count, "\(now)")
        #expect(frame.arcs.allSatisfy { $0.opacity == 1 }, "\(now)")
        let radius = frame.body.map { hypot($0.x, $0.y) }.max()!
        #expect(abs(radius - BloubDecor.cometDot * Bloub.radius) < 4, "\(now): \(radius)")
    }
    // the ribbons never stop turning
    #expect(engine.sample(5).arcs[0].front != engine.sample(5.1).arcs[0].front)
}

@Test func aHeldToolStateIsStillInsideItsClipLongAfterItStarted() {
    for state in [BloubStateId.orbit] {
        let player = BloubPlayer(state: state, shape: .capsule)
        // frame by frame for thirty seconds, as the timeline samples it
        for tick in 0...(60 * 30) { _ = player.sample(Double(tick) / 60, reduceMotion: false) }

        let loop = state.heldLoop!
        let length = loop.upperBound - loop.lowerBound
        let clip = loop.lowerBound + (30 - loop.lowerBound).truncatingRemainder(dividingBy: length)
        let got = player.sample(30, reduceMotion: false).arcs
        let want = BloubEngine(state: state).sample(clip).arcs
        #expect(!got.isEmpty, "\(state)")
        #expect(got.count == want.count, "\(state)")
        for (g, w) in zip(got, want) {
            #expect(abs(g.opacity - w.opacity) < 1e-6, "\(state) \(g.id)")
            for (p, q) in zip(g.front.joined(), w.front.joined()) {
                #expect(abs(p.x - q.x) < 1e-6 && abs(p.y - q.y) < 1e-6, "\(state) \(g.id)")
            }
        }
        // The engine alone played it once and has long since come to rest with nothing round it.
        #expect(BloubEngine(state: state).sample(30).arcs.isEmpty, "\(state)")
    }
}

@Test func underReduceMotionAHeldClipPlaysOnceAsItAlwaysHas() {
    for state in [BloubStateId.comet, .orbit] {
        let player = BloubPlayer(state: state, shape: nil)
        let engine = BloubEngine(state: state, shape: nil, expression: .neutral)
        for tick in stride(from: 0, through: 60 * 10, by: 6) {
            let now = Double(tick) / 60
            #expect(player.sample(now, reduceMotion: true).body == engine.sample(now, decorStill: true).body)
        }
    }
}

@Test func everyAgentWithAFaceAtRestLooksRight() {
    // The computer pose's eyes follow its orbit round the ball, so it has no side to rest on.
    for state in AgentState.allCases where state.bloub != .orbit {
        for shape in BloubShapeId.allCases {
            let player = BloubPlayer(state: state.bloub, shape: shape)
            // averaged over the drift, so a glance to the left at one instant does not count
            let samples = (10...60).map { player.sample(Double($0) / 10, reduceMotion: false).eyes }
            guard !samples[0].isEmpty else { continue }
            let x = samples.flatMap { $0 }.map { Double($0.transform.tx) }.reduce(0, +)
                / Double(samples.count * samples[0].count)
            // Within a twentieth of the ball's radius of the middle is looking straight ahead.
            #expect(x > -5, "\(state) on a \(shape) looks left: \(x)")
        }
    }
}

/// The eyes' mean centre once a player has followed `aim` for two seconds at sixty frames.
private func settledEyes(
    state: BloubStateId = .idle,
    shape: BloubShapeId? = nil,
    aim: CGPoint?
) -> (frame: BloubFrame, centre: CGPoint) {
    let player = BloubPlayer(state: state, shape: shape)
    var frame = player.sample(0, reduceMotion: false, aim: aim)
    for tick in 1...120 { frame = player.sample(Double(tick) / 60, reduceMotion: false, aim: aim) }
    let n = Double(frame.eyes.count)
    return (frame, CGPoint(
        x: frame.eyes.map { Double($0.transform.tx) }.reduce(0, +) / n,
        y: frame.eyes.map { Double($0.transform.ty) }.reduce(0, +) / n
    ))
}

@Test func theEyesTurnTowardsThePointer() {
    let right = settledEyes(aim: CGPoint(x: 1, y: 0)).centre
    let left = settledEyes(aim: CGPoint(x: -1, y: 0)).centre
    let below = settledEyes(aim: CGPoint(x: 0, y: 1)).centre
    let above = settledEyes(aim: CGPoint(x: 0, y: -1)).centre
    #expect(right.x > left.x + 10)
    // screen y grows downwards
    #expect(below.y > above.y + 10)
}

private func inside(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
    var hit = false
    var j = polygon.count - 1
    for i in polygon.indices {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            hit.toggle()
        }
        j = i
    }
    return hit
}

/// The eye-offset table is solved for the resting gaze and its drift only, so a follow that
/// turns further than it covers would open a notch in the silhouette.
@Test func aFollowingFaceStaysInsideEveryShape() {
    // the aim is at most 1 long: its centre, then round the circle at twice the solver's density
    let aims = [CGPoint.zero] + (0..<16).map {
        CGPoint(x: cos(Double($0) / 16 * bloubTau), y: sin(Double($0) / 16 * bloubTau))
    }
    for state in BloubStateId.allCases where state.pointerReach != nil && state != .swirl {
    for shape in BloubShapeId.allCases {
        for aim in aims {
            let frame = settledEyes(state: state, shape: shape, aim: aim).frame
            #expect(!frame.eyes.isEmpty, "\(state)")
            for eye in frame.eyes {
                let r = min(eye.w, eye.h) / 2
                let reach = CGSize(width: eye.w / 2 - r, height: eye.h / 2 - r)
                let outline = (0..<24).flatMap { k -> [CGPoint] in
                    let a = Double(k) / 24 * .pi * 2
                    return [-1.0, 1].map {
                        CGPoint(x: reach.width * $0 + r * cos(a), y: reach.height * $0 + r * sin(a))
                            .applying(eye.transform)
                    }
                }
                let spilled = outline.filter { !inside($0, frame.body) }.count
                #expect(spilled == 0, "\(state) on \(shape) aimed at \(aim): \(spilled) outside")
            }
        }
    }
    }
}

#if os(macOS)
@Test func thePointerIsAimedAtFromTheAvatarNotFromTheWindow() {
    let window = CGRect(x: 0, y: 0, width: 1000, height: 600)
    // an avatar in the sidebar's top corner
    let centre = CGPoint(x: 40, y: 500)
    func aim(_ x: Double, _ y: Double) -> CGPoint? {
        PointerAnchor.aim(mouse: CGPoint(x: x, y: y), centre: centre, window: window, reach: 132)
    }
    // far below it, near the left edge: straight down, whatever the window's middle
    let below = aim(40, 20)!
    #expect(abs(below.x) < 1e-9 && below.y > 0.75 && below.y < 1)
    // level with it, far right: straight right
    let right = aim(900, 500)!
    #expect(right.x > 0.75 && right.x < 1 && abs(right.y) < 1e-9)
    // just above it on screen tilts the gaze up, less than from further away
    let above = aim(40, 560)!
    #expect(above.y < 0 && above.y > -0.5)
    #expect(BloubLook.following(nx: above.x, ny: above.y).pitch > 0)
    #expect(abs(aim(40, 590)!.y) > abs(above.y))
    #expect(aim(1200, 300) == nil)
}
#endif

@Test func aFollowingFacePointsStraightAtThePointer() {
    for aim in [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -0.6, y: 0.8), CGPoint(x: 0.3, y: -0.2)] {
        let look = BloubLook.following(nx: aim.x, ny: aim.y)
        // the face's normal, projected on screen: the eyes' midpoint with no split
        let face = bloubEyePoses(BloubGaze(yaw: look.yaw, pitch: look.pitch, roll: 0), 1, 0).0
        let length = hypot(aim.x, aim.y)
        let turn = length * BloubLook.followTurn * .pi / 180
        #expect(abs(face.x - sin(turn) * aim.x / length) < 1e-9, "\(aim)")
        #expect(abs(face.y - sin(turn) * aim.y / length) < 1e-9, "\(aim)")
    }
}

@Test func avatarsOnDifferentPhasesDoNotBlinkTogether() {
    let a = BloubEngine(state: .idle, phase: 0)
    let b = BloubEngine(state: .idle, phase: 137)
    var apart = 0
    for tick in 0...(60 * 20) {
        let now = Double(tick) / 60
        let lidA = a.sample(now).eyes[0].transform.d
        let lidB = b.sample(now).eyes[0].transform.d
        if abs(lidA - lidB) > 0.05 { apart += 1 }
    }
    #expect(apart > 30)
}

@Test func aBlinkStillComesAfterTheScheduleWrapsRound() {
    let engine = BloubEngine(state: .idle)
    var shut = false
    for tick in 0...(60 * 10) {
        let d = engine.sample(bloubLifePeriod + Double(tick) / 60).eyes[0].transform.d
        if abs(d) < 0.5 { shut = true }
    }
    #expect(shut)
}

@Test func aStateThatOwnsItsGazeIgnoresThePointer() {
    let aimed = settledEyes(state: .orbit, aim: CGPoint(x: 1, y: 1)).frame.eyes
    let alone = settledEyes(state: .orbit, aim: nil).frame.eyes
    #expect(!aimed.isEmpty)
    #expect(aimed.map(\.transform) == alone.map(\.transform))
}

@Test func thePointerLeavingHandsTheFaceBackToItsRest() {
    let released = BloubPlayer(state: .idle, shape: .droplet)
    let untouched = BloubPlayer(state: .idle, shape: .droplet)
    for tick in 0...300 {
        let now = Double(tick) / 60
        _ = released.sample(now, reduceMotion: false, aim: tick < 120 ? CGPoint(x: -1, y: 1) : nil)
    }
    let got = released.sample(5, reduceMotion: false).eyes.map(\.transform)
    let want = untouched.sample(5, reduceMotion: false).eyes.map(\.transform)
    #expect(got.count == want.count)
    for (g, w) in zip(got, want) {
        #expect(abs(g.tx - w.tx) < 1e-6 && abs(g.ty - w.ty) < 1e-6)
    }
}

extension BloubIdentity: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(shape)
        hasher.combine(color)
    }
}
