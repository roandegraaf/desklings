#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Schermes

/// Renders the real Mac screens to PNGs, light and dark, against a running daemon. Off unless
/// `TEST_RUNNER_SCHERMES_RENDER_DIR`, `..._ADDRESS` and `..._PASSWORD` reach `xcodebuild test`.
/// Offscreen windows captured with `cacheDisplay`, so nothing comes to the front.
nonisolated private let environment = ProcessInfo.processInfo.environment
nonisolated private let renderDir = environment["SCHERMES_RENDER_DIR"]
nonisolated private let renderAddress = environment["SCHERMES_RENDER_ADDRESS"]
nonisolated private let renderPassword = environment["SCHERMES_RENDER_PASSWORD"]
nonisolated private let renderOnly = environment["SCHERMES_RENDER_ONLY"]

private func wanted(_ name: String) -> Bool {
    renderOnly.map { name.hasPrefix($0) } ?? true
}

@MainActor
@Test(.enabled(if: renderDir != nil && renderAddress != nil && renderPassword != nil))
func renderMacScreens() async throws {
    let dir = URL(filePath: try #require(renderDir))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let domain = Bundle.main.bundleIdentifier ?? "dev.schermes.Schermes"
    let before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    defer { restoreChangedKeys(domain: domain, before: before, log: dir.appending(path: "defaults-restored.txt")) }

    let screens: [(name: String, open: String?)] = [
        ("main-agent", "agent:juno"),
        ("main-mo", "agent:mo"),
        ("main-bare", "bare:juno"),
        ("home", "home"),
        ("goal", "goal:1"),
        ("search", "search:invoices"),
        ("new-agent", "new-agent"),
    ] + AgentPages.Page.allCases.map { ("page-\(slug($0.rawValue))", "pages:juno:\($0.rawValue)") }
    let wide = CGSize(width: 1440, height: 900)
    let sized: [(name: String, open: String, size: CGSize)] = [
        ("settings-agent", "agent-settings:juno", wide),
        ("settings-agent-narrow", "agent-settings:juno", CGSize(width: 1000, height: 680)),
        ("look", "look:juno", wide),
    ]

    for dark in [false, true] {
        let mode = dark ? "dark" : "light"
        let all = screens.map { ($0.name, $0.open, wide) } + sized.map { ($0.name, Optional($0.open), $0.size) }
        for (name, open, size) in all where wanted(name) {
            useLaunchArguments(open: open)
            let session = try checkedSession()
            let window = makeWindow(size: size, dark: dark) {
                RootView(session: session)
            }
            try await settle(window, sheet: open.map(opensSheet) ?? false)
            try save(window, to: dir.appending(path: "mac-\(name)-\(mode).png"))
            window.close()
        }

        for category in SettingsCategory.allCases where wanted("settings-\(category.rawValue)") {
            useLaunchArguments(open: "settings", tab: category.rawValue)
            let session = try checkedSession()
            let window = makeWindow(size: CGSize(width: 1440, height: 900), dark: dark) {
                RootView(session: session)
            }
            try await settle(window, sheet: true)
            try save(window, to: dir.appending(path: "mac-settings-\(category.rawValue)-\(mode).png"))
            window.close()
        }

        guard wanted("menu-bar") else { continue }
        useLaunchArguments(open: nil)
        let session = try checkedSession()
        await session.start()
        try #require(session.phase == .ready)
        let looks = AgentLooks()
        let feed = MenuBarFeed()
        feed.start(session: session, looks: looks)
        let window = makeWindow(size: CGSize(width: 370, height: 620), dark: dark, chrome: false) {
            MenuBarPanel(session: session, looks: looks, feed: feed)
        }
        try await settle(window)
        try save(window, to: dir.appending(path: "mac-menu-bar-\(mode).png"))
        window.close()
    }
}

private func slug(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: " ", with: "-")
}

private func opensSheet(_ target: String) -> Bool {
    target.hasPrefix("pages:") || target.hasPrefix("look:") || target == "new-agent" || target == "settings"
}

/// The DEBUG levers read the argument domain; it never reaches the shared defaults on disk.
private func useLaunchArguments(open: String?, tab: String? = nil) {
    var values: [String: Any] = [
        addressKey: renderAddress ?? "",
        "schermes.debugPassword": renderPassword ?? "",
    ]
    if let open { values["schermes.debugOpen"] = open }
    if let tab { values[SettingsCategory.storageKey] = tab }
    UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
}

/// Without the launch password a 401 falls through to the Keychain, whose panel would come to the
/// front; without the address the owner's own daemon would be used.
private func checkedSession() throws -> Session {
    try #require(UserDefaults.standard.string(forKey: "schermes.debugPassword") == renderPassword)
    let session = Session()
    try #require(session.address == renderAddress)
    return session
}

