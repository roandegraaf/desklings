import Foundation
import Observation

/// `@Observable` rewrites stored properties, and its expansion cannot see `Self` in an
/// initializer, so the key lives out here.
let addressKey = "schermes.serverAddress"

/// A test launch passes `-schermes.serverAddress`; storing it would repoint the owner's own copy,
/// which shares this bundle id and so this defaults domain.
private var addressFromLaunch: Bool {
    UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[addressKey] != nil
}

#if DEBUG
/// `-schermes.debugPassword` logs a test launch in without typing and without the Keychain, whose
/// read raises an authorisation panel for an app re-signed by every build.
private let launchPassword = UserDefaults.standard.string(forKey: "schermes.debugPassword")
#else
private let launchPassword: String? = nil
#endif

/// Where the owner password is kept between launches. The Keychain in the app; a test passes its
/// own, because the macOS test host is the owner's real app and its real Keychain items.
struct Credentials: Sendable {
    var read: @Sendable (URL) async -> String?
    var save: @Sendable (String, URL) -> Void
    var clear: @Sendable (URL) -> Void

    /// `SecItemCopyMatching` can block for as long as it likes — on a Mac the system may put an
    /// authorisation panel in front of it, which an ad-hoc signed app re-signed by every build
    /// will meet — so none of these run on the actor that draws the screen.
    static let keychain = Credentials(
        read: { daemon in await Task.detached(priority: .userInitiated) { Keychain.read(for: daemon) }.value },
        save: { password, daemon in Task.detached { Keychain.save(password, for: daemon) } },
        clear: { daemon in Task.detached { Keychain.clear(for: daemon) } }
    )
}

/// The one daemon this app talks to, and whether the owner is through the door yet. Owns the
/// server address, the stored password, and the single place a 401 is answered.
@Observable
final class Session {
    enum Phase {
        case connecting
        /// No usable daemon address yet. `trouble` says why, when there was an attempt.
        case needsServer
        /// The daemon has no owner, so the password typed next becomes it.
        case setup
        case login
        case ready
    }

    private(set) var phase: Phase = .connecting
    private(set) var client: SchermesClient?
    /// The APNs token this daemon has been told about, so a log out can take it back.
    var registeredDevice: String?
    var address: String = UserDefaults.standard.string(forKey: addressKey) ?? ""
    var trouble: String?

    enum Reachability: Equatable {
        case reachable
        case unreachable(since: Date, message: String)
    }

    /// Whether the last guarded call reached the daemon. Every call through `run` reports here, so
    /// every screen's banner reads one answer rather than each poll keeping its own.
    private(set) var reachability: Reachability = .reachable

    @ObservationIgnored private let credentials: Credentials
    @ObservationIgnored private let dropAddress: @MainActor () -> Void
    /// Bumped by a log out, a forget and a connect. A call that left under an older epoch writes
    /// nothing back when it lands: it ends as a cancellation, which every screen keeps quiet.
    @ObservationIgnored private var epoch = 0
    /// Bumped by every sign-in, so a 401 for a request sent before one is retried rather than
    /// answered with yet another login.
    @ObservationIgnored private var signIns = 0
    /// The one re-login in flight. Every 401 meanwhile waits for it: each wrong stored password
    /// would count toward the daemon's backoff and earn the owner a 429 at the login screen.
    @ObservationIgnored private var reLoginTask: Task<Bool, Never>?
    @ObservationIgnored private var naps: [UUID: (wake: CheckedContinuation<Void, Never>, timer: Task<Void, Never>)] = [:]
    @ObservationIgnored private let now: () -> Date

    init(
        credentials: Credentials = .keychain,
        dropAddress: @escaping @MainActor () -> Void = Session.dropStoredAddress,
        client: SchermesClient? = nil,
        phase: Phase = .connecting,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.credentials = credentials
        self.dropAddress = dropAddress
        self.client = client
        self.phase = phase
    }

    func start() async {
        guard !address.isEmpty else {
            phase = .needsServer
            return
        }
        await connect()
    }

