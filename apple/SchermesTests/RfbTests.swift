import CoreGraphics
import Foundation
import SwiftUI
import Synchronization
import Testing
import zlib
@testable import Schermes

/// The RFB client against canned byte streams: the handshake, a `Raw` rect, an overlapping
/// `CopyRect`, and every ZRLE subencoding the desktop can send — over one continuous zlib stream,
/// which is the part a per-rect reset would silently break.

// MARK: - A canned server

/// Hands out the stream in small fixed chunks, deliberately not aligned to anything RFB cares
/// about, because the daemon's proxy is a byte pipe and a WebSocket message is not a frame
/// boundary. Records every message the client writes back.
private nonisolated final class CannedServer: RfbTransport {
    private struct State {
        var pending: [Data]
        var written: [Data] = []
    }

    private let state: Mutex<State>

    init(_ stream: Data, chunk: Int = 7) {
        var pending: [Data] = []
        var at = stream.startIndex
        while at < stream.endIndex {
            let end = stream.index(at, offsetBy: chunk, limitedBy: stream.endIndex) ?? stream.endIndex
            pending.append(Data(stream[at..<end]))
            at = end
        }
        state = Mutex(State(pending: pending))
    }

    var written: [Data] { state.withLock { $0.written } }

    func send(_ data: Data) async throws {
        state.withLock { $0.written.append(data) }
    }

    func receive() async throws -> Data {
        try state.withLock {
            guard !$0.pending.isEmpty else { throw RfbError.closed }
            return $0.pending.removeFirst()
        }
    }

    func close() {}
}

/// The mirror of `Inflate`, so the ZRLE fixtures are real zlib rather than a blob nobody can read.
/// One stream flushed at every rect, exactly as a server produces it.
private nonisolated final class Deflate {
    private var stream = z_stream()
    private var scratch = [UInt8](repeating: 0, count: 1 << 16)

    init() {
        _ = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION,
                         Int32(MemoryLayout<z_stream>.size))
    }

    deinit { deflateEnd(&stream) }

    func run(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var output: [UInt8] = []
        input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            while true {
                var produced = 0
                scratch.withUnsafeMutableBufferPointer { room in
                    stream.next_out = room.baseAddress
                    stream.avail_out = uInt(room.count)
                    _ = deflate(&stream, Z_SYNC_FLUSH)
                    produced = room.count - Int(stream.avail_out)
                }
                output.append(contentsOf: scratch[..<produced])
                if produced < scratch.count { return }
            }
        }
        return output
    }
}

// MARK: - Fixtures

private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }

private func be32(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

/// Greeting, the one security type Xvnc is started with, and ServerInit.
private func greeting(width: Int, height: Int) -> Data {
    var data = Data("RFB 003.008\n".utf8)
    data.append(contentsOf: [1, 1])
    data.append(contentsOf: be32(0))
    data.append(contentsOf: be16(width) + be16(height))
    data.append(contentsOf: [UInt8](repeating: 0, count: 16))
    data.append(contentsOf: be32(4))
    data.append(Data("xvnc".utf8))
    return data
}

private func update(_ rects: [Data]) -> Data {
    var data = Data([0, 0])
    data.append(contentsOf: be16(rects.count))
    for rect in rects { data.append(rect) }
    return data
}

private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int, _ payload: [UInt8]) -> Data {
    var data = Data(be16(x) + be16(y) + be16(w) + be16(h) + be32(encoding))
    data.append(contentsOf: payload)
    return data
}

/// A pixel on the wire is 32-bit BGRX little-endian, which is the byte order the framebuffer holds.
private func wirePixel(_ blue: UInt8, _ green: UInt8, _ red: UInt8) -> [UInt8] {
    [blue, green, red, 0]
}

/// A `Raw` payload whose pixel `i` is blue `3i`, green `3i + 1`, red `3i + 2`, so every pixel in
/// it is distinguishable from every other and a swapped channel shows up as a wrong number.
private func gradient(_ count: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    for index in 0..<count {
        let start = UInt8(index * 3)
        bytes += wirePixel(start, start + 1, start + 2)
    }
    return bytes
}

/// The same gradient as CPIXELs, which drop the padding byte.
private func gradientPixels(_ count: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    for index in 0..<count {
        let start = UInt8(index * 3)
        bytes += [start, start + 1, start + 2]
    }
    return bytes
}

// MARK: - Running one

