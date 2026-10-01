import QuickLook
import SwiftUI

/// Something arrived in this thread that the owner has not looked at.
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(.tint)
            .frame(width: 9, height: 9)
            .accessibilityLabel("unread")
    }
}

/// A screenshot arrives as base64 PNG and the two platforms disagree about what an image is.
struct ScreenshotView: View {
    let image: Base64Image
    var fit = CGSize(width: 240, height: 180)

    @State private var previewing: URL?
    @State private var decoded: Decoded?
    @State private var unreadable = false
    @Environment(\.displayScale) private var displayScale
    #if os(iOS)
    @State private var saving: URL?
    #endif

    private var maxPixels: Int { Int((max(fit.width, fit.height) * displayScale).rounded(.up)) }

    private func frame(_ size: CGSize) -> CGSize {
        let scale = min(fit.width / size.width, fit.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        if let hit = decoded ?? Self.cached(image, maxPixels: maxPixels) {
            let frame = frame(hit.size)
            Button { previewing = try? imageFile(image) } label: {
                Image(decorative: hit.image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Image")
            .accessibilityHint("Opens a preview")
            .contextMenu {
                Button("Quick Look", systemImage: "eye") { previewing = try? imageFile(image) }
                Button("Copy Image", systemImage: "doc.on.doc") {
                    if let file = try? imageFile(image) { copyImageToPasteboard(at: file) }
                }
                Button(SAVE_LABEL, systemImage: "square.and.arrow.down") { save() }
            }
            .quickLookPreview($previewing)
            #if os(iOS)
            .fileMover(
                isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
                file: saving
            ) { _ in }
            #endif
        } else if unreadable {
            Label("screenshot could not be read", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let size = imageSize(image) {
            // The picture's own frame from the header, so the row does not change height under
            // the reader when the pixels land; decoding them is what would stall the scroll.
            let frame = frame(size)
            RoundedRectangle(cornerRadius: 12)
                .fill(.fill.tertiary)
                .frame(width: frame.width, height: frame.height)
                .task {
                    let image = image, maxPixels = maxPixels
                    let fresh = await Task.detached(priority: .userInitiated) {
                        imageThumbnail(image, maxPixels: maxPixels)
                    }.value
                    guard let fresh else { unreadable = true; return }
                    decoded = Self.remember(image, Decoded(image: fresh.image, size: fresh.size))
                }
        } else {
            Label("screenshot could not be read", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let file = try? imageFile(image) else { return }
        #if os(macOS)
        if let kept = try? moveToDownloads(file) { NSWorkspace.shared.activateFileViewerSelecting([kept]) }
        #else
        saving = file
        #endif
    }

    private static let decoded = NSCache<NSString, Decoded>()

    private final class Decoded {
        let image: CGImage
        let size: CGSize
        init(image: CGImage, size: CGSize) {
            self.image = image
            self.size = size
        }
    }

    private static func cached(_ image: Base64Image, maxPixels: Int) -> Decoded? {
        guard let hit = decoded.object(forKey: image.base64 as NSString),
              max(hit.image.width, hit.image.height) >= min(maxPixels, Int(max(hit.size.width, hit.size.height)))
        else { return nil }
        return hit
    }

    private static func remember(_ image: Base64Image, _ fresh: Decoded) -> Decoded {
        decoded.setObject(fresh, forKey: image.base64 as NSString)
        return fresh
    }
}
