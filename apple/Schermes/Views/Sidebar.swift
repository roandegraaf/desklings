import SwiftUI

extension View {
    /// A Mac sidebar row draws its own fill, so the list only spaces it inside the panel.
    @ViewBuilder func sidebarRow() -> some View {
        #if os(macOS)
        listRowInsets(EdgeInsets(top: 1, leading: -2, bottom: 1, trailing: -2))
        #else
        self
        #endif
    }
}

extension View {
    /// The Mac's fill for a picked row that has no agent colour of its own.
    @ViewBuilder func sidebarPicked(_ picked: Bool) -> some View {
        #if os(macOS)
        background(picked ? AnyShapeStyle(Theme.ink.opacity(0.06)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        #else
        self
        #endif
    }
}

struct CountCapsule: View {
    let count: Int
    let fill: AnyShapeStyle
    let text: AnyShapeStyle

    var body: some View {
        Text("\(count)")
            #if os(macOS)
            .font(.system(size: 12, weight: .bold))
            #else
            .font(.caption.bold())
            #endif
            .monospacedDigit()
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 22)
            .background(fill, in: .capsule)
    }
}

/// The canvas's section label: small, uppercase, spaced out.
struct SidebarLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.canvas(11, .caption2, weight: .semibold))
            .tracking(0.44)
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)
            .padding(.top, 10)
    }
}

#if os(macOS)

/// The Mac window's three floating panels: r22 cards on the warm window ground, with `inset`
/// round the window and between them.
enum MacPanel {
    static let radius: CGFloat = 22
    static let inset: CGFloat = 10
}

extension View {
    /// The sidebar and inspector card from the canvas's Main: white 66%, a white 90% hairline and
    /// a two-layer ink shadow, running up under the title bar, where the traffic lights sit on it.
    func macPanel() -> some View {
        background {
            RoundedRectangle(cornerRadius: MacPanel.radius)
                .fill(Theme.card.opacity(0.66))
                .strokeBorder(Theme.card.opacity(0.9), lineWidth: 1)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.06), radius: 16, y: 12)
                .ignoresSafeArea()
        }
    }
}

/// The Mac window's three panes. `NavigationSplitView` puts the sidebar and the inspector in glass
/// columns with a divider line and a shadow at each edge, and AppKit offers no switch for that
/// glass on sidebar or inspector items. Plain split items have none; the divider is the gutter.
struct MacSplit<Sidebar: View, Detail: View, Inspector: View>: NSViewControllerRepresentable {
    let inspecting: Bool
    let onInspecting: (Bool) -> Void
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail
    @ViewBuilder let inspector: Inspector

    func makeNSViewController(context: Context) -> MacSplitController {
        MacSplitController(inspecting: inspecting)
    }

    func updateNSViewController(_ controller: MacSplitController, context: Context) {
        // A hosting controller starts from a fresh environment; the panes need this one's looks,
        // session objects and tint.
        let environment = context.environment
        controller.sidebar.rootView = AnyView(
            // Main's traffic-light row: the card's 14pt padding, the 12pt lights and their 14pt of air.
            sidebar.safeAreaPadding(.top, 41).environment(\.self, environment)
        )
        controller.detail.rootView = AnyView(detail.environment(\.self, environment))
        controller.inspector.rootView = AnyView(inspector.environment(\.self, environment))
        controller.onInspecting = onInspecting
        controller.show(inspector: inspecting)
    }
}

final class MacSplitController: NSSplitViewController {
    let sidebar = MacSplitController.host()
    let detail = MacSplitController.host()
    let inspector = MacSplitController.host()
    var onInspecting: (Bool) -> Void = { _ in }
    private var inspectorItem: NSSplitViewItem!
    private var inspectorShown: Bool
    private var placed = false
    private var animating = false