private struct Played {
    var frames: [CGImage]
    var written: [Data]
    var cuts: [String] = []
}

private func play(_ stream: Data, holding: Bool = false, chunk: Int = 7) async -> Played {
    let server = CannedServer(stream, chunk: chunk)
    let client = RfbClient(transport: server)
    if holding { await client.hold(true) }
    async let collected: [CGImage] = {
        var frames: [CGImage] = []
        for await event in client.events {
            if case .frame(let image) = event { frames.append(image) }
        }
        return frames
    }()
    async let cuts: [String] = {
        var cuts: [String] = []
        for await text in client.cuts { cuts.append(text) }
        return cuts
    }()
    await client.run()
    return Played(frames: await collected, written: server.written, cuts: await cuts)
}

/// Reads a pixel back out of the finished image as blue, green, red — the framebuffer's own order.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
    let at = y * image.bytesPerRow + x * 4
    return [bytes[at], bytes[at + 1], bytes[at + 2]]
}

// MARK: - Handshake and Raw

@Test func theHandshakeAgreesOnThreeEightAndAsksForTheFormatTheFramebufferAlreadyHolds() async throws {
    var stream = greeting(width: 4, height: 2)
    stream.append(update([rect(0, 0, 4, 2, 0, gradient(8))]))

    let played = await play(stream)

    #expect(played.written.count == 7)
    #expect(played.written[0] == Data("RFB 003.008\n".utf8))
    #expect(played.written[1] == Data([1])) // Security type None.
    #expect(played.written[2] == Data([1])) // ClientInit, shared.
    #expect(Array(played.written[3]) == [0, 0, 0, 0, 32, 24, 0, 1,
                                         0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    #expect(Array(played.written[4]) == [2, 0, 0, 3, 0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 0])
    #expect(Array(played.written[5]) == [3, 0, 0, 0, 0, 0, 0, 4, 0, 2]) // The full one, first.
    #expect(Array(played.written[6]) == [3, 1, 0, 0, 0, 0, 0, 4, 0, 2]) // Then incremental.
}

@Test func aRawRectLandsInTheFramebufferWithNoChannelReordered() async throws {
    var stream = greeting(width: 4, height: 2)
    stream.append(update([rect(0, 0, 4, 2, 0, gradient(8))]))

    let played = await play(stream)
    let screen = try #require(played.frames.last)

    #expect(screen.width == 4 && screen.height == 2)
    #expect(pixel(screen, 0, 0) == [0, 1, 2])
    #expect(pixel(screen, 3, 0) == [9, 10, 11])
    #expect(pixel(screen, 0, 1) == [12, 13, 14])
    #expect(pixel(screen, 3, 1) == [21, 22, 23])
}

@Test func aRectThatWouldRunOffTheScreenIsRefusedRatherThanWrittenPastTheEnd() async throws {
    var stream = greeting(width: 4, height: 2)
    stream.append(update([rect(2, 0, 4, 2, 0, [UInt8](repeating: 9, count: 4 * 2 * 4))]))

    let played = await play(stream)
    #expect(played.frames.isEmpty)
}

// MARK: - CopyRect

@Test func anOverlappingCopyRectMovesEveryRowIntactRatherThanSmearingIt() async throws {
    // Four distinct columns, then the leftmost three shifted one to the right over themselves:
    // the case a window dragged across the desktop produces, and the one a plain forward copy
    // would smear into a repeat of the first column.
    var stream = greeting(width: 4, height: 2)
    stream.append(update([rect(0, 0, 4, 2, 0, gradient(8))]))
    stream.append(update([rect(1, 0, 3, 2, 1, be16(0) + be16(0))]))

    let played = await play(stream)
    let screen = try #require(played.frames.last)

    #expect(pixel(screen, 0, 0) == [0, 1, 2])   // Untouched.
    #expect(pixel(screen, 1, 0) == [0, 1, 2])   // Was column 0.
    #expect(pixel(screen, 2, 0) == [3, 4, 5])   // Was column 1, not a repeat of column 0.
    #expect(pixel(screen, 3, 0) == [6, 7, 8])
    #expect(pixel(screen, 1, 1) == [12, 13, 14])
    #expect(pixel(screen, 3, 1) == [18, 19, 20])
}

