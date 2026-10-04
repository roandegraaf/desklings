import CryptoKit
import Foundation
import Testing
@testable import Schermes

/// The session's sign-in, re-login, log out and forget paths against a canned daemon. Nothing here
/// touches the Keychain or the defaults: the macOS test host is the owner's real app. The canned
/// daemon and the vault are shared with `AccountTests.swift`.

struct Recorded: Sendable {
    var method: String
    var path: String
    var body: [String: String]
    var query: String? = nil
    var headers: [String: String] = [:]
}

struct Canned: Sendable {
    var status: Int = 200
    var json: String = #"{"ok":true}"#
    var headers: [String: String] = [:]
    /// The request never reaches the daemon: the network fails with this.
    var failure: URLError.Code? = nil
}

/// Every test gets a host of its own, so tests running side by side never share a script.
nonisolated final class Daemon: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: @Sendable (Recorded) -> Canned
    private var log: [Recorded] = []
    let host = "\(UUID().uuidString.lowercased()).test"

    init(_ answer: @escaping @Sendable (Recorded) -> Canned = { _ in Canned() }) {
        self.answer = answer
        Daemon.register(self)
    }

    var requests: [Recorded] { lock.withLock { log } }

    func answer(_ request: Recorded) -> Canned {
        let respond = lock.withLock {
            log.append(request)
            return answer
        }
        return respond(request)
    }

    func script(_ next: @escaping @Sendable (Recorded) -> Canned) {
        lock.withLock { answer = next }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Daemon] = [:]

    static func register(_ daemon: Daemon) {
        registryLock.withLock { registry[daemon.host] = daemon }
    }

    static func find(_ host: String?) -> Daemon? {
        registryLock.withLock { host.flatMap { registry[$0] } }
    }
}

nonisolated final class CannedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let daemon = Daemon.find(url.host()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET", path: url.path(), body: Self.body(of: request), query: url.query(),
            headers: request.allHTTPHeaderFields ?? [:]
        )
        let canned = daemon.answer(recorded)
        if let failure = canned.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

let canned: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CannedProtocol.self]
    return URLSession(configuration: config)
}()

nonisolated final class Vault: @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    private var _saved: [String] = []
    private var _cleared: [URL] = []
    let password: String?
    let beforeRead: @Sendable () async -> Void

    init(password: String? = "stored-password", beforeRead: @escaping @Sendable () async -> Void = {}) {
        self.password = password
        self.beforeRead = beforeRead
    }

    var reads: Int { lock.withLock { _reads } }
    var saved: [String] { lock.withLock { _saved } }
    var cleared: [URL] { lock.withLock { _cleared } }

    var credentials: Credentials {
        Credentials(
            read: { _ in
                self.lock.withLock { self._reads += 1 }
                await self.beforeRead()
                return self.password
            },
            save: { password, _ in self.lock.withLock { self._saved.append(password) } },
            clear: { daemon in self.lock.withLock { self._cleared.append(daemon) } }
        )
    }
}

func session(_ daemon: Daemon, _ vault: Vault, phase: Session.Phase, dropAddress: @escaping @MainActor () -> Void = {}) -> Session {
    let client = SchermesClient(baseURL: URL(string: "http://\(daemon.host)")!, urlSession: canned)
    return Session(credentials: vault.credentials, dropAddress: dropAddress, client: client, phase: phase)
}

private final class Tally {
    var count = 0
}