private func makeWindow(
    size: CGSize, dark: Bool, chrome: Bool = true, @ViewBuilder content: () -> some View
) -> NSWindow {
    let style: NSWindow.StyleMask = chrome
        ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        : [.borderless]
    let window = OffscreenWindow(
        contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
        styleMask: style, backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let ground = Theme.window.rgb(dark: dark)
    window.backgroundColor = NSColor(srgbRed: ground.r, green: ground.g, blue: ground.b, alpha: 1)
    let host = NSHostingView(
        rootView: content()
            .environment(AgentLooks())
            .environment(Desktops())
            .environment(\.scenePhase, .active)
            .tint(Theme.ink)
    )
    host.sizingOptions = []
    host.frame = CGRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    let container = NSView(frame: host.frame)
    container.addSubview(host)
    window.contentView = container
    window.orderFrontRegardless()
    return window
}

/// A titled window is pulled back onto a screen and shrunk to fit, which sent the split view into
/// an endless constraints pass.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Data loads and the inspector's open and close animations take a few seconds; done once two
/// captures a second apart match.
private func settle(_ window: NSWindow, sheet: Bool = false) async throws {
    try await Task.sleep(for: .seconds(4))
    if sheet {
        for _ in 0..<20 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    var last = Data()
    for _ in 0..<10 {
        let frame = try #require(window.contentView?.superview)
        let now = try png(frame, ground: window.backgroundColor)
        if now == last { return }
        last = now
        try await Task.sleep(for: .seconds(1))
    }
}

/// The theme frame, so the traffic lights are in the picture; an attached sheet is saved beside it.
private func save(_ window: NSWindow, to url: URL) throws {
    let frame = try #require(window.contentView?.superview)
    try png(frame, ground: window.backgroundColor).write(to: url)
    try viewTree(frame).write(to: url.deletingPathExtension().appendingPathExtension("views.txt"), atomically: true, encoding: .utf8)
    if let sheet = window.attachedSheet, let sheetFrame = sheet.contentView?.superview {
        try png(sheetFrame, ground: sheet.backgroundColor).write(to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
        try viewTree(sheetFrame).write(to: url.deletingPathExtension().appendingPathExtension("sheet.views.txt"), atomically: true, encoding: .utf8)
    }
}

/// What draws where, for a column that comes out black: `cacheDisplay` can't see what the window
/// server composites (glass, backdrop materials).
private func viewTree(_ view: NSView, depth: Int = 0) -> String {
    let frame = view.convert(view.bounds, to: nil).integral
    var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame)"
    if let layer = view.layer {
        line += " layer=\(type(of: layer))"
        if let color = layer.backgroundColor { line += " bg=\(color)" }
    }
    if view.isHidden { line += " hidden" }
    return ([line] + view.subviews.map { viewTree($0, depth: depth + 1) }).joined(separator: "\n")
}

/// `cacheDisplay` leaves out what the window server draws: the window background (`Theme.window`
/// via `containerBackground`) and the `NSGlassEffectView` that holds the macOS 26 sidebar and
/// inspector columns, whose scroll view comes out empty. So the picture starts from the ground and
/// each glass view's content and SwiftUI clip views are drawn again on top. The glass's own tint
/// and blur are not in it, and anything floating over a clip view inside the glass lands under it.
private func png(_ view: NSView, ground: NSColor) throws -> Data {
    let shot = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: shot)
    let out = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    let layers = descendants(of: view).compactMap { $0 as? NSGlassEffectView }.flatMap { glass in
        glass.subviews.flatMap(\.subviews) + descendants(of: glass).filter {
            $0 is NSClipView && "\(type(of: $0))".contains("Hosting")
        }
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    ground.setFill()
    view.bounds.fill()
    over(shot, in: view.bounds)
    for layer in layers {
        guard let inner = layer.bitmapImageRepForCachingDisplay(in: layer.bounds) else { continue }
        layer.cacheDisplay(in: layer.bounds, to: inner)
        over(inner, in: layer.convert(layer.bounds, to: view))
    }
    NSGraphicsContext.restoreGraphicsState()
    return try #require(out.representation(using: .png, properties: [:]))
}

private func over(_ rep: NSBitmapImageRep, in rect: CGRect) {
    rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

/// The host shares the owner's bundle id, so whatever the renders wrote (split widths, last seen)
/// goes back to what it was.
private func restoreChangedKeys(domain: String, before: [String: Any], log: URL) {
    let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    let changed = Set(before.keys).union(after.keys).filter {
        !((before[$0] as AnyObject?)?.isEqual(after[$0]) ?? (after[$0] == nil))
    }
    guard !changed.isEmpty else { return }
    UserDefaults.standard.setPersistentDomain(before, forName: domain)
    try? changed.sorted().joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
}
#endif
