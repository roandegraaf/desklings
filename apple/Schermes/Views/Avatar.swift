import QuickLook
import SwiftUI

extension AgentState {
    var tint: Color {
        switch self {
        case .failed: .red
        case .thinking, .using_computer, .using_terminal: .orange
        case .waiting_for_agent, .waiting_for_task_worker: .blue
        case .completed: .secondary
        case .idle, .waiting_for_user: .green
        }
    }
}

struct StateDot: View {
    let state: AgentState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state.label)
    }
}

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
    @Environment(\.displayScale) private var displayScale
    #if os(iOS)
    @State private var saving: URL?
    #endif

    var body: some View {
        if let (decoded, size) = Self.load(image, maxPixels: Int((max(fit.width, fit.height) * displayScale).rounded(.up))) {
            let scale = min(fit.width / size.width, fit.height / size.height, 1)
            Button { previewing = try? imageFile(image) } label: {
                decoded
                    .resizable()
                    .frame(width: size.width * scale, height: size.height * scale)
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

    private static func load(_ image: Base64Image, maxPixels: Int) -> (Image, CGSize)? {
        let key = image.base64 as NSString
        if let hit = decoded.object(forKey: key),
           max(hit.image.width, hit.image.height) >= min(maxPixels, Int(max(hit.size.width, hit.size.height))) {
            return (Image(decorative: hit.image, scale: 1), hit.size)
        }
        guard let fresh = imageThumbnail(image, maxPixels: maxPixels) else { return nil }
        decoded.setObject(Decoded(image: fresh.image, size: fresh.size), forKey: key)
        return (Image(decorative: fresh.image, scale: 1), fresh.size)
    }
}
