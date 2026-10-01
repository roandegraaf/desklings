import SwiftUI
import UniformTypeIdentifiers

/// The share sheet's "Schermes" entry. It has no `Session`: the app leaves the daemon address and
/// a copy of the password in the app group, and `StoredDaemon` logs in again on a 401.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let sheet = SendToSheet(
            client: StoredDaemon.client(from: StoredDaemon.sharedDefaults),
            load: { try await Self.item(from: providers) },
            finish: { [weak self] sent in
                if sent {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                }
            }
        )
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// A web link before text, text before a file. A Files share arrives as a file URL, which
    /// conforms to `public.url` too, so a link is only a link when it is not a file.
    static func item(from providers: [NSItemProvider]) async throws -> SharedItem {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                return .link(url)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return .text(text)
            }
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.data.identifier) }) {
            return try await file(from: provider)
        }
        throw ShareError.nothing
    }

    /// The copy `loadFileRepresentation` hands over is gone once its handler returns, so the
    /// bytes are read inside it. Photos gives no filename; the name is then made from the type.
    private nonisolated static func file(from provider: NSItemProvider) async throws -> SharedItem {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? .data
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.nothing)
                    return
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= maxShareBytes else {
                    continuation.resume(throwing: ShareError.tooBig)
                    return
                }
                do {
                    let data = try Data(contentsOf: url)
                    var name = suggested ?? url.lastPathComponent
                    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                        name += ".\(ext)"
                    }
                    continuation.resume(returning: .file(name: name, data: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
