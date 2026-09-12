import SwiftUI

extension AgentState {
    var tint: Color {
        switch self {
        case .failed: .red
        case .thinking, .using_computer, .using_terminal: .orange
        case .waiting_for_user, .waiting_for_agent, .waiting_for_task_worker: .blue
        case .completed: .secondary
        case .idle: .green
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

    var body: some View {
        if let decoded = Self.load(image) {
            decoded
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 12))
        } else {
            Label("screenshot could not be read", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func load(_ image: Base64Image) -> Image? {
        guard let data = Data(base64Encoded: image.base64) else { return nil }
        #if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
