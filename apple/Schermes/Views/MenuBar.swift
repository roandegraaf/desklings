import SwiftUI

let consoleWindowID = "console"

enum QuickMessage: Equatable {
    case empty
    /// No `@`: for the agent last written to.
    case plain(String)
    case to(agent: String, text: String)
    case unknown(String)
}

/// A leading `@name` picks the agent (any case, one `:` or `,` after it allowed); an unknown name
/// is reported rather than sent to whoever was last.
func quickMessage(_ input: String, agents: [String]) -> QuickMessage {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .empty }
    guard text.hasPrefix("@") else { return .plain(text) }
    let body = text.dropFirst()
    let token = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    guard !token.isEmpty else { return .plain(text) }
    var rest = body.dropFirst(token.count)
    if rest.first == ":" || rest.first == "," { rest = rest.dropFirst() }
    guard let name = agents.first(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) else {
        return .unknown(String(token))
    }
    return .to(agent: name, text: rest.trimmingCharacters(in: .whitespacesAndNewlines))
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// The menu bar's own poll: the console window can be closed while the extra stays.
@Observable
final class MenuBarFeed {
    private(set) var agents: [Agent] = []
    private(set) var needs: [NeedsYouItem] = []
    var shown = false

    private var session: Session?
    private var looks: AgentLooks?

    func start(session: Session, looks: AgentLooks) {
        guard self.session == nil else { return }
        self.session = session
        self.looks = looks
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(shown ? 2 : 10))
            }
        }
    }

    func refresh() async {
        guard let session, session.phase == .ready,
              let rows = try? await session.run({ try await $0.agents() })
        else { return }
        if agents != rows { agents = rows }
        looks?.adopt(rows)
        if let pending = try? await session.run({ try await $0.needsYou() }), pending != needs { needs = pending }
    }

    func drop(_ id: String) {
        needs.removeAll { $0.id == id }
    }
}

extension NeedsYouItem {
    /// Only yes and no are answered from the panel; anything else becomes Open, into the console.
    var answeredInPlace: NeedsYouItem {
        var copy = self
        copy.actions = actions.filter { [.approve, .always, .deny].contains($0) }
        if case .other = kind { return copy }
        if copy.actions.count < actions.count || copy.actions.isEmpty { copy.actions.append(.open) }
        return copy
    }
}

struct MenuBarLabel: View {
    let session: Session
    let looks: AgentLooks
    let feed: MenuBarFeed

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: feed.needs.isEmpty ? "bell" : "bell.badge.fill")
            if !feed.needs.isEmpty { Text("\(feed.needs.count)") }
        }
        .onAppear { feed.start(session: session, looks: looks) }
    }
}

struct MenuBarPanel: View {
    let session: Session
    let looks: AgentLooks
    let feed: MenuBarFeed

    @Environment(\.openWindow) private var openWindow
    @AppStorage("schermes.quickTarget") private var lastTarget = ""
    @State private var draft = ""
    @State private var picked: String?
    @State private var sending = false
    @State private var note: String?
    @FocusState private var typing: Bool

    private var targets: [Agent] { feed.agents.filter { $0.parentId == nil } }
    private var titles: [String: String] { Schermes.titles(feed.agents) }
    private var parsed: QuickMessage { quickMessage(draft, agents: targets.map(\.name)) }

    private var target: String? {
        switch parsed {
        case .to(let agent, _): agent
        case .unknown: nil
        case .plain, .empty: picked ?? (targets.contains { $0.name == lastTarget } ? lastTarget : nil)
        }
    }

