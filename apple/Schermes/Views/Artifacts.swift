import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What the app draws itself rather than handing to Quick Look: prose as rendered Markdown, a
/// page as a page, code as code. Anything else, a PDF or a spreadsheet, Quick Look does better.
enum ArtifactKind: Equatable {
    case markdown
    case web(mime: String)
    case code
}

func artifactKind(_ path: String) -> ArtifactKind? {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "md" || ext == "markdown" { return .markdown }
    guard let type = UTType(filenameExtension: ext) else { return nil }
    if type.conforms(to: .html) { return .web(mime: "text/html") }
    if type.conforms(to: .svg) { return .web(mime: "image/svg+xml") }
    if type.conforms(to: .sourceCode) || type.conforms(to: .json) { return .code }
    if type.conforms(to: .text), !type.conforms(to: .delimitedText) { return .code }
    return nil
}

/// A file the agent named, open beside the chat. The pane fetches it itself, so opening it again
/// shows the file as it is now.
struct Artifact: Identifiable {
    let source: FileSource
    let path: String
    let kind: ArtifactKind

    var id: String { "\(source.agent)\n\(path)" }
    var name: String { (path as NSString).lastPathComponent }
}

/// The one artifact a thread has open. Nil in the environment where there is no pane to open one
/// in, and the file falls back to Quick Look.
@Observable
final class Artifacts {
    var open: Artifact?

    /// True when the file is one the pane draws, and it is now open there.
    func show(_ path: String, from source: FileSource) -> Bool {
        guard let kind = artifactKind(path) else { return false }
        open = Artifact(source: source, path: path, kind: kind)
        return true
    }
}

/// The pane itself: the file's name, a switch between the rendering and its source where the two
/// differ, copy, save and close.
struct ArtifactPane: View {
    let artifact: Artifact
    let close: () -> Void

    @State private var file: URL?
    @State private var text = ""
    @State private var trouble: String?
    @State private var showingSource = false
    @State private var copied = false
    #if os(iOS)
    @State private var saving: URL?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: artifact.id) { await load() }
        #if os(iOS)
        .fileMover(
            isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
            file: saving
        ) { _ in }
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(artifact.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(artifact.path)
            Spacer()
            if artifact.kind != .code {
                Picker("View", selection: $showingSource) {
                    Text("Preview").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                copyToPasteboard(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .disabled(file == nil)
            Button(SAVE_LABEL, systemImage: "square.and.arrow.down") { keep() }
                .disabled(file == nil)
            Button("Close", systemImage: "xmark") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let trouble {
            ContentUnavailableView("Could not open", systemImage: "doc.questionmark", description: Text(trouble))
        } else if file == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch artifact.kind {
            case .markdown where !showingSource:
                ScrollView {
                    MarkdownText(content: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            case .web(let mime) where !showingSource:
                WebPage(data: Data(text.utf8), mime: mime).id(text)
            default:
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
        }
    }

    private func load() async {
        file = nil
        trouble = nil
        do {
            let fetched = try await artifact.source.fetch(artifact.path)
            text = try String(contentsOf: fetched, encoding: .utf8)
            file = fetched
        } catch {
            trouble = error.localizedDescription
        }
    }

    private func keep() {
        guard let file else { return }
        #if os(macOS)
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try moveToDownloads(file)])
        } catch {
            trouble = error.localizedDescription
        }
        #else
        saving = file
        #endif
    }
}

/// The page as WebKit draws it. No base URL, so the page cannot reach the app's files.
/// ponytail: scripts run unrestricted; add a content rule list if agent pages need fencing in.
private struct WebPage {
    let data: Data
    let mime: String

    private func make() -> WKWebView {
        let view = WKWebView()
        view.load(data, mimeType: mime, characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return view
    }
}

#if os(macOS)
extension WebPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension WebPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

/// Where the pane goes: beside the chat where there is room, as the desktop app does it, and
/// over it as a sheet on a phone.
struct ArtifactSplit: ViewModifier {
    let artifacts: Artifacts
    let roomy: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if roomy, let artifact = artifacts.open {
                Divider()
                ArtifactPane(artifact: artifact) { artifacts.open = nil }
                    .frame(minWidth: 320, idealWidth: 520)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.default, value: artifacts.open?.id)
        .sheet(item: Binding(get: { roomy ? nil : artifacts.open }, set: { artifacts.open = $0 })) { artifact in
            ArtifactPane(artifact: artifact) { artifacts.open = nil }
        }
    }
}