    /// A bare host is what people type, so a missing scheme is filled in rather than refused:
    /// https for a domain, http for an IP, a single-label name or anything under .local.
    static func parse(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let scheme = isDomain(trimmed) ? "https" : "http"
        let text = trimmed.contains("://") ? trimmed : "\(scheme)://\(trimmed)"
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// Plain HTTP to anything but this device, where the password and the session cookie cross a
    /// network anyone on it can read.
    nonisolated static func isCleartext(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", var host = url.host()?.lowercased() else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host != "localhost" && host != "::1" && !host.hasPrefix("127.")
    }

    private static func isDomain(_ address: String) -> Bool {
        let host = address.split(whereSeparator: { $0 == ":" || $0 == "/" }).first ?? ""
        return host.contains(".") && !host.hasSuffix(".local") && host.contains { $0.isLetter }
    }

    func connect() async {
        guard let url = Self.parse(address) else {
            trouble = SchermesError.badURL.errorDescription
            phase = .needsServer
            return
        }

        let client = SchermesClient(baseURL: url)
        epoch += 1
        phase = .connecting
        trouble = nil
        setReachability(.reachable)

        do {
            let health = try await client.health()
            self.client = client
            storeAddress(url)

            if health.setupRequired {
                phase = .setup
                return
            }
            // The only way to know a session is still good is to spend it on a guarded route.
            _ = try await client.agents()
            phase = .ready
        } catch SchermesError.unauthorized {
            self.client = client
            storeAddress(url)
            phase = await reLogin(after: signIns) ? .ready : .login
        } catch {
            trouble = error.localizedDescription
            phase = .needsServer
        }
    }

    /// Setup or login, whichever the daemon asked for. Setup sends the code from the daemon's log;
    /// a login sends the authenticator code or a recovery code once the daemon has asked for one
    /// (`SchermesError.totpRequired`). The password is kept so an expired session can be spent
    /// again without asking.
    func enter(password: String, setupToken: String = "", totp: String? = nil, recoveryCode: String? = nil) async throws {
        guard let client else { throw SchermesError.badURL }
        let started = epoch
        if phase == .setup {
            try await client.setup(password: password, setupToken: Self.typedCode(setupToken) ?? "")
        } else {
            try await client.login(password: password, totp: Self.typedCode(totp), recoveryCode: Self.typedCode(recoveryCode))
        }
        try current(started)
        credentials.save(password, client.baseURL)
        signIns += 1
        phase = .ready
    }

    /// Codes arrive pasted out of a log or an authenticator app, with spaces around them.
    private static func typedCode(_ code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The screen changes first and the daemon hears about it after, best effort: a log out is
    /// often pressed because the daemon is unreachable, and waiting on it would freeze the window.
    /// The device comes off the push list before the session goes, since that route needs it.
    @discardableResult
    func logOut() -> Task<Void, Never> {
        epoch += 1
        reLoginTask?.cancel()
        reLoginTask = nil
        let client = client
        let device = registeredDevice
        registeredDevice = nil
        phase = .login
        setReachability(.reachable)
        if let client { credentials.clear(client.baseURL) }
        return Task { await Self.signOut(client, device: device) }
    }

    /// The new password replaces the stored one only once the daemon took it, so the silent
    /// re-login keeps working. Answers how many other sessions were signed out.
    func changePassword(current: String, next: String) async throws -> Int {
        let changed = try await run { try await $0.changePassword(current: current, next: next) }
        if let client { credentials.save(next, client.baseURL) }
        return changed.signedOut
    }

    /// This app's own session goes through `logOut()`, which takes the device off the push list
    /// while the session can still do it, then ends that same session.
    func revoke(_ entry: SessionEntry) async throws {
        if entry.current {
            await logOut().value
            return
        }
        try await run { try await $0.revokeSession(handle: entry.handle) }
    }

    private static func signOut(_ client: SchermesClient?, device: String?) async {
        guard let client else { return }
        if let device { try? await client.unregisterDevice(token: device) }
        try? await client.logout()
    }

    /// Logs out of this daemon, then forgets its address: no push to this device, no stored
    /// password, no session left behind for the next owner of the address.
    @discardableResult
    func forgetServer() -> Task<Void, Never> {
        let signedOut = logOut()
        dropAddress()
        client = nil
        phase = .needsServer
        return signedOut
    }

    static func dropStoredAddress() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        StoredDaemon.sharedDefaults.removeObject(forKey: addressKey)
    }

    /// The iPhone's share extension has no `Session`: it reads the address and a copy of the
    /// password from the app group. Refreshed on every connect, so an upgraded install catches up.
    private func storeAddress(_ daemon: URL) {
        guard !addressFromLaunch else { return }
        UserDefaults.standard.set(address, forKey: addressKey)
        #if os(iOS)
        StoredDaemon.sharedDefaults.set(address, forKey: addressKey)
        Task.detached { Keychain.shareWithExtension(for: daemon) }
        #endif
    }

    private func current(_ started: Int) throws {
        if epoch != started { throw CancellationError() }
    }

    /// Every guarded call goes through here. A 401 spends the stored password once and retries
    /// once; anything else puts the login screen back. Auth routes never come through here —
    /// `POST /api/auth/login` answers 401 for a wrong password, and retrying that would loop.
    /// A call that lands after a log out or a forget throws `CancellationError` instead of
    /// answering, and never signs back in.
    func run<T>(_ call: (SchermesClient) async throws -> T) async throws -> T {
        guard let client else { throw SchermesError.badURL }
        let started = epoch
        let signedIn = signIns
        do {
            let value = try await call(client)
            try current(started)
            reached()
            return value
        } catch SchermesError.unauthorized {
            try current(started)
            reached()
            if await reLogin(after: signedIn) {
                try current(started)
                do {
                    let value = try await call(client)
                    try current(started)
                    return value
                } catch SchermesError.unauthorized {}
            }
            try current(started)
            phase = .login
            throw SchermesError.unauthorized
        } catch {
            try current(started)
            if error.isUnreachable {
                missed(error)
            } else if !error.isCancellation {
                reached()
            }
            throw error
        }
    }

    /// What a poll should show on its own screen for a failure, if anything: a cancellation is
    /// nobody's news, and an unreachable daemon is already the banner's.
    func complaint(about error: any Error) -> String? {
        error.isCancellation || error.isUnreachable ? nil : error.localizedDescription
    }

    /// The banner's Retry now: every poll asleep in `nap` runs at once.
    func retryNow() {
        let sleeping = naps.values
        naps = [:]
        for nap in sleeping {
            nap.timer.cancel()
            nap.wake.resume()
        }
    }

    /// A poll's wait between runs. Cut short by `retryNow`, by the daemon coming back (a poll
    /// backed off to a minute must not sit stale once another one got through), and by
    /// cancellation.
    func nap(for duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake in
                if Task.isCancelled { return wake.resume() }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.wake(id)
                }
                naps[id] = (wake, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        guard let nap = naps.removeValue(forKey: id) else { return }
        nap.timer.cancel()
        nap.wake.resume()
    }

    private func reached() {
        guard reachability != .reachable else { return }
        setReachability(.reachable)
        retryNow()
    }

    private func missed(_ error: any Error) {
        let message = error.localizedDescription
        if case .unreachable(let since, let shown) = reachability {
            if shown != message { setReachability(.unreachable(since: since, message: message)) }
        } else {
            setReachability(.unreachable(since: now(), message: message))
        }
    }

    private func setReachability(_ next: Reachability) {
        if reachability != next { reachability = next }
    }

    private func reLogin(after signedIn: Int) async -> Bool {
        if signIns != signedIn { return true }
        if let reLoginTask { return await reLoginTask.value }
        guard let client else { return false }
        let started = epoch
        let read = credentials.read
        let task = Task {
            await Self.reLogin(client) { daemon in
                if let launchPassword { return launchPassword }
                return await read(daemon)
            }
        }
        reLoginTask = task
        let loggedIn = await task.value
        if reLoginTask == task { reLoginTask = nil }
        guard loggedIn else { return false }
        guard epoch == started else {
            // Signed out while the login was on its way: the session it made must not outlive that.
            Task { try? await client.logout() }
            return false
        }
        signIns += 1
        return true
    }

    /// Spends the password stored for this client's own daemon and no other: after a switch of
    /// daemon, the new one's first 401 must not be answered with the old one's password. With TOTP
    /// on this fails, since a stored password is only half a login.
    static func reLogin(_ client: SchermesClient, stored: (URL) async -> String?) async -> Bool {
        guard let password = await stored(client.baseURL) else { return false }
        do {
            try await client.login(password: password)
            return true
        } catch {
            return false
        }
    }
}

extension Session.Phase: Equatable {}

/// The owner password, so an expired cookie is replaced without asking for it again. Nonisolated
/// because these are blocking system calls that must be free to run off the main actor.
nonisolated enum Keychain {
    private static let service = "dev.schermes.owner"
    /// Never in a backup restored onto another device.
    private static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// One item per daemon, named by the address its login goes to, so a password is only ever
    /// sent back to the daemon it was set on.
    static func query(for daemon: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: daemon.absoluteString,
        ]
    }

