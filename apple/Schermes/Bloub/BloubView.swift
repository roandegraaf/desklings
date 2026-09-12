import SwiftUI

/// One agent's avatar: the bloub engine sampled every frame and drawn into a `Canvas`.
///
/// The eyes are real holes punched in the body, as in bloub, not light shapes laid over it — that
/// is what makes them crop themselves against the silhouette when they slide towards the edge. A
/// hole shows whatever is drawn behind it, and the back half of the rings is drawn behind on
/// purpose, so an opaque backing in `paper` goes under the body first.
struct BloubView: View {
    let state: BloubStateId
    let identity: BloubIdentity
    var size: CGFloat = 44
    /// What shows through the eyes. Defaults to something close to the system background.
    var paper: BloubRGB?
    /// Freezes the picture at this many seconds into the state. The engine is a pure function of
    /// time, so this is reproducible to the pixel and needs no animation loop: the board uses it.
    var frozenAt: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var player: BloubPlayer
    @State private var epoch = Date()

    init(
        state: BloubStateId,
        identity: BloubIdentity,
        size: CGFloat = 44,
        paper: BloubRGB? = nil,
        frozenAt: Double? = nil
    ) {
        self.state = state
        self.identity = identity
        self.size = size
        self.paper = paper
        self.frozenAt = frozenAt
        _player = State(initialValue: BloubPlayer(state: state, shape: identity.shape))
    }

