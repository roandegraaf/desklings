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
    #if os(macOS)
    @State private var pointer = PointerAnchor()
    #endif

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
        // A frozen picture keeps phase 0, so the board stays reproducible to the pixel.
        _player = State(initialValue: BloubPlayer(
            state: state,
            shape: identity.shape,
            phase: frozenAt == nil ? .random(in: 0..<bloubLifePeriod) : 0
        ))
    }

    var body: some View {
        Group {
            if let frozenAt {
                canvas(at: frozenAt, aim: nil)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(at: timeline.date.timeIntervalSince(epoch), aim: aim)
                }
            }
        }
        .frame(width: size, height: size)
        #if os(macOS)
        .background(PointerAnchorView(anchor: pointer))
        #endif
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

    // ponytail: the Mac only. An iPad pointer would need a hover gesture feeding the same aim.
    private var aim: CGPoint? {
        #if os(macOS)
        pointer.aim()
        #else
        nil
        #endif
    }

    private func canvas(at now: Double, aim: CGPoint?) -> some View {
        // Reduce Motion keeps the morph, the blink and the drift, holds the orbit rings and the
        // comet ribbons at their phase origin, and plays a held clip only once.
        let frame = player.sample(now, reduceMotion: reduceMotion, aim: aim)
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

        // A layer per frame per avatar is the expensive part of drawing one, and at full opacity
        // compositing it is the same as drawing straight in.
        if frame.bodyAlpha >= 1 {
            drawBody(frame, ink: ink, paper: paper, into: &context)
        } else {
            context.drawLayer { layer in
                layer.opacity = frame.bodyAlpha
                drawBody(frame, ink: ink, paper: paper, into: &layer)
            }
        }

        if !frame.dotsBehind { drawDots(frame.dots, ink: ink, paper: paper, scale: scale, into: &context) }

        if let notif = frame.notif {
            context.fill(circle(notif), with: .color(BloubDecor.notifBlue.color))
        }

        for arc in frame.arcs { stroke(arc, arc.front, into: &context) }
    }

    private static func drawBody(
        _ frame: BloubFrame,
        ink: BloubRGB,
        paper: BloubRGB,
        into context: inout GraphicsContext
    ) {
        let body = closedPath(frame.body)
        // Opaque backing in the body's exact shape: without it a ring passing behind the ball
        // reappears inside the eyes.
        context.fill(body, with: .color(paper.color))
        context.drawLayer { inner in
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
            // One fill, so opacity on a copy of the context composites exactly as a layer would.
            var faded = context
            faded.opacity = dot.opacity
            faded.fill(path, with: .color(fill.color))
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
        var faded = context
        faded.opacity = arc.opacity
        faded.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: arc.stops.map(\.color)),
                startPoint: arc.gradientStart,
                endPoint: arc.gradientEnd
            ),
            style: StrokeStyle(lineWidth: arc.width, lineCap: .round)
        )
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

#if os(macOS)
/// The avatar's own spot in AppKit, so it can find the pointer on every frame without an event
/// stream: `NSEvent.mouseLocation` can be read at any time, in whichever window the avatar sits.
/// A hover on the root view would miss the sheets, popovers and Settings, which are windows of
/// their own.
final class PointerAnchor {
    fileprivate weak var view: NSView?

    /// The direction from the avatar's centre to the pointer, y down, half length when the pointer
    /// is three avatars away and closing on full length the further it goes; nil while the pointer
    /// is outside the window.
    func aim() -> CGPoint? {
        guard let view, let window = view.window else { return nil }
        let centre = window.convertPoint(
            toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        )
        return Self.aim(
            mouse: NSEvent.mouseLocation,
            centre: centre,
            window: window.frame,
            reach: view.bounds.width * 3
        )
    }

    /// Mouse, centre and window in screen coordinates, which grow upwards.
    nonisolated static func aim(mouse: CGPoint, centre: CGPoint, window: CGRect, reach: Double) -> CGPoint? {
        guard window.contains(mouse) else { return nil }
        let dx = mouse.x - centre.x
        let dy = centre.y - mouse.y
        let d = hypot(dx, dy)
        guard d > 0 else { return .zero }
        // Saturates smoothly instead of stopping dead at `reach`: a pointer over the avatar barely
        // turns it, and one across the window still turns it further than one nearby.
        let k = atan(d / max(reach, 1)) / (.pi / 2)
        return CGPoint(x: dx / d * k, y: dy / d * k)
    }
}

private struct PointerAnchorView: NSViewRepresentable {
    let anchor: PointerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// Sits under avatars that live inside buttons, so it must never take the click.
private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

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
