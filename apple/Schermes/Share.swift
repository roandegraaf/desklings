import SwiftUI

/// Shared by the iPhone app and its share extension: the daemon address and a copy of the owner
/// password live here, because the extension has no `Session` and no container of the app's.
nonisolated let appGroup = "group.dev.schermes"

/// The daemon's own limit on a file handed to an agent.
nonisolated let maxShareBytes = 25_000_000

/// What the share sheet or a Service hands over.
enum SharedItem: Sendable, Equatable {
    case link(URL)
    case text(String)
    case file(name: String, data: Data)
}

/// Who gets it: an agent, or an open goal, which its lead receives.
struct ShareTarget: Hashable, Identifiable {
    var recipient: String
    var goal: Goal?

    var id: String { goal.map { "goal:\($0.id)" } ?? "agent:\(recipient)" }
}

enum ShareError: LocalizedError {
    case nothing
    case tooBig
    case noDaemon

    var errorDescription: String? {
        switch self {
        case .nothing: "There is nothing here to send."
        case .tooBig: "A file may be at most \(maxShareBytes / 1_000_000) MB."
        case .noDaemon: "Open Schermes and sign in first."
        }
    }
}

/// The one owner line the recipient gets. A file is named by where the daemon put it.
func sharedMessage(_ item: SharedItem, instruction: String, goal: Goal?, uploadedTo path: String? = nil) -> String {
    let asked = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts = [asked.isEmpty ? "Have a look at this." : asked]
    if let goal { parts.append("This is for the goal \"\(goal.title)\".") }
    switch item {
    case .link(let url):
        parts.append(url.absoluteString)
    case .text(let text):
        parts.append(text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
    case .file(let name, _):
        parts.append("I put the file in your home: \(path ?? name)")
    }
    return parts.joined(separator: "\n\n")
}

/// A name the daemon's uploads route takes: `^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,127}$`, no `..`.
/// Accents are folded rather than lost, and a long name keeps its extension.
func uploadFilename(_ name: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._()+-")
    let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    var cleaned = String(String.UnicodeScalarView(folded.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
    while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: ".") }
    cleaned = String(cleaned.drop { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
    if cleaned.isEmpty { return "shared" }
    guard cleaned.count > 128 else { return cleaned }
    let ext = (cleaned as NSString).pathExtension
    guard !ext.isEmpty, ext.count < 16 else { return String(cleaned.prefix(128)) }
    return String(cleaned.dropLast(ext.count + 1).prefix(127 - ext.count)) + "." + ext
}

/// A file goes into the recipient's `~/uploads` first, so the message can say where it is.
func deliverShare(_ item: SharedItem, to target: ShareTarget, instruction: String, client: SchermesClient) async throws {
    var path: String?
    if case .file(let name, let data) = item {
        path = try await client.upload(agent: target.recipient, name: uploadFilename(name), data: data).path
    }
    let text = sharedMessage(item, instruction: instruction, goal: target.goal, uploadedTo: path)
    _ = try await client.send(.agent(target.recipient), text: text)
}

/// A client off the stored address, for a caller with no `Session`: a background launch, the
/// share extension, a Service. The cookie store carries the login; a 401 spends the stored
/// password once, like `Session.run`.
enum StoredDaemon {
    /// The iPhone app mirrors its address into the group for the extension. The Mac keeps to its
    /// own defaults: touching a group container it is not entitled to can raise a privacy panel.
    static var sharedDefaults: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: appGroup) ?? .standard
        #else
        .standard
        #endif
    }

    static func client(from defaults: UserDefaults) -> SchermesClient? {
        defaults.string(forKey: addressKey).flatMap(Session.parse).map { SchermesClient(baseURL: $0) }
    }

    static func run(_ client: SchermesClient, _ call: (SchermesClient) async throws -> Void) async throws {
        do {
            try await call(client)
        } catch SchermesError.unauthorized {
            let loggedIn = await Session.reLogin(client) { daemon in
                await Task.detached { Keychain.read(for: daemon) }.value
            }
            guard loggedIn else { throw SchermesError.unauthorized }
            try await call(client)
        }
    }
}

/// Pick an agent or an open goal, add an instruction, send. The iOS share extension and the Mac
/// "Send to Schermes" Service both show this.
#if SCHERMES_EXTENSION
/// The share extension compiles without the app's theme, so it keeps the stock grouped form.
private struct ShareForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View { Form { content }.formStyle(.grouped) }
}

private let troubleColor = Color.red
#else
private typealias ShareForm = ThemedForm
private let troubleColor = Theme.failed
#endif

