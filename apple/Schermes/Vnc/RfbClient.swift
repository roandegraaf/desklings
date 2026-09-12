import CoreGraphics
import Foundation
import zlib

/// The byte pipe the client talks over. The daemon's proxy has no RFB parser — it forwards bytes
/// and nothing else — so a WebSocket message is not a frame boundary and this promises only that
/// bytes arrive in order. Swapped for a canned stream in tests.
nonisolated protocol RfbTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

nonisolated final class WebSocketTransport: RfbTransport {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): data
        case .string(let text): Data(text.utf8)
        @unknown default: throw RfbError.closed
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

nonisolated enum RfbError: LocalizedError {
    case handshake(String)
    case malformed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .handshake(let why): why
        case .malformed(let what): "the desktop sent something this client cannot read: \(what)"
        case .closed: "the connection closed"
        }
    }
}

nonisolated enum RfbEvent: Sendable {
    case frame(CGImage)
    case failed(String)
}

/// The three buttons, as their bit in an RFB button mask.
nonisolated enum PointerButton: UInt8, Sendable {
    case left = 0
    case middle = 1
    case right = 2
}

/// A wheel click is a button press and release, and there are four of them.
nonisolated enum WheelDirection: UInt8, Sendable {
    case up = 3
    case down = 4
    case left = 5
    case right = 6
}