@Test func aCopyDownwardsOverItselfWalksTheRowsFromTheBottom() async throws {
    var stream = greeting(width: 2, height: 4)
    stream.append(update([rect(0, 0, 2, 4, 0, gradient(8))]))
    stream.append(update([rect(0, 1, 2, 3, 1, be16(0) + be16(0))]))

    let played = await play(stream)
    let screen = try #require(played.frames.last)

    #expect(pixel(screen, 0, 1) == [0, 1, 2])    // Row 0 moved down one.
    #expect(pixel(screen, 0, 2) == [6, 7, 8])    // Row 1, not a repeat of row 0.
    #expect(pixel(screen, 0, 3) == [12, 13, 14]) // Row 2.
}

// MARK: - ZRLE

/// A 70-wide rect is two tiles: a full 64 and a clipped 6. Every subencoding the desktop can send
/// is exercised across three updates that share one zlib stream, so a client that reset the stream
/// per rect would fail from the second update on.
@Test func zrleDecodesEverySubencodingAcrossAClippedEdgeTileAndOneContinuousStream() async throws {
    let deflate = Deflate()

    // Two colours, one bit an index, rows padded to a byte: pixel 0 of row 0 and pixel 63 of
    // row 1 take entry 1, everything else entry 0.
    var packed: [UInt8] = [2, 10, 20, 30, 40, 50, 60]
    packed += [0x80, 0, 0, 0, 0, 0, 0, 0]
    packed += [0, 0, 0, 0, 0, 0, 0, 0x01]
    let rawTile: [UInt8] = [0] + gradientPixels(12)

    let solid: [UInt8] = [1, 200, 100, 50]
    let otherSolid: [UInt8] = [1, 90, 80, 70]
    // Seven of one colour then five of another, so a run crosses the row boundary of the tile.
    let plainRle: [UInt8] = [128, 7, 8, 9, 6, 11, 12, 13, 4]
    // The same shape through a two-entry palette, each run flagged by the high bit of its index.
    let paletteRle: [UInt8] = [130, 1, 2, 3, 4, 5, 6, 0x80, 6, 0x81, 4]

    // The full 64-wide tile first, the clipped 6-wide one second.
    var stream = greeting(width: 70, height: 2)
    for tiles in [packed + rawTile, solid + plainRle, otherSolid + paletteRle] {
        let compressed = deflate.run(tiles)
        stream.append(update([rect(0, 0, 70, 2, 16, be32(compressed.count) + compressed)]))
    }

    let played = await play(stream)
    #expect(played.frames.count == 3)

    let first = try #require(played.frames.first)
    #expect(pixel(first, 0, 0) == [40, 50, 60])   // Packed palette, entry 1.
    #expect(pixel(first, 1, 0) == [10, 20, 30])   // Entry 0.
    #expect(pixel(first, 0, 1) == [10, 20, 30])   // Each row starts on its own byte.
    #expect(pixel(first, 63, 1) == [40, 50, 60])  // The last bit of the last byte of row 1.
    #expect(pixel(first, 64, 0) == [0, 1, 2])     // The clipped tile, raw CPIXELs.
    #expect(pixel(first, 69, 1) == [33, 34, 35])

    let second = played.frames[1]
    #expect(pixel(second, 0, 0) == [200, 100, 50])  // Solid.
    #expect(pixel(second, 63, 1) == [200, 100, 50])
    #expect(pixel(second, 64, 0) == [7, 8, 9])      // Plain RLE, first run.
    #expect(pixel(second, 64, 1) == [7, 8, 9])      // The run crosses the row boundary.
    #expect(pixel(second, 65, 1) == [11, 12, 13])   // Second run.
    #expect(pixel(second, 69, 1) == [11, 12, 13])

    let third = try #require(played.frames.last)
    #expect(pixel(third, 0, 0) == [90, 80, 70])   // A second solid, over the first.
    #expect(pixel(third, 64, 0) == [1, 2, 3])     // Palette RLE, entry 0, run of seven.
    #expect(pixel(third, 64, 1) == [1, 2, 3])     // Still inside that run, a row down.
    #expect(pixel(third, 65, 1) == [4, 5, 6])     // Entry 1, run of five.
    #expect(pixel(third, 69, 1) == [4, 5, 6])
}

// MARK: - The gate