struct SendToSheet: View {
    let client: SchermesClient?
    let load: () async throws -> SharedItem
    let finish: (_ sent: Bool) -> Void

    @State private var item: SharedItem?
    @State private var agents: [Agent]?
    @State private var goals: [Goal] = []
    @State private var picked: ShareTarget?
    @State private var instruction = ""
    @State private var sending = false
    @State private var trouble: String?

    var body: some View {
        NavigationStack {
            ShareForm {
                if let item { Section { preview(item) } }
                if !goals.isEmpty {
                    Section("Open goals") {
                        ForEach(goals) { goal in
                            row(ShareTarget(recipient: goal.lead, goal: goal), title: goal.title, detail: "Led by \(leadTitle(goal.lead))")
                        }
                    }
                }
                Section("Agents") {
                    if let agents {
                        if agents.isEmpty, trouble == nil {
                            Text("There is no agent to send this to.").foregroundStyle(.secondary)
                        }
                        ForEach(agents) { agent in
                            row(ShareTarget(recipient: agent.name), title: agent.title, detail: agentDetail(agent))
                        }
                    } else if trouble == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                Section {
                    TextField("What should happen with it?", text: $instruction, axis: .vertical)
                        .lineLimit(2...6)
                    if let trouble {
                        Label(trouble, systemImage: "exclamationmark.triangle").foregroundStyle(troubleColor)
                    }
                } header: {
                    Text(picked.map { "Instruction for \(leadTitle($0.recipient))" } ?? "Instruction")
                }
            }
            .navigationTitle("Send to Schermes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(picked == nil || item == nil || sending)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 480)
        #endif
        .task { await start() }
    }

    @ViewBuilder
    private func preview(_ item: SharedItem) -> some View {
        switch item {
        case .link(let url):
            Label(url.absoluteString, systemImage: "link").lineLimit(2)
        case .text(let text):
            Label(text, systemImage: "text.quote").lineLimit(4)
        case .file(let name, let data):
            Label {
                HStack {
                    Text(name).fontDesign(.monospaced)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "doc")
            }
            .lineLimit(1)
        }
    }

    private func agentDetail(_ agent: Agent) -> String? {
        let name = agent.label == nil ? nil : "@\(agent.name)"
        return [name, agent.tagline].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private func leadTitle(_ name: String) -> String {
        agents?.first { $0.name == name }?.title ?? name
    }

    private func row(_ target: ShareTarget, title: String, detail: String?) -> some View {
        Button { picked = target } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .fontDesign(.rounded)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if picked == target {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked == target ? .isSelected : [])
    }

    private func start() async {
        do {
            item = try await load()
            guard let client else { throw ShareError.noDaemon }
            var all: [Agent] = []
            var open: [Goal] = []
            try await StoredDaemon.run(client) {
                all = try await $0.agents()
                open = try await $0.goals().filter(\.isOpen)
            }
            agents = all.filter { $0.parentId == nil }
            goals = open
        } catch SchermesError.unauthorized {
            trouble = ShareError.noDaemon.errorDescription
        } catch {
            trouble = error.localizedDescription
        }
    }

    private func send() {
        guard let picked, let item, let client else { return }
        sending = true
        trouble = nil
        Task {
            do {
                try await StoredDaemon.run(client) {
                    try await deliverShare(item, to: picked, instruction: instruction, client: $0)
                }
                finish(true)
            } catch {
                trouble = error.localizedDescription
            }
            sending = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if os(macOS)
import AppKit

/// "Send to Schermes…" in the Services menu, for text, links and files. It runs in the app, so
/// the sheet opens in a window of its own and the console need not be showing.
final class ShareService: NSObject {
    private var windows: [NSWindow] = []

    @objc(sendToSchermes:userData:error:)
    func sendToSchermes(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let item: SharedItem
        do {
            item = try Self.item(from: pasteboard)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Send to Schermes"
        window.contentViewController = NSHostingController(rootView: SendToSheet(
            client: StoredDaemon.client(from: .standard),
            load: { item },
            finish: { [weak self, weak window] _ in
                window?.close()
                self?.windows.removeAll { $0 === window }
            }
        ))
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func item(from pasteboard: NSPasteboard) throws -> SharedItem {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            guard url.isFileURL else { return .link(url) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxShareBytes else { throw ShareError.tooBig }
            return .file(name: url.lastPathComponent, data: try Data(contentsOf: url))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
        throw ShareError.nothing
    }
}
#endif