/// Opens once `count` callers have arrived.
private actor Turnstile {
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let count: Int

    init(_ count: Int) { self.count = count }

    func arrive() {
        arrived += 1
        if arrived >= count {
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    func wait() async {
        if arrived >= count { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

// MARK: - Setup and login

@Test func setupSendsTheCodeFromTheDaemonLog() async throws {
    let daemon = Daemon { _ in Canned(status: 201) }
    let vault = Vault()
    let session = session(daemon, vault, phase: .setup)

    try await session.enter(password: "a long password", setupToken: "  3f9c-77ab \n")

    #expect(daemon.requests.map(\.path) == ["/api/auth/setup"])
    #expect(daemon.requests.first?.body == ["password": "a long password", "setupToken": "3f9c-77ab"])
    #expect(session.phase == .ready)
    #expect(vault.saved == ["a long password"])
}

@Test func aWrongSetupCodeShowsTheDaemonsWords() async throws {
    let refusal = "setup token required: it is printed in the daemon log"
    let daemon = Daemon { _ in Canned(status: 403, json: #"{"error":"\#(refusal)"}"#) }
    let session = session(daemon, Vault(), phase: .setup)

    await #expect {
        try await session.enter(password: "a long password", setupToken: "nope")
    } throws: { $0.localizedDescription == refusal }
    #expect(session.phase == .setup)
}

@Test func aWrongPasswordSaysSoRatherThanThatTheSessionExpired() async throws {
    let daemon = Daemon { _ in Canned(status: 401, json: #"{"error":"invalid password"}"#) }
    let session = session(daemon, Vault(), phase: .login)

    await #expect {
        try await session.enter(password: "wrong")
    } throws: { $0.localizedDescription == "invalid password" }
    #expect(session.phase == .login)
}

@Test func withTotpOnThePasswordAloneAsksForTheCode() async throws {
    let daemon = Daemon { request in
        request.body["totp"] == "123456"
            ? Canned()
            : Canned(status: 401, json: #"{"error":"enter the code from your authenticator app","totpRequired":true}"#)
    }
    let vault = Vault()
    let session = session(daemon, vault, phase: .login)

    do {
        try await session.enter(password: "pw")
        Issue.record("the password alone signed in")
    } catch SchermesError.totpRequired(let message) {
        #expect(message == "enter the code from your authenticator app")
    }
    #expect(session.phase == .login)
    #expect(vault.saved.isEmpty)

    try await session.enter(password: "pw", totp: " 123456 ")
    #expect(daemon.requests.last?.body == ["password": "pw", "totp": "123456"])
    #expect(session.phase == .ready)
    #expect(vault.saved == ["pw"])
}

@Test func aRecoveryCodeSignsInInsteadOfTheAuthenticatorCode() async throws {
    let daemon = Daemon { request in
        request.body["recoveryCode"] == "abcd-efgh-ijkl-mnop"
            ? Canned()
            : Canned(status: 401, json: #"{"error":"invalid code","totpRequired":true}"#)
    }
    let session = session(daemon, Vault(), phase: .login)

    await #expect {
        try await session.enter(password: "pw", recoveryCode: "wrong-code")
    } throws: { $0.localizedDescription == "invalid code" }

    try await session.enter(password: "pw", recoveryCode: "abcd-efgh-ijkl-mnop")
    #expect(daemon.requests.last?.body == ["password": "pw", "recoveryCode": "abcd-efgh-ijkl-mnop"])
    #expect(session.phase == .ready)
}

@Test func theBackoffCarriesItsWait() async throws {
    let daemon = Daemon { _ in
        Canned(status: 429, json: #"{"error":"too many failed attempts, try again in 7 s"}"#, headers: ["Retry-After": "7"])
    }
    let session = session(daemon, Vault(), phase: .login)

    do {
        try await session.enter(password: "pw")
        Issue.record("a 429 signed in")
    } catch SchermesError.tooManyAttempts(let wait, let message) {
        #expect(wait == 7)
        #expect(message == "too many failed attempts, try again in 7 s")
    }
}

// MARK: - One re-login in flight

@Test func concurrentExpiredCallsShareOneReLogin() async throws {
    let daemon = Daemon()
    let failed = Turnstile(3)
    let vault = Vault(beforeRead: { await failed.wait() })
    let session = session(daemon, vault, phase: .ready)

    func call(_ name: String) async throws -> String {
        var tried = false
        return try await session.run { _ in
            if !tried {
                tried = true
                await failed.arrive()
                throw SchermesError.unauthorized
            }
            return name
        }
    }

    async let a = call("a")
    async let b = call("b")
    async let c = call("c")
    let answers = try await [a, b, c]

    #expect(answers == ["a", "b", "c"])
    #expect(vault.reads == 1)
    #expect(daemon.requests.filter { $0.path == "/api/auth/login" }.count == 1)
    #expect(session.phase == .ready)
}

@Test func aLate401AfterAReLoginRetriesWithoutAnother() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let session = session(daemon, vault, phase: .ready)
    let reLoggedIn = Turnstile(1)
    let slowSent = Turnstile(1)

    let slow = Task {
        var tried = false
        return try await session.run { _ in
            if !tried {
                tried = true
                await slowSent.arrive()
                await reLoggedIn.wait()
                throw SchermesError.unauthorized
            }
            return "slow"
        }
    }

    await slowSent.wait()
    var tried = false
    let fast: String = try await session.run { _ in
        if !tried {
            tried = true
            throw SchermesError.unauthorized
        }
        return "fast"
    }
    await reLoggedIn.arrive()

    #expect(fast == "fast")
    #expect(try await slow.value == "slow")
    #expect(daemon.requests.filter { $0.path == "/api/auth/login" }.count == 1)
}

// MARK: - The logout race

@Test func aPollThatLandsAfterLogOutWritesNothingBack() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let session = session(daemon, vault, phase: .ready)
    let inFlight = Turnstile(1)
    let landed = Turnstile(1)

    let poll = Task {
        try await session.run { _ in
            await inFlight.arrive()
            await landed.wait()
            return ["agent"]
        }
    }
    await inFlight.wait()
    await session.logOut().value
    await landed.arrive()

    await #expect(throws: CancellationError.self) { try await poll.value }
    #expect(session.phase == .login)
}

@Test func a401ThatLandsAfterLogOutNeverSignsBackIn() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let session = session(daemon, vault, phase: .ready)
    let inFlight = Turnstile(1)
    let landed = Turnstile(1)

    let poll = Task {
        try await session.run { _ -> [String] in
            await inFlight.arrive()
            await landed.wait()
            throw SchermesError.unauthorized
        }
    }
    await inFlight.wait()
    await session.logOut().value
    await landed.arrive()

    await #expect(throws: CancellationError.self) { try await poll.value }
    #expect(vault.reads == 0)
    #expect(!daemon.requests.contains { $0.path == "/api/auth/login" })
    #expect(session.phase == .login)
}

@Test func logOutTakesTheDeviceOffThenEndsTheSession() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let session = session(daemon, vault, phase: .ready)
    session.registeredDevice = "ab12cd"

    let signingOut = session.logOut()
    #expect(session.phase == .login)
    #expect(session.registeredDevice == nil)
    await signingOut.value

    #expect(daemon.requests.map { "\($0.method) \($0.path)" } == ["DELETE /api/devices/ab12cd", "POST /api/auth/logout"])
    #expect(vault.cleared.map(\.host) == [daemon.host])
}

// MARK: - Forget server

@Test func forgetServerUnregistersPushAndClearsTheStoredPassword() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let dropped = Tally()
    let session = session(daemon, vault, phase: .ready) { dropped.count += 1 }
    session.registeredDevice = "feed42"

    let signingOut = session.forgetServer()
    #expect(session.phase == .needsServer)
    #expect(session.client == nil)
    #expect(dropped.count == 1)
    #expect(vault.cleared.map(\.host) == [daemon.host])
    await signingOut.value

    #expect(daemon.requests.map { "\($0.method) \($0.path)" } == ["DELETE /api/devices/feed42", "POST /api/auth/logout"])
}

@Test func forgetServerDoesNotWaitForAnUnreachableDaemon() async throws {
    let daemon = Daemon { _ in Canned(status: 502, json: "bad gateway") }
    let session = session(daemon, Vault(), phase: .login)
    session.registeredDevice = "feed42"

    let signingOut = session.forgetServer()
    #expect(session.phase == .needsServer)
    await signingOut.value
}

// MARK: - Callers with no window

@Test func aCallerWithNoWindowIsSentToTheAppWhenTheStoredPasswordCannotSignIn() async throws {
    let daemon = Daemon { request in
        request.path == "/api/auth/login"
            ? Canned(status: 401, json: #"{"error":"enter the code from your authenticator app","totpRequired":true}"#)
            : Canned(status: 401, json: #"{"error":"unauthorized"}"#)
    }
    let client = SchermesClient(baseURL: URL(string: "http://\(daemon.host)")!, urlSession: canned)

    await #expect {
        try await StoredDaemon.run(client, credentials: Vault().credentials) { _ = try await $0.agents() }
    } throws: { error in
        guard case SchermesError.signInInApp = error else { return false }
        return error.localizedDescription == "Open Schermes and sign in again."
    }
    #expect(daemon.requests.map(\.path) == ["/api/agents", "/api/auth/login"])
}

// MARK: - Against a real daemon

nonisolated private let liveAddress = ProcessInfo.processInfo.environment["SCHERMES_LIVE_AUTH_ADDRESS"]
nonisolated private let liveSetupCode = ProcessInfo.processInfo.environment["SCHERMES_LIVE_AUTH_CODE"]

/// RFC 6238 with the daemon's parameters: HMAC-SHA-1, 30 s steps, 6 digits.
private func totp(secret: String, step: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var bits = 0, value = 0
    var key = [UInt8]()
    for char in secret.uppercased() where char != "=" {
        guard let index = alphabet.firstIndex(of: char) else { continue }
        value = (value << 5) | index
        bits += 5
        if bits >= 8 {
            key.append(UInt8((value >> (bits - 8)) & 0xff))
            bits -= 8
        }
    }
    var counter = UInt64(step).bigEndian
    let message = Data(bytes: &counter, count: 8)
    let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    let offset = Int(mac[mac.count - 1] & 0x0f)
    let number = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    return String(format: "%06d", number % 1_000_000)
}

/// `TEST_RUNNER_SCHERMES_LIVE_AUTH_ADDRESS` and `_CODE` point it at a fresh daemon and the setup
/// code from its log. Claims it, changes the password, revokes a second client's session, turns
/// TOTP on through the app's client, signs in with a code and with a recovery code, then turns it
/// off with another recovery code.
@Test(.enabled(if: liveAddress != nil && liveSetupCode != nil))
func aFreshDaemonIsClaimedAndSignedIntoWithTotpFromTheApp() async throws {
    let base = try #require(liveAddress.flatMap(Session.parse))
    let password = "live test password"
    let changed = "changed live password"
    func fresh(_ phase: Session.Phase, vault: Vault = Vault()) -> Session {
        let client = SchermesClient(baseURL: base, urlSession: URLSession(configuration: .ephemeral))
        return Session(credentials: vault.credentials, dropAddress: {}, client: client, phase: phase)
    }

    let ownerVault = Vault()
    let owner = fresh(.setup, vault: ownerVault)
    await #expect {
        try await owner.enter(password: password, setupToken: "not-the-code")
    } throws: { $0.localizedDescription == "setup token required: it is printed in the daemon log" }
    try await owner.enter(password: password, setupToken: " \(try #require(liveSetupCode)) ")
    #expect(owner.phase == .ready)

    await #expect {
        _ = try await owner.changePassword(current: "not the password", next: changed)
    } throws: { $0.localizedDescription == "the current password is wrong" }
    #expect(owner.phase == .ready)
    #expect(try await owner.changePassword(current: password, next: changed) == 0)
    #expect(ownerVault.saved == [password, changed])

    let second = fresh(.login, vault: Vault(password: nil))
    try await second.enter(password: changed)
    let listed = try await owner.run { try await $0.sessions() }
    #expect(listed.count == 2 && listed.filter(\.current).count == 1)
    let other = try #require(listed.first { !$0.current })
    try await owner.revoke(other)
    await #expect(throws: SchermesError.self) { _ = try await second.run { try await $0.agents() } }
    #expect(second.phase == .login)
    #expect(try await owner.run { try await $0.sessions() }.count == 1)

    let enrolled = try await owner.run { try await $0.setupTotp(password: changed) }
    #expect(enrolled.uri.hasPrefix("otpauth://totp/") && qrCode(enrolled.uri) != nil)
    let step = Int(Date().timeIntervalSince1970) / 30
    let codes = try await owner.run { try await $0.confirmTotp(code: totp(secret: enrolled.secret, step: step)) }.recoveryCodes
    #expect(codes.count == 10)
    #expect(try await owner.run { try await $0.totpStatus() } == TotpStatus(enabled: true, pending: false, recoveryCodesLeft: 10))

    let withCode = fresh(.login)
    do {
        try await withCode.enter(password: changed)
        Issue.record("the password alone signed in with TOTP on")
    } catch SchermesError.totpRequired {}
    try await withCode.enter(password: changed, totp: totp(secret: enrolled.secret, step: step + 1))
    #expect(withCode.phase == .ready)
    _ = try await withCode.run { try await $0.agents() }

    let withRecovery = fresh(.login)
    try await withRecovery.enter(password: changed, recoveryCode: codes[0])
    #expect(withRecovery.phase == .ready)
    _ = try await withRecovery.run { try await $0.agents() }

    try await owner.run { try await $0.disableTotp(password: changed, recoveryCode: codes[1]) }
    #expect(try await owner.run { try await $0.totpStatus() }.enabled == false)

    let audit = try await owner.run { try await $0.audit(limit: 50) }
    let actions = Set(audit.map(\.action))
    #expect(actions.isSuperset(of: [.setup, .password_changed, .password_change_failed, .session_revoked, .totp_enabled, .recovery_code_used, .totp_disabled]))
    let older = try await owner.run { try await $0.audit(before: try #require(audit.first?.id), limit: 2) }
    #expect(older.count == 2 && older.allSatisfy { $0.id < audit[0].id })
}