/// RFB 3.8 against `ws://<daemon>/api/agents/<name>/vnc`.
///
/// An actor rather than anything on the main actor: this reads a socket, inflates and walks
/// millions of bytes per second, and only the finished `CGImage` has any business on the actor
/// that draws. `KeyEvent` (4) and `PointerEvent` (5) leave here only while `hold(true)` has been
/// called, because the daemon's proxy filters nothing and this gate is the whole of the promise.
/// `ClientCutText` (6) is still never written: the app has no clipboard bridge to feed it.
actor RfbClient {
    /// Frames and the one failure that ends the connection. Finishes when `run()` returns.
    nonisolated let events: AsyncStream<RfbEvent>

    private nonisolated let transport: RfbTransport
    private nonisolated let feed: AsyncStream<RfbEvent>.Continuation

    private var buffer: [UInt8] = []
    private var offset = 0
    private var framebuffer: Framebuffer?
    private var inflate: Inflate?
    private var drawnAt = ContinuousClock.now

    private var holds = false
    private var buttons: UInt8 = 0
    private var pressed: Set<UInt32> = []
    private var at = (x: 0, y: 0)

    init(transport: RfbTransport) {
        self.transport = transport
        (events, feed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    /// Runs until the socket dies or the task is cancelled. Leaving the desktop cancels the task
    /// that called this, which closes the socket from the cancellation handler, which is what
    /// unblocks the read this is parked on.
    func run() async {
        await withTaskCancellationHandler {
            do {
                try await converse()
            } catch {
                if !error.isCancellation && !Task.isCancelled {
                    feed.yield(.failed(error.localizedDescription))
                }
            }
            transport.close()
            feed.finish()
        } onCancel: {
            transport.close()
        }
    }

    private func converse() async throws {
        let size = try await handshake()
        guard let screen = Framebuffer(width: size.width, height: size.height) else {
            throw RfbError.malformed("a \(size.width)x\(size.height) screen")
        }
        framebuffer = screen
        inflate = try Inflate()

        try await write(pixelFormatMessage)
        try await write(encodingsMessage)
        try await requestUpdate(incremental: false)

        while !Task.isCancelled {
            switch try await u8() {
            case 0:
                try await readUpdate()
            case 1:
                // Never arrives while true colour is set, but a desynchronised stream is worse
                // than the three lines that step over it.
                _ = try await take(3)
                _ = try await u16()
                _ = try await take(try await u16() * 6)
            case 2:
                break // Bell.
            case 3:
                // ServerCutText: the desktop's clipboard, which a view-only client has no use for.
                _ = try await take(3)
                _ = try await take(try await u32())
            case let other:
                throw RfbError.malformed("server message \(other)")
            }
        }
    }

    // MARK: - Handshake

    private func handshake() async throws -> (width: Int, height: Int) {
        let greeting = try await take(12)
        guard greeting.starts(with: Array("RFB 003.".utf8)) else {
            throw RfbError.handshake("that is not a VNC server")
        }
        try await write(Data("RFB 003.008\n".utf8))

        let offered = try await u8()
        guard offered > 0 else { throw RfbError.handshake(try await failureReason()) }
        guard try await take(offered).contains(securityNone) else {
            throw RfbError.handshake("the desktop wants a password this app has no way to give")
        }
        try await write(Data([securityNone]))
        guard try await u32() == 0 else { throw RfbError.handshake(try await failureReason()) }

        // ClientInit, shared: another viewer already on this desktop must not be thrown off it.
        try await write(Data([1]))

        let width = try await u16()
        let height = try await u16()
        _ = try await take(16) // The server's own pixel format, replaced by SetPixelFormat below.
        _ = try await take(try await u32()) // The desktop name.
        return (width, height)
    }

    private func failureReason() async throws -> String {
        String(decoding: try await take(try await u32()), as: UTF8.self)
    }

    // MARK: - Updates

    private func readUpdate() async throws {
        _ = try await take(1)
        for _ in 0..<(try await u16()) {
            let x = try await u16()
            let y = try await u16()
            let w = try await u16()
            let h = try await u16()
            // Before the payload, not after: a rect is up to 65535 on a side and its bytes are
            // buffered whole, so a desynchronised stream must be caught on the header.
            guard framebuffer?.contains(x: x, y: y, w: w, h: h) == true else {
                throw RfbError.malformed("a \(w)x\(h) rect at \(x),\(y)")
            }
            switch try await u32() {
            case 0: try await readRaw(x: x, y: y, w: w, h: h)
            case 1: try await readCopyRect(x: x, y: y, w: w, h: h)
            case 16: try await readZrle(x: x, y: y, w: w, h: h)
            case let other: throw RfbError.malformed("encoding \(Int32(bitPattern: UInt32(other)))")
            }
        }
        await draw()
        try await requestUpdate(incremental: true)
    }

    private func readRaw(x: Int, y: Int, w: Int, h: Int) async throws {
        try blit(try await take(w * h * 4), x: x, y: y, w: w, h: h)
    }

    private func readCopyRect(x: Int, y: Int, w: Int, h: Int) async throws {
        let fromX = try await u16()
        let fromY = try await u16()
        guard framebuffer?.copy(fromX: fromX, fromY: fromY, toX: x, toY: y, w: w, h: h) == true
        else { throw RfbError.malformed("a copy from outside the screen") }
    }

    private func readZrle(x: Int, y: Int, w: Int, h: Int) async throws {
        // The rect already fits the screen, but its compressed length is its own word off the
        // wire. Uncompressed the tiles are three bytes a pixel plus a byte each, and deflate can
        // only pad that by a fraction of a percent, so four bytes a pixel is a generous ceiling.
        let length = try await u32()
        guard length <= w * h * 4 + 4096 else {
            throw RfbError.malformed("a \(length)-byte zrle rect of \(w)x\(h)")
        }
        let compressed = try await take(length)
        guard let inflate else { throw RfbError.malformed("zrle before the handshake finished") }
        try tiles(try inflate.run(compressed), x: x, y: y, w: w, h: h)
    }

    /// ZRLE: 64x64 tiles left to right, top to bottom, the ones at the edges clipped rather than
    /// padded. A CPIXEL is three bytes here — the requested format is 32 bits at depth 24 with
    /// every component in the low three, which is exactly the case RFB compresses — and those
    /// three bytes are already the B, G, R the framebuffer wants.
    private func tiles(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int) throws {
        var at = 0
        var tile = [UInt8](repeating: 0, count: tileSide * tileSide * 4)

        func byte() throws -> Int {
            guard at < data.count else { throw RfbError.malformed("a zrle tile ran off the end") }
            defer { at += 1 }
            return Int(data[at])
        }

        func cpixel() throws -> (UInt8, UInt8, UInt8) {
            guard at + 3 <= data.count else {
                throw RfbError.malformed("a zrle tile ran off the end")
            }
            defer { at += 3 }
            return (data[at], data[at + 1], data[at + 2])
        }

        func palette(_ size: Int) throws -> [UInt8] {
            guard at + size * 3 <= data.count else {
                throw RfbError.malformed("a zrle palette ran off the end")
            }
            var entries = [UInt8](repeating: 0, count: size * 4)
            for entry in 0..<size {
                entries[entry * 4] = data[at]
                entries[entry * 4 + 1] = data[at + 1]
                entries[entry * 4 + 2] = data[at + 2]
                at += 3
            }
            return entries
        }

        /// A run length is the sum of the 255s before the first smaller byte, plus that byte,
        /// plus one.
        func runLength() throws -> Int {
            var total = 1
            var next = try byte()
            while next == 255 {
                total += 255
                next = try byte()
            }
            return total + next
        }

        func paint(_ pixel: (UInt8, UInt8, UInt8), at index: Int, times: Int = 1) {
            for step in 0..<times {
                tile[(index + step) * 4] = pixel.0
                tile[(index + step) * 4 + 1] = pixel.1
                tile[(index + step) * 4 + 2] = pixel.2
            }
        }

        func entry(_ entries: [UInt8], _ number: Int) -> (UInt8, UInt8, UInt8) {
            (entries[number * 4], entries[number * 4 + 1], entries[number * 4 + 2])
        }

        for top in stride(from: 0, to: h, by: tileSide) {
            for left in stride(from: 0, to: w, by: tileSide) {
                let tw = min(tileSide, w - left)
                let th = min(tileSide, h - top)
                let pixels = tw * th

                switch try byte() {
                case 0:
                    for index in 0..<pixels { paint(try cpixel(), at: index) }

                case 1:
                    paint(try cpixel(), at: 0, times: pixels)

                case let packed where (2...16).contains(packed):
                    let entries = try palette(packed)
                    // Indices are packed most significant bits first, and every row of the tile
                    // starts on a byte boundary of its own.
                    let bits = packed == 2 ? 1 : (packed <= 4 ? 2 : 4)
                    let perByte = 8 / bits
                    var index = 0
                    for _ in 0..<th {
                        var current = 0
                        for column in 0..<tw {
                            if column % perByte == 0 { current = try byte() }
                            let shift = 8 - bits - (column % perByte) * bits
                            paint(entry(entries, (current >> shift) & ((1 << bits) - 1)), at: index)
                            index += 1
                        }
                    }

                case 128:
                    var index = 0
                    while index < pixels {
                        let pixel = try cpixel()
                        let run = try runLength()
                        guard index + run <= pixels else {
                            throw RfbError.malformed("a zrle run past the end of its tile")
                        }
                        paint(pixel, at: index, times: run)
                        index += run
                    }

                case let coded where (130...255).contains(coded):
                    let size = coded - 128
                    let entries = try palette(size)
                    var index = 0
                    while index < pixels {
                        let marked = try byte()
                        let number = marked & 0x7f
                        let run = marked & 0x80 == 0 ? 1 : try runLength()
                        guard number < size, index + run <= pixels else {
                            throw RfbError.malformed("a zrle run past the end of its tile")
                        }
                        paint(entry(entries, number), at: index, times: run)
                        index += run
                    }

                case let other:
                    throw RfbError.malformed("zrle subencoding \(other)")
                }

                try blit(tile, x: x + left, y: y + top, w: tw, h: th)
            }
        }
    }

    private func blit(_ source: [UInt8], x: Int, y: Int, w: Int, h: Int) throws {
        guard framebuffer?.write(x: x, y: y, w: w, h: h, from: source) == true else {
            throw RfbError.malformed("a \(w)x\(h) rect at \(x),\(y)")
        }
    }

    /// At most 60 a second, by waiting out the rest of the frame rather than dropping the update:
    /// the screen only changes when the server says it did, and a dropped last frame would leave
    /// the desktop showing something that is no longer there.
    private func draw() async {
        let since = ContinuousClock.now - drawnAt
        if since < frameInterval { try? await Task.sleep(for: frameInterval - since) }
        drawnAt = .now
        if let image = framebuffer?.image() { feed.yield(.frame(image)) }
    }

    // MARK: - Client messages

    /// The one way bytes leave this client. Everything above it writes freely; `input` is the only
    /// caller that has a gate in front of it, and `KeyEvent` and `PointerEvent` are the only
    /// messages that go through it.
    private func write(_ message: Data) async throws {
        do {
            try await transport.send(message)
        } catch {
            throw error.isCancellation ? error : RfbError.closed
        }
    }

    // MARK: - Input

    /// Taking the desktop, or giving it back. Returning it releases whatever is still down first,
    /// while the hold is still there to allow the writes: a button or a modifier left pressed
    /// outlives the viewer that pressed it, and only the agent would find out.
    func hold(_ wanted: Bool) async {
        guard wanted != holds else { return }
        if !wanted { await releaseEverything() }
        holds = wanted
    }

    func move(x: Int, y: Int) async {
        await pointer(x: x, y: y)
    }

    func button(_ button: PointerButton, down: Bool, x: Int, y: Int) async {
        let bit = UInt8(1) << button.rawValue
        buttons = down ? buttons | bit : buttons & ~bit
        await pointer(x: x, y: y)
    }

    /// Letting a button go without saying where. A release whose point fell outside the picture
    /// still has to happen, and the last place the pointer was is the honest answer.
    func release(_ button: PointerButton) async {
        await self.button(button, down: false, x: at.x, y: at.y)
    }

    /// A wheel click is a press and a release of a button that is never held, so it is one call.
    func wheel(_ direction: WheelDirection, x: Int, y: Int) async {
        let bit = UInt8(1) << direction.rawValue
        await pointer(x: x, y: y, mask: buttons | bit)
        await pointer(x: x, y: y)
    }

    func key(_ keysym: UInt32, down: Bool) async {
        if down { pressed.insert(keysym) } else { pressed.remove(keysym) }
        await input(keyMessage(keysym, down: down))
    }

    private func releaseEverything() async {
        if buttons != 0 {
            buttons = 0
            await pointer(x: at.x, y: at.y)
        }
        for keysym in pressed { await input(keyMessage(keysym, down: false)) }
        pressed.removeAll()
    }

    private func pointer(x: Int, y: Int, mask: UInt8? = nil) async {
        at = (x, y)
        var message = Data([5, mask ?? buttons])
        message.append(contentsOf: [UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)])
        message.append(contentsOf: [UInt8(truncatingIfNeeded: y >> 8), UInt8(truncatingIfNeeded: y)])
        await input(message)
    }

    private nonisolated func keyMessage(_ keysym: UInt32, down: Bool) -> Data {
        var message = Data([4, down ? 1 : 0, 0, 0])
        for shift in stride(from: 24, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: keysym >> UInt32(shift)))
        }
        return message
    }

    /// The one place an input message can leave this client. A dead socket is nothing a gesture
    /// callback can do anything about, so it is dropped rather than thrown back up a touch handler.
    private func input(_ message: Data) async {
        guard holds else { return }
        try? await write(message)
    }

    private func requestUpdate(incremental: Bool) async throws {
        guard let framebuffer else { return }
        var message = Data([3, incremental ? 1 : 0])
        for value in [0, 0, framebuffer.width, framebuffer.height] {
            message.append(UInt8(truncatingIfNeeded: value >> 8))
            message.append(UInt8(truncatingIfNeeded: value))
        }
        try await write(message)
    }

    // MARK: - Reading

    /// A WebSocket message carries whatever the proxy happened to read, so everything is parsed by
    /// length out of one buffer and never per message.
    private func take(_ count: Int) async throws -> [UInt8] {
        guard count >= 0 else { throw RfbError.malformed("a negative length") }
        while buffer.count - offset < count {
            let chunk = try await transport.receive()
            guard !chunk.isEmpty else { throw RfbError.closed }
            buffer.append(contentsOf: chunk)
        }
        let slice = Array(buffer[offset..<(offset + count)])
        offset += count
        // Compacting costs a copy of everything still unread, so it waits until most of the buffer
        // is spent rather than running on every read.
        if offset > 1 << 16, offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
        return slice
    }

    private func u8() async throws -> Int { Int(try await take(1)[0]) }

    private func u16() async throws -> Int {
        let bytes = try await take(2)
        return Int(bytes[0]) << 8 | Int(bytes[1])
    }

    private func u32() async throws -> Int {
        let bytes = try await take(4)
        return Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    }
}