@Test func aViewerThatWasNeverGivenTheDesktopWritesNoPointerOrKeyOrClipboardMessage() async throws {
    let deflate = Deflate()
    let compressed = deflate.run([1, 5, 6, 7] + [1, 5, 6, 7])

    var stream = greeting(width: 70, height: 2)
    stream.append(update([rect(0, 0, 4, 2, 0, [UInt8](repeating: 0, count: 4 * 2 * 4))]))
    stream.append(update([rect(0, 0, 4, 2, 1, be16(4) + be16(0))]))
    stream.append(update([rect(0, 0, 70, 2, 16, be32(compressed.count) + compressed)]))
    stream.append(Data([2]))                                     // Bell.
    stream.append(Data([3, 0, 0, 0] + be32(2) + Array("hi".utf8))) // ServerCutText.

    let played = await play(stream)
    #expect(played.cuts.isEmpty) // The desktop's clipboard is not surfaced to a watcher.

    // The handshake writes three raw replies of its own; after those, every message a client with
    // no hold is allowed to send is SetPixelFormat, SetEncodings or FramebufferUpdateRequest.
    // The proxy filters nothing, so this side is the only thing keeping the desktop read-only.
    #expect(played.written.count > 3)
    for message in played.written.dropFirst(3) {
        #expect([0, 2, 3].contains(message[message.startIndex]))
    }
    #expect(!played.written.dropFirst(3).contains { [4, 5, 6].contains($0[$0.startIndex]) })
}

/// The gate does not depend on the handshake, so these need no stream at all: a client that was
/// handed one and never given the desktop must put nothing on it.
@Test func inputIsRefusedUntilTheDaemonSaysThisViewerHoldsTheDesktop() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)

    await client.move(x: 10, y: 20)
    await client.button(.left, down: true, x: 10, y: 20)
    await client.wheel(.up, x: 10, y: 20)
    await client.key(0x41, down: true)
    await client.release(.left)

    #expect(server.written.isEmpty)
}

@Test func holdingTheDesktopIsWhatPutsPointerAndKeyBytesOnTheWire() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)
    await client.hold(true)

    await client.move(x: 0x0102, y: 0x0304)
    await client.button(.right, down: true, x: 1, y: 2)
    await client.wheel(.up, x: 1, y: 2)
    await client.key(Keysym.enter, down: true)

    #expect(server.written.count == 5)
    #expect(Array(server.written[0]) == [5, 0b000, 0x01, 0x02, 0x03, 0x04])
    #expect(Array(server.written[1]) == [5, 0b100, 0, 1, 0, 2]) // Right is bit 2, and stays down.
    #expect(Array(server.written[2]) == [5, 0b1100, 0, 1, 0, 2]) // A wheel click, over that button.
    #expect(Array(server.written[3]) == [5, 0b100, 0, 1, 0, 2]) // And released again on its own.
    #expect(Array(server.written[4]) == [4, 1, 0, 0, 0, 0, 0xff, 0x0d])
}

/// A drag that ends on the letterbox bar has no framebuffer point to name, so the view asks for a
/// release without one. It still has to happen, or the button stays down on the agent's desktop.
@Test func aButtonCanBeLetGoWithoutSayingWhereAndLandsWhereItWasLastSeen() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)

    await client.hold(true)
    await client.button(.left, down: true, x: 300, y: 200)
    await client.move(x: 301, y: 205)
    await client.release(.left)

    #expect(server.written.count == 3)
    #expect(Array(server.written[1]) == [5, 0b1, 1, 0x2d, 0, 205]) // Still dragging.
    #expect(Array(server.written[2]) == [5, 0, 1, 0x2d, 0, 205])   // Let go, where it last was.
}

@Test func returningTheDesktopReleasesWhatIsStillDownBeforeTheGateCloses() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)

    await client.hold(true)
    await client.button(.left, down: true, x: 7, y: 9)
    await client.key(Keysym.control, down: true)
    await client.hold(false)

    // Anything after the hold is gone writes nothing at all.
    await client.move(x: 1, y: 1)
    await client.key(Keysym.control, down: false)

    #expect(server.written.count == 4)
    #expect(Array(server.written[0]) == [5, 0b1, 0, 7, 0, 9])
    #expect(Array(server.written[1]) == [4, 1, 0, 0, 0, 0, 0xff, 0xe3])
    // The button let go where it was last seen, and the modifier let go after it.
    #expect(Array(server.written[2]) == [5, 0, 0, 7, 0, 9])
    #expect(Array(server.written[3]) == [4, 0, 0, 0, 0, 0, 0xff, 0xe3])
}

// MARK: - Clipboard

