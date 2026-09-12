import CoreGraphics
import Foundation
import Testing
@testable import Schermes

/// The Swift port against bloub's own values. Everything in `bloubGoldenJSON` was produced by
/// running bloub's TypeScript engine at the ported commit, so these are not self-comparisons: a
/// drift in the port fails here instead of quietly changing the face.
///
/// Body points are the anchors of bloub's `closedPath`, which are exactly `toPoints` rounded to
/// two decimals — hence the 0.01 tolerances on anything that came through a path string.

private struct Goldens: Decodable {
    struct Eye: Decodable {
        let w: Double
        let h: Double
        let m: [Double]
        let alpha: Double
    }

    struct Dot: Decodable {
        let x: Double
        let y: Double
        let r: Double
        let opacity: Double
        /// -1 stands in for "no depth haze"
        let depth: Double
        let tear: Int
        let rot: Double
    }

    struct Arc: Decodable {
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

    struct Frame: Decodable {
        let state: String
        let t: Double
        let body: [Double]
        let bodyAlpha: Double
        let dotsBehind: Bool
        let eyes: [Eye]
        let dots: [Dot]
        let arcs: [Arc]
        let notif: [Double]
        let notch: [Double]
    }

    struct Bodied: Decodable {
        let t: Double
        let body: [Double]
    }

    struct Shaped: Decodable {
        let shape: String
        let t: Double
        let body: [Double]
        let eyes: [[Double]]
    }

    struct Fit: Decodable {
        let id: String
        let entries: [String: [Double]]
    }

    let frames: [Frame]
    let morphs: [Bodied]
    let fades: [Bodied]
    let chained: [Bodied]
    let shaped: [Shaped]
    let eyefit: [Fit]
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

@Test func theEyesMatchBloubOnEveryState() {
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
@Test func theEyeOffsetTableMatchesBloubForEveryShapeAndExpression() {
    for fit in goldens.eyefit {
        let shape = shapeByBloubId[fit.id]!
        for (key, want) in fit.entries {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            let got = BloubEyefit.offset(
                shape: shape,
                state: state(String(parts[0])),
                expression: parts[1].isEmpty ? nil : expressionByBloubId[String(parts[1])]!
            )
            #expect(abs(got.x - want[0]) < 0.0001, "\(fit.id) \(key) x")
            #expect(abs(got.y - want[1]) < 0.0001, "\(fit.id) \(key) y")
        }
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
    #expect(AgentState.waiting_for_user.bloub == .notify)
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

@Test func aHeldToolStateIsStillInsideItsClipLongAfterItStarted() {
    for state in [BloubStateId.comet, .orbit] {
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

extension BloubIdentity: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(shape)
        hasher.combine(color)
    }
}