    private var text: String {
        switch parsed {
        case .to(_, let text), .plain(let text): text
        case .unknown, .empty: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.phase == .ready {
                quick
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        waiting
                        working
                    }
                }
                .frame(maxHeight: 480)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open Schermes to sign in.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
            Button { openConsole(at: nil) } label: {
                HStack {
                    Text("Open Schermes")
                    Spacer()
                    Text("⌘O").foregroundStyle(Theme.muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .padding(12)
        .frame(width: 370)
        .background(Theme.panel)
        .onAppear {
            feed.start(session: session, looks: looks)
            feed.shown = true
            typing = true
            Task { await feed.refresh() }
        }
        .onDisappear { feed.shown = false }
        .onChange(of: draft) { _, now in
            if !now.isEmpty { note = nil }
        }
    }

    private var quick: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                TextField("Message, or @name message", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($typing)
                    .disabled(sending)
                    .onSubmit(send)
                Text("⌥Space")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.card, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline) }
            HStack(spacing: 8) {
                Menu {
                    ForEach(targets) { agent in
                        Button(agent.title) { picked = agent.name }
                    }
                } label: {
                    Text(target.map { "To \(titles[$0] ?? $0)" } ?? "Pick an agent")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if case .unknown(let name) = parsed {
                    Text("There is no agent called \(name).")
                        .foregroundStyle(Theme.failed)
                } else if target == nil, !text.isEmpty {
                    Text("Pick who gets it, or start with @name.")
                        .foregroundStyle(Theme.muted)
                } else if let note {
                    Text(note)
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 12))
            .lineLimit(2)
            .padding(.horizontal, 4)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarLabel(title: "Needs you").padding(.horizontal, 4)
            if feed.needs.isEmpty {
                Text("Nothing is waiting on you.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }
            ForEach(feed.needs) { item in
                NeedsYouCard(
                    item: item.answeredInPlace,
                    agent: feed.agents.first { $0.name == item.agent },
                    titles: titles,
                    compact: true,
                    onAct: act
                )
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarLabel(title: "Working").padding(.horizontal, 4).padding(.bottom, 4)
            let busy = feed.agents.filter(\.state.busy)
            if busy.isEmpty {
                Text("Nothing is running.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }
            ForEach(busy) { BusyAgentRow(agent: $0, size: 22).padding(.horizontal, 8) }
        }
    }

    private func act(_ item: NeedsYouItem, _ action: NeedsYouAction) async {
        guard [.approve, .always, .deny].contains(action) else { return openConsole(at: item.agent) }
        do {
            try await session.run { try await $0.act(onNeedsYou: item.id, action) }
            feed.drop(item.id)
            await feed.refresh()
        } catch {
            if !error.isCancellation { note = error.localizedDescription }
        }
    }

    private func send() {
        guard let target, !text.isEmpty, !sending else { return }
        let message = text
        sending = true
        Task {
            do {
                _ = try await session.run { try await $0.send(.agent(target), text: message) }
                lastTarget = target
                picked = nil
                draft = ""
                note = "Sent to \(titles[target] ?? target)."
                await feed.refresh()
            } catch {
                if !error.isCancellation { note = error.localizedDescription }
            }
            sending = false
            typing = true
        }
    }

    /// A console window that is only hidden or minimised is brought back rather than doubled.
    private func openConsole(at agent: String?) {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(consoleWindowID) == true && ($0.isVisible || $0.isMiniaturized)
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: consoleWindowID)
        }
        NSApp.activate()
        if let agent { NotificationCenter.default.post(name: .openAgent, object: agent) }
    }
}

/// ⌥Space from any app. Carbon's hot keys need no Accessibility permission, unlike an `NSEvent`
/// global monitor.
enum PanelHotKey {
    private static var hotKey: EventHotKeyRef?

    static func register() {
        // A test run hosts the whole app; it must not take the owner's ⌥Space meanwhile.
        guard hotKey == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { PanelHotKey.toggle() }
            return noErr
        }, 1, &pressed, nil, nil)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x5343_484D), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// SwiftUI has no call that opens a `MenuBarExtra`, so this clicks its status item, found by
    /// walking views rather than through a private key-value name.
    static func toggle() {
        let button = NSApp.windows
            .filter { $0.className == "NSStatusBarWindow" }
            .lazy
            .compactMap { $0.contentView.flatMap(firstButton(in:)) }
            .first
        button?.performClick(nil)
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap(firstButton(in:)).first
    }
}
#endif
