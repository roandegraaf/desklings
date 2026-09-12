import CoreGraphics
import Foundation

/// One agent's screen as a single bitmap that rects are written straight into.
///
/// `byteOrder32Little` with `noneSkipFirst` lays a pixel out in memory as B, G, R, ignored — which
/// is exactly the 32-bit BGRX the client asks the server for, and exactly the three bytes a ZRLE
/// CPIXEL carries. So a `Raw` rect is a row-by-row `memcpy` and no channel is ever reordered.
///
/// Nonisolated: the client decodes off the main actor and only the finished `CGImage` crosses back.
nonisolated final class Framebuffer {
    let width: Int
    let height: Int

    private let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    private let stride: Int

    /// Xvnc is started at a geometry this app does not choose, so the size arrives over the wire
    /// and is checked here rather than trusted.
    init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let stride = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ), let data = context.data else { return nil }

        self.width = width
        self.height = height
        self.context = context
        self.stride = stride
        self.pixels = data.bindMemory(to: UInt8.self, capacity: height * stride)
    }

    /// Whether a rect off the wire lands entirely on the screen. Asked before a rect's payload is
    /// read, not after: a desynchronised stream can name a rect near the full 16-bit range, and
    /// buffering that many bytes to find out it was nonsense is the whole cost of the mistake.
    func contains(x: Int, y: Int, w: Int, h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    /// `source` holds `w * h` pixels, rows packed at `w * 4` bytes with no padding.
    func write(x: Int, y: Int, w: Int, h: Int, from source: [UInt8]) -> Bool {
        guard contains(x: x, y: y, w: w, h: h), source.count >= w * h * 4 else { return false }
        source.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            for row in 0..<h {
                memcpy(pixels + (y + row) * stride + x * 4, base + row * w * 4, w * 4)
            }
        }
        return true
    }

    /// A window dragged across the desktop arrives as a `CopyRect` whose source and destination
    /// overlap, so the rows are walked away from the destination and each row moved with `memmove`.
    func copy(fromX: Int, fromY: Int, toX: Int, toY: Int, w: Int, h: Int) -> Bool {
        guard contains(x: fromX, y: fromY, w: w, h: h), contains(x: toX, y: toY, w: w, h: h)
        else { return false }
        let rows = toY > fromY ? Array((0..<h).reversed()) : Array(0..<h)
        for row in rows {
            memmove(
                pixels + (toY + row) * stride + toX * 4,
                pixels + (fromY + row) * stride + fromX * 4,
                w * 4
            )
        }
        return true
    }

    func image() -> CGImage? {
        context.makeImage()
    }
}

/// Where a point in the view lands on the screen above. The picture is scaled to fit and centred
/// in its box, so the bars either side of it are not the desktop and a press on one is not a press
/// on it — which is why this answers with nothing rather than with the nearest edge.
nonisolated func framebufferPoint(
    _ point: CGPoint,
    view: CGSize,
    screen: CGSize
) -> (x: Int, y: Int)? {
    guard view.width > 0, view.height > 0, screen.width > 0, screen.height > 0 else { return nil }
    let scale = min(view.width / screen.width, view.height / screen.height)
    let drawn = CGSize(width: screen.width * scale, height: screen.height * scale)
    let inside = CGPoint(
        x: point.x - (view.width - drawn.width) / 2,
        y: point.y - (view.height - drawn.height) / 2
    )
    guard inside.x >= 0, inside.y >= 0, inside.x < drawn.width, inside.y < drawn.height else {
        return nil
    }
    // The last row and column are a whole pixel each, so a point on the far edge of one still
    // rounds into it rather than one past the end of the screen.
    return (
        min(Int(inside.x / scale), Int(screen.width) - 1),
        min(Int(inside.y / scale), Int(screen.height) - 1)
    )
}