    static func save(_ password: String, for daemon: URL) {
        clear(for: daemon)
        // The one unscoped item earlier builds kept. Dropped here, when the owner has just typed a
        // password, rather than at launch: the macOS test run launches the app too.
        var unscoped = query(for: daemon)
        unscoped[kSecAttrAccount as String] = "password"
        SecItemDelete(unscoped as CFDictionary)

        var item = query(for: daemon)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = accessible
        SecItemAdd(item as CFDictionary, nil)
        #if os(iOS)
        item[kSecAttrAccessGroup as String] = appGroup
        SecItemAdd(item as CFDictionary, nil)
        #endif
    }

    #if os(iOS)
    /// A second copy in the app group for the share extension, added beside the app's own and never
    /// in its place, so a re-login running meanwhile always finds one. `clear` takes both. Without
    /// the group entitlement (simulator builds) the add fails and nothing changes.
    static func shareWithExtension(for daemon: URL) {
        guard let password = read(for: daemon) else { return }
        var item = query(for: daemon)
        item[kSecAttrAccessGroup as String] = appGroup
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = accessible
        SecItemAdd(item as CFDictionary, nil)
    }
    #endif

    static func read(for daemon: URL) -> String? {
        var item = query(for: daemon)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        #if os(iOS)
        // Items saved by earlier builds keep the class they were added with until updated. The
        // Mac's file-based keychain ignores the class, and changing an item there can prompt.
        SecItemUpdate(query(for: daemon) as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
        #endif
        return String(data: data, encoding: .utf8)
    }

    static func clear(for daemon: URL) {
        SecItemDelete(query(for: daemon) as CFDictionary)
    }
}
