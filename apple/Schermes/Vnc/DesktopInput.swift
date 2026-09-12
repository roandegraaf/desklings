import SwiftUI

/// What a hand did, in the coordinates of the view it did it in. `DesktopView` maps the point back
/// through the letterbox before any of it reaches the client.
nonisolated enum DesktopInputEvent: Sendable {
    case move(CGPoint)
    case button(PointerButton, down: Bool, at: CGPoint)
    case wheel(WheelDirection, at: CGPoint)
    case key(UInt32, down: Bool)
}

private nonisolated let wheelStep: CGFloat = 16
private nonisolated let tapSlack: CGFloat = 12
private nonisolated let tapTime: TimeInterval = 0.4

#if os(macOS)

/// The one AppKit shim the task allows itself. SwiftUI has no primitive for the right button, the
/// middle button, the wheel, a hovering pointer or a bare key press reaching a plain view, and a
/// desktop without any of those is not a desktop.
struct DesktopInput: NSViewRepresentable {
    let send: @MainActor (DesktopInputEvent) -> Void

    func makeNSView(context: Context) -> DesktopInputNSView {
        let view = DesktopInputNSView()
        view.send = send
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: DesktopInputNSView, context: Context) {
        view.send = send
    }
}

final class DesktopInputNSView: NSView {
    var send: @MainActor (DesktopInputEvent) -> Void = { _ in }

    private var tracking: NSTrackingArea?
    private var modifiers: NSEvent.ModifierFlags = []
    private var downKeys: [UInt16: UInt32] = [:]
    private var scrolled = CGSize.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        guard let window else { return }
        // Cmd-tabbing away leaves the desktop holding whatever was down, and nothing else would
        // ever tell it otherwise: a stuck Command on an agent's screen outlives the window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(letGo),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func at(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) { send(.button(.left, down: true, at: at(event))) }
    override func mouseUp(with event: NSEvent) { send(.button(.left, down: false, at: at(event))) }
    override func rightMouseDown(with event: NSEvent) { send(.button(.right, down: true, at: at(event))) }
    override func rightMouseUp(with event: NSEvent) { send(.button(.right, down: false, at: at(event))) }
    override func otherMouseDown(with event: NSEvent) { send(.button(.middle, down: true, at: at(event))) }
    override func otherMouseUp(with event: NSEvent) { send(.button(.middle, down: false, at: at(event))) }

    override func mouseMoved(with event: NSEvent) { send(.move(at(event))) }
    override func mouseDragged(with event: NSEvent) { send(.move(at(event))) }
    override func rightMouseDragged(with event: NSEvent) { send(.move(at(event))) }
    override func otherMouseDragged(with event: NSEvent) { send(.move(at(event))) }

    /// A wheel click is discrete and a trackpad is not, so the continuous deltas are accumulated
    /// and spent a click at a time. A line-scrolling mouse reports ±1 per notch, which is scaled up
    /// to the same units rather than given a second code path.
    override func scrollWheel(with event: NSEvent) {
        let point = at(event)
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : wheelStep
        scrolled.height += event.scrollingDeltaY * factor
        scrolled.width += event.scrollingDeltaX * factor

        while abs(scrolled.height) >= wheelStep {
            let up = scrolled.height > 0
            scrolled.height -= up ? wheelStep : -wheelStep
            send(.wheel(up ? .up : .down, at: point))
        }
        while abs(scrolled.width) >= wheelStep {
            let left = scrolled.width > 0
            scrolled.width -= left ? wheelStep : -wheelStep
            send(.wheel(left ? .left : .right, at: point))
        }
    }

    // MARK: - Keyboard

    /// `charactersIgnoringModifiers`, never `characters`: Ctrl+C reports `characters` as U+0003,
    /// which would be sent as keysym 3. Shift is still honoured by the former, so a capital arrives
    /// as a capital alongside the Shift press `flagsChanged` sends.
    private func keysym(of event: NSEvent) -> UInt32? {
        event.charactersIgnoringModifiers?.first.flatMap(Keysym.of)
    }

    override func keyDown(with event: NSEvent) {
        guard let keysym = keysym(of: event) else { return }
        // AppKit delivers no `keyUp` for a key pressed while Command is down, so a Command chord is
        // sent as a tap rather than left waiting on a release that is never reported.
        guard !event.modifierFlags.contains(.command) else {
            send(.key(keysym, down: true))
            send(.key(keysym, down: false))
            return
        }
        downKeys[event.keyCode] = keysym
        send(.key(keysym, down: true))
    }

    override func keyUp(with event: NSEvent) {
        // By keycode, not by character: a modifier released mid-press would otherwise change what
        // the key is and leave the one actually pressed held down on the desktop.
        guard let keysym = downKeys.removeValue(forKey: event.keyCode) else { return }
        send(.key(keysym, down: false))
    }

    override func flagsChanged(with event: NSEvent) {
        let now = event.modifierFlags
        for (flag, keysym) in modifierKeysyms where modifiers.contains(flag) != now.contains(flag) {
            send(.key(keysym, down: now.contains(flag)))
        }
        modifiers = now
    }

    override func resignFirstResponder() -> Bool {
        letGo()
        return super.resignFirstResponder()
    }