    init(inspecting: Bool) {
        inspectorShown = inspecting
        super.init(nibName: nil, bundle: nil)
        splitView = GutterSplitView()
        splitView.isVertical = true
        if !hostingTests { splitView.autosaveName = "console.split" }
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.holdingPriority = .init(260)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 320
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.holdingPriority = .init(260)
        inspectorItem.isCollapsed = !inspecting
        [sidebarItem, detailItem, inspectorItem].forEach(addSplitViewItem)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleSidebarOfWindow), name: .toggleSidebar, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func host() -> NSHostingController<AnyView> {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        // The split view sizes the panes; content-driven sizes made it fight SwiftUI.
        host.sizingOptions = []
        // Each pane is a card that starts 10pt from the window top, under the title bar; it sets its
        // own top padding rather than taking the title bar's height as safe area.
        host.safeAreaRegions = []
        return host
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, view.bounds.width > 0, let window = view.window else { return }
        placed = true
        // An empty toolbar makes the title bar the toolbar's height, which puts the traffic lights
        // inside the sidebar card and the content below them, where Main draws them.
        if window.toolbar == nil {
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
        }
        // The autosave restores widths and whether the inspector was shut; the binding decides the
        // latter, and an inspector saved shut has lost its width, so it gets the canvas's again.
        let savedShut = inspectorItem.isCollapsed
        inspectorItem.isCollapsed = !inspectorShown
        let fresh = splitView.autosaveName.map { UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") == nil } ?? true
        if fresh {
            splitView.setPosition(292, ofDividerAt: 0)
        }
        if inspectorShown && (fresh || savedShut) {
            splitView.setPosition(view.bounds.width - 340 - splitView.dividerThickness, ofDividerAt: 1)
        }
    }

    /// The stock action looks for a sidebar-behaviour item, and ours is a plain one.
    override func toggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    @objc private func toggleSidebarOfWindow(_ note: Notification) {
        guard let window = view.window, note.object as? NSWindow === window else { return }
        toggleSidebar(nil)
    }

    func show(inspector shown: Bool) {
        guard shown != inspectorShown else { return }
        inspectorShown = shown
        animating = true
        NSAnimationContext.runAnimationGroup { _ in
            inspectorItem.animator().isCollapsed = !shown
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.settled() }
        }
    }

    private func settled() {
        animating = false
    }

    /// A drag that closes or opens the inspector goes back to the binding the header button reads.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard placed, !animating, inspectorItem.isCollapsed == inspectorShown else { return }
        inspectorShown = !inspectorItem.isCollapsed
        onInspecting(inspectorShown)
    }
}

private final class GutterSplitView: NSSplitView {
    override var dividerThickness: CGFloat { MacPanel.inset }
    override func drawDivider(in rect: NSRect) {}
}

struct SidebarSearchRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            Text("Search or ask").frame(maxWidth: .infinity, alignment: .leading)
            Text("⌘K").font(.system(size: 11).monospaced())
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Theme.ink.opacity(0.06), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}

/// Calm when nothing waits; the Needs you tile, fill and count the moment something does.
struct SidebarHomeRow: View {
    let count: Int
    let selected: Bool

    private var waiting: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: waiting ? "bell.fill" : "house.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(waiting ? Theme.onNeedsYouTile : Theme.secondary)
                .frame(width: 30, height: 30)
                .background(waiting ? AnyShapeStyle(Theme.needsYouTile) : AnyShapeStyle(Theme.ink.opacity(0.06)), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 0) {
                Text("Home")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                if waiting {
                    Text(count == 1 ? "1 thing needs you" : "\(count) things need you")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.needsYou)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if waiting {
                CountCapsule(count: count, fill: AnyShapeStyle(Theme.ink), text: AnyShapeStyle(Theme.onInk))
            }
        }
        .padding(8)
        .background(fill, in: .rect(cornerRadius: 12))
        .animation(.snappy, value: waiting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Home")
        .accessibilityValue(waiting ? (count == 1 ? "1 thing needs you" : "\(count) things need you") : "")
    }

    private var fill: AnyShapeStyle {
        switch (waiting, selected) {
        case (true, true): AnyShapeStyle(Theme.needsYouFill)
        case (true, false): AnyShapeStyle(Theme.needsYouSoft)
        case (false, true): AnyShapeStyle(Theme.ink.opacity(0.06))
        case (false, false): AnyShapeStyle(.clear)
        }
    }
}

/// An agent in the Mac sidebar: bloub, rounded name, a state line, and its waiting count in its
/// own bubble colour. The row picked is filled with the agent's soft colour.
struct SidebarAgentRow: View {
    let agent: Agent
    let needs: [NeedsYouItem]
    let unread: Bool
    let selected: Bool

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let identity = looks[agent.name]
        let palette = identity.palette(dark: scheme == .dark)
        HStack(spacing: 10) {
            BloubView(state: agent.state.bloub, identity: identity, size: 34)
                .busyHalo(agent.state.busy, color: identity.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                if !needs.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "bell")
                        Text("Needs you")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.needsYou)
                } else {
                    StateLine(state: agent.state, identity: identity, font: .system(size: 12, weight: .semibold))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !needs.isEmpty {
                CountCapsule(
                    count: needs.count,
                    fill: AnyShapeStyle(palette.bubble.color),
                    text: AnyShapeStyle(palette.bubbleText.color)
                )
            } else if unread {
                UnreadDot()
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(selected ? AnyShapeStyle(palette.soft.color) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A goal's helper, indented under its lead.
struct SidebarHelperRow: View {
    let name: String
    let title: String
    let lead: String
    let state: AgentState
    let selected: Bool

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            HelperBloub(state: state, name: name, lead: lead, size: 20)
            Text(title).fontWeight(.semibold).foregroundStyle(Theme.secondary)
            Text(state.presentation.word).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            selected ? AnyShapeStyle(looks[lead].palette(dark: scheme == .dark).soft.color) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 10)
        )
        .padding(.leading, 26)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
#endif
