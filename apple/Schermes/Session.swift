import Foundation
import Observation

/// `@Observable` rewrites stored properties, and its expansion cannot see `Self` in an
/// initializer, so the key lives out here.
private let addressKey = "schermes.serverAddress"

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
    var address: String = UserDefaults.standard.string(forKey: addressKey) ?? ""
    var trouble: String?

    func start() async {
        guard !address.isEmpty else {
            phase = .needsServer
            return
        }
        await connect()
    }

    /// A bare host is what people type, so a missing scheme is filled in rather than refused.
    static func parse(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    func connect() async {
        guard let url = Self.parse(address) else {
            trouble = SchermesError.badURL.errorDescription
            phase = .needsServer
            return
        }

        let client = SchermesClient(baseURL: url)
        phase = .connecting
        trouble = nil

        do {
            let health = try await client.health()
            self.client = client
            UserDefaults.standard.set(address, forKey: addressKey)

            if health.setupRequired {
                phase = .setup
                return
            }
            // The only way to know a session is still good is to spend it on a guarded route.
            _ = try await client.agents()
            phase = .ready
        } catch SchermesError.unauthorized {
            self.client = client
            UserDefaults.standard.set(address, forKey: addressKey)
            phase = await reLogin() ? .ready : .login
        } catch {
            trouble = error.localizedDescription
            phase = .needsServer
        }
    }

    /// Setup or login, whichever the daemon asked for. The password is kept so an expired session
    /// can be spent again without asking.
    func enter(password: String) async throws {
        guard let client else { throw SchermesError.badURL }
        if phase == .setup {
            try await client.setup(password: password)
        } else {
            try await client.login(password: password)
        }
        let daemon = client.baseURL
        Task.detached { Keychain.save(password, for: daemon) }
        phase = .ready
    }

    func logOut() async {
        try? await client?.logout()
        if let daemon = client?.baseURL {
            Task.detached { Keychain.clear(for: daemon) }
        }
        phase = .login
    }

    func forgetServer() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        client = nil
        phase = .needsServer
    }

    /// Every guarded call goes through here. A 401 spends the stored password once and retries
    /// once; anything else puts the login screen back. Auth routes never come through here —
    /// `POST /api/auth/login` answers 401 for a wrong password, and retrying that would loop.
    func run<T>(_ call: (SchermesClient) async throws -> T) async throws -> T {
        guard let client else { throw SchermesError.badURL }
        do {
            return try await call(client)
        } catch SchermesError.unauthorized {
            if await reLogin() {
                do { return try await call(client) } catch SchermesError.unauthorized {}
            }
            phase = .login
            throw SchermesError.unauthorized
        }
    }

    private func reLogin() async -> Bool {
        guard let client else { return false }
        // `SecItemCopyMatching` can block for as long as it likes — on a Mac the system may put
        // an authorisation panel in front of it, which an ad-hoc signed app re-signed by every
        // build will meet — so it never runs on the actor that draws the screen.
        return await Self.reLogin(client) { daemon in
            await Task.detached(priority: .userInitiated) { Keychain.read(for: daemon) }.value
        }
    }

    /// Spends the password stored for this client's own daemon and no other: after a switch of
    /// daemon, the new one's first 401 must not be answered with the old one's password.
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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(for daemon: URL) -> String? {
        var item = query(for: daemon)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear(for daemon: URL) {
        SecItemDelete(query(for: daemon) as CFDictionary)
    }
}