    @objc private func letGo() {
        for keysym in downKeys.values { send(.key(keysym, down: false)) }
        downKeys.removeAll()
        for (flag, keysym) in modifierKeysyms where modifiers.contains(flag) {
            send(.key(keysym, down: false))
        }
        modifiers = []
    }
}

private nonisolated let modifierKeysyms: [(NSEvent.ModifierFlags, UInt32)] = [
    (.shift, Keysym.shift),
    (.control, Keysym.control),
    (.option, Keysym.alt),
    (.command, Keysym.meta),
]

#else

/// The iOS half. One finger is the left button, two fingers scroll, and a two-finger tap is the
/// right button — the trackpad conventions, because a touch has no other way to say which button
/// it meant. The middle button has no gesture here and is macOS only.
///
/// Also the keyboard: `UIKeyInput` is what raises the software one, and `pressesBegan` is what a
/// hardware keyboard's arrows, escape and chords arrive through.
struct DesktopInput: UIViewRepresentable {
    let send: @MainActor (DesktopInputEvent) -> Void
    var typing: Bool

    func makeUIView(context: Context) -> DesktopInputUIView {
        let view = DesktopInputUIView()
        view.send = send
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: DesktopInputUIView, context: Context) {
        view.send = send
        if typing, !view.isFirstResponder { view.becomeFirstResponder() }
        if !typing, view.isFirstResponder { view.resignFirstResponder() }
    }
}

final class DesktopInputUIView: UIView, UIKeyInput {
    var send: @MainActor (DesktopInputEvent) -> Void = { _ in }

    private var scrolling = false
    private var lastTouch = CGPoint.zero
    private var scrolled: CGFloat = 0
    private var began: (point: CGPoint, at: Date)?
    private var travelled: CGFloat = 0

    // MARK: - Pointer

    /// Everything still on the glass, this event's new touches included — `touches` alone is only
    /// what changed, so a second finger landing would otherwise look like the only one there.
    private func live(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        }
    }

    private func middle(_ touches: [UITouch]) -> CGPoint {
        guard !touches.isEmpty else { return lastTouch }
        let total = touches.reduce(CGPoint.zero) {
            let point = $1.location(in: self)
            return CGPoint(x: $0.x + point.x, y: $0.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(touches.count), y: total.y / CGFloat(touches.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = live(event)
        let point = middle(active)
        if active.count >= 2 {
            if !scrolling {
                // A second finger ends whatever the first was dragging, rather than leaving the
                // button down for the length of the scroll.
                send(.button(.left, down: false, at: lastTouch))
                scrolling = true
                scrolled = 0
                travelled = 0
                began = (point, Date())
            }
        } else {
            send(.button(.left, down: true, at: point))
        }
        lastTouch = point
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = middle(live(event))
        if scrolling {
            let step = point.y - lastTouch.y
            scrolled += step
            travelled += abs(step) + abs(point.x - lastTouch.x)
            while abs(scrolled) >= wheelStep {
                // Fingers moving down drag the content down, which is the wheel turning up.
                let up = scrolled > 0
                scrolled -= up ? wheelStep : -wheelStep
                send(.wheel(up ? .up : .down, at: point))
            }
        } else {
            send(.move(point))
        }
        lastTouch = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard scrolling else {
            send(.button(.left, down: false, at: touches.first?.location(in: self) ?? lastTouch))
            return
        }
        guard live(event).isEmpty else { return }
        scrolling = false
        if let began, travelled < tapSlack, Date().timeIntervalSince(began.at) < tapTime {
            send(.button(.right, down: true, at: began.point))
            send(.button(.right, down: false, at: began.point))
        }
        began = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !scrolling { send(.button(.left, down: false, at: lastTouch)) }
        scrolling = false
        began = nil
    }

    // MARK: - Keyboard

    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { false }

    func insertText(_ text: String) {
        for character in text {
            if let keysym = Keysym.of(character) { tap(keysym) }
        }
    }

    func deleteBackward() { tap(Keysym.backSpace) }

    private func tap(_ keysym: UInt32) {
        send(.key(keysym, down: true))
        send(.key(keysym, down: false))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let left = presses.filter { !handle($0) }
        if !left.isEmpty { super.pressesBegan(left, with: event) }
    }

    /// Whether this press has been sent. A bare modifier says nothing on its own, because UIKit
    /// reports the modifiers of the key they modify and the chord is built from those. A plain
    /// character is left to the text input system so it cannot be typed twice.
    private func handle(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        let usage = key.keyCode.rawValue
        guard !Keysym.isModifier(usage) else { return true }

        let chorded = !key.modifierFlags.intersection([.control, .alternate, .command]).isEmpty
        let typed = chorded ? key.charactersIgnoringModifiers.first.flatMap(Keysym.of) : nil
        guard let keysym = Keysym.hid(usage) ?? typed else { return false }

        chord(key.modifierFlags) { tap(keysym) }
        return true
    }

    private func chord(_ flags: UIKeyModifierFlags, _ press: () -> Void) {
        let held: [UInt32] = [
            flags.contains(.shift) ? Keysym.shift : nil,
            flags.contains(.control) ? Keysym.control : nil,
            flags.contains(.alternate) ? Keysym.alt : nil,
            flags.contains(.command) ? Keysym.meta : nil,
        ].compactMap { $0 }
        for keysym in held { send(.key(keysym, down: true)) }
        press()
        for keysym in held.reversed() { send(.key(keysym, down: false)) }
    }
}

#endif
