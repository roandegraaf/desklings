import CryptoKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Where the files an agent names are fetched from: its home, as the daemon reads it.
struct FileSource {
    let session: Session
    let agent: String

    /// Into a folder of its own per file under the temporary directory, so the name is the
    /// agent's and asking again replaces the copy rather than adding one. Fetched every time, so
    /// what opens is the file as it is now, not as it was when the reply came in.
    func fetch(_ path: String) async throws -> URL {
        let file = try await session.run { try await $0.file(agent: agent, path: path) }
        guard let data = Data(base64Encoded: file.base64) else { throw CocoaError(.fileReadCorruptFile) }
        let digest = SHA256.hash(data: Data("\(agent)\n\(path)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.temporaryDirectory.appending(path: "files-\(digest)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: file.name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct FileKind: Equatable {
    var label: String
    var symbol: String
    var tint: Color = .gray
}

/// What a file is, in the words a person uses, from the system's own type table.
func fileKind(_ path: String) -> FileKind {
    let ext = (path as NSString).pathExtension
    guard let type = UTType(filenameExtension: ext) else { return FileKind(label: "File", symbol: "doc") }
    let kinds: [(UTType, FileKind)] = [
        (.spreadsheet, FileKind(label: "Spreadsheet", symbol: "tablecells", tint: .green)),
        (.delimitedText, FileKind(label: "Spreadsheet", symbol: "tablecells", tint: .green)),
        (.pdf, FileKind(label: "PDF", symbol: "doc.richtext", tint: .red)),
        (.presentation, FileKind(label: "Presentation", symbol: "rectangle.on.rectangle", tint: .orange)),
        (.image, FileKind(label: "Image", symbol: "photo", tint: .purple)),
        (.movie, FileKind(label: "Video", symbol: "film", tint: .pink)),
        (.audio, FileKind(label: "Audio", symbol: "waveform", tint: .pink)),
        (.archive, FileKind(label: "Archive", symbol: "doc.zipper", tint: .brown)),
        (.sourceCode, FileKind(label: "Code", symbol: "chevron.left.forwardslash.chevron.right", tint: .indigo)),
        (.json, FileKind(label: "Code", symbol: "chevron.left.forwardslash.chevron.right", tint: .indigo)),
        (.text, FileKind(label: "Document", symbol: "doc.text", tint: .blue)),
    ]
    return kinds.first { type.conforms(to: $0.0) }?.1 ?? FileKind(label: "File", symbol: "doc")
}

/// A file an agent named, drawn where it named it. The card opens it; the arrow keeps it. An image
/// is shown as itself instead.
struct FileCard: View {
    let source: FileSource
    let path: String

    @State private var working = false
    @State private var trouble: String?
    @State private var previewing: URL?
    @State private var picture: URL?
    #if os(iOS)
    @State private var saving: URL?
    #endif
    @Environment(Artifacts.self) private var artifacts: Artifacts?

    private var name: String { (path as NSString).lastPathComponent }
    private var kind: FileKind { fileKind(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if kind.label == "Image" {
                image
            } else {
                card
            }
            if let trouble {
                Text(trouble).font(.caption).foregroundStyle(.red)
            }
        }
        .quickLookPreview($previewing)
        #if os(iOS)
        .fileMover(
            isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
            file: saving
        ) { _ in }
        #endif
    }

    private var card: some View {
        HStack(spacing: 0) {
            Button { Task { await preview() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(kind.tint.gradient, in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text("\(kind.label) · \((path as NSString).pathExtension.uppercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(path)
            .accessibilityLabel("\(name), \(kind.label)")
            .accessibilityHint("Opens a preview")

            download
        }
        .padding(.leading, 8)
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    @ViewBuilder private var image: some View {
        if let picture, let (shown, size) = Self.load(picture), size.width > 0, size.height > 0 {
            let scale = min(1, 380 / size.width, 280 / size.height)
            ZStack(alignment: .topTrailing) {
                Button { previewing = picture } label: {
                    shown
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help(path)
                .accessibilityLabel("\(name), image")
                .accessibilityHint("Opens a preview")
                .contextMenu {
                    Button("Quick Look", systemImage: "eye") { previewing = picture }
                    Button("Copy Image", systemImage: "doc.on.doc") { copyImageToPasteboard(at: picture) }
                    Button(SAVE_LABEL, systemImage: "square.and.arrow.down") { Task { await keep() } }
                }

                download
                    .background(.regularMaterial, in: .circle)
                    .padding(6)
            }
        } else {
            card.task { picture = await fetch() }
        }
    }

    private var download: some View {
        #if os(iOS)
        let side: CGFloat = 44
        #else
        let side: CGFloat = 28
        #endif
        return Button { Task { await keep() } } label: {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Download", systemImage: "arrow.down.circle").labelStyle(.iconOnly)
                }
            }
            .font(.body)
            .frame(width: side, height: side)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(working)
        .help("Download")
    }

    private func preview() async {
        if artifacts?.show(path, from: source) == true { return }
        previewing = await fetch()
    }

    private func keep() async {
        guard let fetched = await fetch() else { return }
        #if os(macOS)
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try moveToDownloads(fetched)])
        } catch {
            trouble = error.localizedDescription
        }
        #else
        saving = fetched
        #endif
    }

    private func fetch() async -> URL? {
        working = true
        trouble = nil
        defer { working = false }
        do {
            return try await source.fetch(path)
        } catch {
            trouble = error.localizedDescription
            return nil
        }
    }

    private static func load(_ url: URL) -> (Image, CGSize)? {
        #if os(macOS)
        NSImage(contentsOf: url).map { (Image(nsImage: $0), $0.size) }
        #else
        UIImage(contentsOfFile: url.path).map { (Image(uiImage: $0), $0.size) }
        #endif
    }
}

#if os(macOS)
let SAVE_LABEL = "Save to Downloads"

/// As a browser does it: a name that is taken gets a number rather than overwriting.
func moveToDownloads(_ file: URL) throws -> URL {
    let downloads = try FileManager.default.url(
        for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    let stem = file.deletingPathExtension().lastPathComponent
    let ext = file.pathExtension
    var target = downloads.appending(path: file.lastPathComponent)
    var copy = 1
    while FileManager.default.fileExists(atPath: target.path) {
        target = downloads.appending(path: ext.isEmpty ? "\(stem) (\(copy))" : "\(stem) (\(copy)).\(ext)")
        copy += 1
    }
    try FileManager.default.copyItem(at: file, to: target)
    return target
}
#else
let SAVE_LABEL = "Save to Files"
#endif