private func serverCutText(_ bytes: [UInt8]) -> Data {
    Data([3, 0, 0, 0] + be32(bytes.count) + bytes)
}

@Test func theDesktopsClipboardReachesAViewerThatHoldsItAsLatin1() async throws {
    var stream = greeting(width: 4, height: 2)
    stream.append(serverCutText([0x63, 0x61, 0x66, 0xe9, 0x0a, 0x21])) // "café\n!" in Latin-1.
    stream.append(update([rect(0, 0, 4, 2, 0, gradient(8))]))

    let played = await play(stream, holding: true)

    #expect(played.cuts == ["café\n!"])
    #expect(played.frames.count == 1) // Still in step after it.
}

@Test func anAbsurdlyLongCutTextIsSteppedOverWithoutLosingTheStream() async throws {
    var stream = greeting(width: 4, height: 2)
    stream.append(Data([3, 0, 0, 0] + be32(maxCutText + 1)))
    stream.append(Data(repeating: 0x41, count: maxCutText + 1))
    stream.append(update([rect(0, 0, 4, 2, 0, gradient(8))]))

    let played = await play(stream, holding: true, chunk: 4096)

    #expect(played.cuts.isEmpty)
    let screen = try #require(played.frames.last)
    #expect(pixel(screen, 3, 1) == [21, 22, 23])
}

@Test func aLengthNoDesktopCouldSendIsDroppedRatherThanAllocated() async throws {
    // Four gigabytes announced and a stream that ends: the client reads until the socket closes and
    // never tries to hold the whole of it.
    var stream = greeting(width: 4, height: 2)
    stream.append(Data([3, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]))
    stream.append(Data(repeating: 0, count: 64))

    let played = await play(stream, holding: true)
    #expect(played.cuts.isEmpty)
}

@Test func pastingSendsTheOwnersClipboardThenControlV() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)
    await client.hold(true)

    await client.paste("hé\r\nyo")

    #expect(server.written.count == 5)
    #expect(Array(server.written[0]) == [6, 0, 0, 0] + be32(5) + [0x68, 0xe9, 0x0a, 0x79, 0x6f])
    #expect(Array(server.written[1]) == [4, 1, 0, 0, 0, 0, 0xff, 0xe3]) // Control down.
    #expect(Array(server.written[2]) == [4, 1, 0, 0, 0, 0, 0, 0x76])    // v down.
    #expect(Array(server.written[3]) == [4, 0, 0, 0, 0, 0, 0, 0x76])    // v up.
    #expect(Array(server.written[4]) == [4, 0, 0, 0, 0, 0, 0xff, 0xe3]) // Control up.
}

@Test func aPasteOrShortcutWithoutTheDesktopWritesNothing() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)

    await client.paste("secret")
    await client.shortcut(0x63)

    #expect(server.written.isEmpty)
}

@Test func aPasteTooLongToCarryIsNotPastedAtAll() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)
    await client.hold(true)

    let long = String(repeating: "a", count: maxCutText + 1)
    #expect(!RfbClient.canCarry(long))
    #expect(RfbClient.canCarry(String(repeating: "a", count: maxCutText)))
    await client.paste(long)

    // No Control+V either: the agent would paste its own clipboard instead.
    #expect(server.written.isEmpty)
}

@Test func aCommandShortcutGoesAsAControlChord() async throws {
    let server = CannedServer(Data())
    let client = RfbClient(transport: server)
    await client.hold(true)

    await client.shortcut(try #require(Keysym.controlShortcut("c", shift: false)))

    #expect(server.written.map(Array.init) == [
        [4, 1, 0, 0, 0, 0, 0xff, 0xe3],
        [4, 1, 0, 0, 0, 0, 0, 0x63],
        [4, 0, 0, 0, 0, 0, 0, 0x63],
        [4, 0, 0, 0, 0, 0, 0xff, 0xe3],
    ])
}

@Test func onlyTheEditingCommandChordsBecomeControl() {
    #expect(Keysym.controlShortcut("c", shift: false) == 0x63)
    #expect(Keysym.controlShortcut("v", shift: false) == 0x76)
    #expect(Keysym.controlShortcut("x", shift: false) == 0x78)
    #expect(Keysym.controlShortcut("a", shift: false) == 0x61)
    #expect(Keysym.controlShortcut("z", shift: false) == 0x7a)
    // Redo: the capital, since Xvnc fits Shift to the keysym and a small z would lift it.
    #expect(Keysym.controlShortcut("Z", shift: true) == 0x5a)
    #expect(Keysym.controlShortcut("z", shift: true) == 0x5a)
    #expect(Keysym.controlShortcut("V", shift: false) == 0x76)
    for other: Character in ["q", "w", "t", ",", "`", "1"] {
        #expect(Keysym.controlShortcut(other, shift: false) == nil)
    }
    #expect(Keysym.isPaste(0x76) && Keysym.isPaste(0x56) && !Keysym.isPaste(0x63))
}

