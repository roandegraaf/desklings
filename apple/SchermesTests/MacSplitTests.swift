#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Schermes

/// `MacSplit` hands each pane a new `AnyView` root on every update of its parent, which the console
/// does on its 2 s poll. The chat pane's draft and scroll position must come through that.
@MainActor
@Suite struct MacSplitTests {
    @Observable final class Ticker { var tick = 0 }

    final class Probe {
        var seen: [(tick: Int, token: UUID)] = []
    }

    struct Detail: View {
        let tick: Int
        let probe: Probe
        @State private var token = UUID()

        var body: some View {
            ScrollView {
                LazyVStack {
                    ForEach(0..<300, id: \.self) { Text("Row \($0)").frame(height: 20) }
                }
            }
            .overlay { Text("\(tick)") }
            .onChange(of: tick, initial: true) { probe.seen.append((tick, token)) }
        }
    }

    struct Shell: View {
        let ticker: Ticker
        let probe: Probe

        var body: some View {
            MacSplit(inspecting: true, onInspecting: { _ in }) {
                Text("Sidebar")
            } detail: {
                Detail(tick: ticker.tick, probe: probe)
            } inspector: {
                Text("Inspector")
            }
        }
    }

    private func withShell(_ body: (NSWindow, Ticker, Probe) async throws -> Void) async throws {
        let ticker = Ticker()
        let probe = Probe()
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 1200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Shell(ticker: ticker, probe: probe))
        window.orderFrontRegardless()
        defer { window.close() }
        try await until { probe.seen.count == 1 }
        try await body(window, ticker, probe)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }

    private func controller(in window: NSWindow) throws -> MacSplitController {
        let content = try #require(window.contentView)
        let split = try #require(descendants(of: content).compactMap { $0 as? NSSplitView }.first)
        return try #require(split.delegate as? MacSplitController)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test func detailStateAndScrollSurviveARefresh() async throws {
        try await withShell { window, ticker, probe in
            let detail = try controller(in: window).detail.view
            let scroll = try #require(descendants(of: detail).compactMap { $0 as? NSScrollView }.first)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
            scroll.reflectScrolledClipView(scroll.contentView)

            for next in 1...3 {
                ticker.tick = next
                try await until { probe.seen.last?.tick == next }
            }

            #expect(probe.seen.map(\.tick) == [0, 1, 2, 3])
            #expect(Set(probe.seen.map(\.token)).count == 1)
            #expect(scroll.contentView.bounds.origin.y == 1000)
        }
    }

    @Test func viewMenuHasToggleSidebar() throws {
        let items = try #require(NSApp.mainMenu).items.flatMap { $0.submenu?.items ?? [] }
        let toggle = try #require(items.first { $0.title == "Toggle Sidebar" })
        #expect(toggle.keyEquivalent == "s")
        #expect(toggle.keyEquivalentModifierMask == [.control, .command])
    }

    @Test func toggleSidebarCommandTogglesTheWindowsSidebar() async throws {
        try await withShell { window, _, _ in
            let items = try controller(in: window).splitViewItems
            let sidebar = try #require(items.first)
            #expect(!sidebar.isCollapsed)
            NotificationCenter.default.post(name: .toggleSidebar, object: window)
            try await until { sidebar.isCollapsed }
            NotificationCenter.default.post(name: .toggleSidebar, object: window)
            try await until { !sidebar.isCollapsed }
        }
    }
}
#endif