// MARK: - Constants

private nonisolated let securityNone: UInt8 = 1
private nonisolated let tileSide = 64
private nonisolated let frameInterval = Duration.milliseconds(1000 / 60)

/// SetPixelFormat: 32 bits per pixel at depth 24, little-endian, true colour, red at 16, green at
/// 8, blue at 0. In memory that is B, G, R, ignored — the layout `Framebuffer` already holds.
private nonisolated let pixelFormatMessage = Data([
    0, 0, 0, 0,
    32, 24, 0, 1,
    0, 255, 0, 255, 0, 255,
    16, 8, 0,
    0, 0, 0,
])

/// SetEncodings, in preference order. ZRLE rather than Tight: TigerVNC serves both, but Tight
/// needs a JPEG decoder, four zlib streams and its filters, while ZRLE needs no image decoder at
/// all. No pseudo-encodings: Xvnc is started at a fixed geometry and changing it restarts the
/// server, which drops this socket anyway, so there is nothing for `DesktopSize` to report.
private nonisolated let encodingsMessage = Data([
    2, 0, 0, 3,
    0, 0, 0, 16,
    0, 0, 0, 1,
    0, 0, 0, 0,
])

// MARK: - zlib

/// One inflate stream for the life of the connection. ZRLE flushes at every rect but never ends
/// the stream and carries its dictionary across it, so this must not be reset between rects.
nonisolated final class Inflate {
    private var stream = z_stream()
    private var scratch = [UInt8](repeating: 0, count: 1 << 16)

    init() throws {
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RfbError.malformed("zlib would not start")
        }
    }

    deinit { inflateEnd(&stream) }

    func run(_ input: [UInt8]) throws -> [UInt8] {
        var input = input
        var output: [UInt8] = []
        var failure: RfbError?

        input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)

            while true {
                var produced = 0
                var status: Int32 = Z_OK
                scratch.withUnsafeMutableBufferPointer { room in
                    stream.next_out = room.baseAddress
                    stream.avail_out = uInt(room.count)
                    status = inflate(&stream, Z_SYNC_FLUSH)
                    produced = room.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else {
                    failure = .malformed("zlib failed with \(status)")
                    return
                }
                output.append(contentsOf: scratch[..<produced])
                // A call that did not fill the buffer has nothing left pending.
                if produced < scratch.count { return }
            }
        }

        if let failure { throw failure }
        return output
    }
}