@Test func textLatin1CannotCarryIsReplacedNotCrashedOn() {
    #expect(latin1Bytes("é") == [0xe9])
    #expect(latin1Bytes("e\u{301}") == [0xe9])          // A combining accent, composed first.
    #expect(latin1Bytes("5 €") == [0x35, 0x20, 0x3f])
    #expect(latin1Bytes("a👨‍👩‍👧b") == [0x61, 0x3f, 0x62]) // One mark for the whole emoji.
    #expect(latin1Bytes("1\r\n2\r3\n") == [0x31, 0x0a, 0x32, 0x0a, 0x33, 0x0a])
    #expect(latin1Text([0x63, 0xe9, 0xff]) == "cé\u{ff}")
}

private final class FakeClipboard: Clipboard {
    var text: String?
    var written: [String] = []
    init(_ text: String?) { self.text = text }
    func put(_ text: String) { written.append(text) }
}

@Test func aPasteTheDesktopCannotCarrySaysSoAndOneItCanSaysNothing() {
    let long = DesktopLink(clipboard: FakeClipboard(String(repeating: "a", count: maxCutText + 1)))
    #expect(long.pasteClipboard()?.contains("256 KB") == true)

    #expect(DesktopLink(clipboard: FakeClipboard("hello")).pasteClipboard() == nil)
    #expect(DesktopLink(clipboard: FakeClipboard(nil)).pasteClipboard() == nil) // A bare Ctrl+V.
}

#if os(macOS)

/// Through the hosting view the way AppKit asks, so a SwiftUI layer that stopped forwarding key
/// equivalents to the input view would show up here and not only on a real desktop. Never ordered
/// front: a direct call, no posted event, no focus taken.
@Test func commandChordsReachTheDesktopAsControlAndTheMenuKeepsTheRest() throws {
    var sent: [DesktopInputEvent] = []
    let host = NSHostingView(rootView: DesktopInput { sent.append($0) })
    host.sizingOptions = []
    host.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
    let container = NSView(frame: host.frame)
    container.addSubview(host)
    let window = NSWindow(
        contentRect: CGRect(x: -30000, y: -30000, width: 200, height: 120),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { window.close() }
    host.layoutSubtreeIfNeeded()

    func find(_ view: NSView) -> DesktopInputNSView? {
        if let input = view as? DesktopInputNSView { return input }
        return view.subviews.lazy.compactMap(find).first
    }
    let input = try #require(find(container))
    #expect(window.makeFirstResponder(input))

    func chord(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        return container.performKeyEquivalent(with: event)
    }

    #expect(chord("c", .command, keyCode: 8))
    #expect(chord("Z", [.command, .shift], keyCode: 6))
    #expect(!chord("q", .command, keyCode: 12))
    #expect(!chord("c", [.command, .control], keyCode: 8))

    let shortcuts = sent.compactMap { event -> UInt32? in
        if case .shortcut(let keysym) = event { keysym } else { nil }
    }
    #expect(shortcuts == [0x63, 0x5a])
    #expect(sent.count == 2)
}

/// Each move to a window used to add one more resign-key observer and never drop the last, so the
/// window the view had left could still let go of keys held in the one it was in.
@Test func onlyTheInputViewsCurrentWindowLetsGoOfItsKeys() throws {
    func offscreen() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
    let first = offscreen()
    let second = offscreen()
    defer { first.close(); second.close() }

    var sent: [DesktopInputEvent] = []
    let input = DesktopInputNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
    input.send = { sent.append($0) }
    first.contentView?.addSubview(input)
    input.removeFromSuperview()
    second.contentView?.addSubview(input)

    let press = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: second.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
    ))
    input.keyDown(with: press)
    func released() -> Bool {
        sent.contains { if case .key(_, down: false) = $0 { true } else { false } }
    }

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
    #expect(!released())
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
    #expect(released())
}

#endif