    var body: some View {
        Group {
            if let frozenAt {
                canvas(at: frozenAt)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(at: timeline.date.timeIntervalSince(epoch))
                }
            }
        }
        .frame(width: size, height: size)
        // The name and the state are already spoken by the row and the pill beside it.
        .accessibilityHidden(true)
        .onChange(of: state) { player.setState(state, now: Date().timeIntervalSince(epoch)) }
        .onChange(of: identity.shape) {
            player.setShape(identity.shape, now: Date().timeIntervalSince(epoch))
        }
    }

    private var ground: BloubRGB {
        paper ?? (colorScheme == .dark ? BloubRGB(hex: 0x1c1c1e) : BloubRGB(hex: 0xf9f9f9))
    }

    private func canvas(at now: Double) -> some View {
        // Reduce Motion keeps the morph, the blink and the drift, holds the orbit rings and the
        // comet ribbons at their phase origin, and plays a held clip only once.
        let frame = player.sample(now, reduceMotion: reduceMotion)
        let ink = identity.color.rgb(dark: colorScheme == .dark)
        let paper = ground
        let scale = player.engine.scale
        return Canvas(rendersAsynchronously: false) { context, canvasSize in
            let k = min(canvasSize.width, canvasSize.height) / (Bloub.halfViewBox * 2)
            context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.scaleBy(x: k, y: k)
            Self.draw(frame, ink: ink, paper: paper, scale: scale, into: &context)
        }
    }

    private static func draw(
        _ frame: BloubFrame,
        ink: BloubRGB,
        paper: BloubRGB,
        scale: Double,
        into context: inout GraphicsContext
    ) {
        // the back half of the orbits, drawn before the body so the body hides it
        for arc in frame.arcs { stroke(arc, arc.back, into: &context) }

        if frame.dotsBehind { drawDots(frame.dots, ink: ink, paper: paper, scale: scale, into: &context) }

        let body = closedPath(frame.body)
        context.drawLayer { layer in
            layer.opacity = frame.bodyAlpha
            // Opaque backing in the body's exact shape: without it a ring passing behind the ball
            // reappears inside the eyes.
            layer.fill(body, with: .color(paper.color))
            layer.drawLayer { inner in
                inner.fill(body, with: .color(ink.color))
                inner.blendMode = .destinationOut
                for eye in frame.eyes {
                    let capsule = Path(
                        roundedRect: CGRect(
                            x: -max(eye.w, 0.01) / 2,
                            y: -max(eye.h, 0.01) / 2,
                            width: max(eye.w, 0.01),
                            height: max(eye.h, 0.01)
                        ),
                        cornerRadius: min(max(eye.w, 0.01), max(eye.h, 0.01)) / 2
                    )
                    inner.fill(
                        capsule.applying(eye.transform),
                        with: .color(.black.opacity(eye.alpha))
                    )
                }
                if let notch = frame.notch {
                    inner.fill(circle(notch), with: .color(.black))
                }
            }
        }

        if !frame.dotsBehind { drawDots(frame.dots, ink: ink, paper: paper, scale: scale, into: &context) }

        if let notif = frame.notif {
            context.fill(circle(notif), with: .color(BloubDecor.notifBlue.color))
        }

        for arc in frame.arcs { stroke(arc, arc.front, into: &context) }
    }

    private static func drawDots(
        _ dots: [BloubDot],
        ink: BloubRGB,
        paper: BloubRGB,
        scale: Double,
        into context: inout GraphicsContext
    ) {
        for dot in dots {
            // The depth haze is what makes the burst's particles melt into the background as they
            // move away; a plain dot just takes the body's colour.
            let fill = dot.depth.map { BloubRGB.mix(paper, ink, $0) } ?? ink
            let path: Path
            if dot.teardrop {
                var shape = Path()
                shape.addLines(bloubTeardrop)
                shape.closeSubpath()
                path = shape.applying(
                    CGAffineTransform(translationX: dot.x, y: dot.y)
                        .rotated(by: dot.rot * .pi / 180)
                        .scaledBy(x: scale, y: scale)
                )
            } else {
                path = circle(BloubBlob(x: dot.x, y: dot.y, r: dot.r))
            }
            context.drawLayer { layer in
                layer.opacity = dot.opacity
                layer.fill(path, with: .color(fill.color))
            }
        }
    }

    private static func stroke(
        _ arc: BloubArcRender,
        _ runs: [[CGPoint]],
        into context: inout GraphicsContext
    ) {
        guard !runs.isEmpty else { return }
        var path = Path()
        for run in runs where run.count > 1 { path.addLines(run) }
        guard !path.isEmpty else { return }
        context.drawLayer { layer in
            layer.opacity = arc.opacity
            layer.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: arc.stops.map(\.color)),
                    startPoint: arc.gradientStart,
                    endPoint: arc.gradientEnd
                ),
                style: StrokeStyle(lineWidth: arc.width, lineCap: .round)
            )
        }
    }

    private static func circle(_ blob: BloubBlob) -> Path {
        Path(ellipseIn: CGRect(
            x: blob.x - blob.r,
            y: blob.y - blob.r,
            width: blob.r * 2,
            height: blob.r * 2
        ))
    }

    /// Closed polyline to Catmull-Rom cubics. With 64 points centred tangents are plenty: the
    /// outline is smooth to the pixel even at 600 px.
    private static func closedPath(_ points: [CGPoint], tension: CGFloat = 1.0 / 6.0) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            path.addCurve(
                to: p2,
                control1: CGPoint(
                    x: p1.x + (p2.x - p0.x) * tension,
                    y: p1.y + (p2.y - p0.y) * tension
                ),
                control2: CGPoint(
                    x: p2.x - (p3.x - p1.x) * tension,
                    y: p2.y - (p3.y - p1.y) * tension
                )
            )
        }
        path.closeSubpath()
        return path
    }
}

extension BloubRGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension BloubColorId {
    /// bloub draws on one ground; this app draws on a light one and a dark one. Ink on the dark and
    /// cream on the light are a silhouette with no edge and eyes the colour of the ground, so on
    /// that ground each moves just off it: ink to a light grey, cream to a sand, both clear of `grey`.
    func rgb(dark: Bool) -> BloubRGB {
        switch self {
        case .ink where dark: BloubRGB(hex: 0xd1d1d6)
        case .cream where !dark: BloubRGB(hex: 0xbfb190)
        default: rgb
        }
    }
}
