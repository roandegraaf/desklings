import Foundation
import Testing
@testable import Schermes

/// The account routes, the general settings and the model capabilities: fixtures for every body
/// the daemon sends, the exact requests the client makes against the canned daemon from
/// `SessionTests.swift`, and the session's password and revoke paths.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func encoded(_ value: some Encodable) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
}

private func client(_ daemon: Daemon) -> SchermesClient {
    SchermesClient(baseURL: URL(string: "http://\(daemon.host)")!, urlSession: canned)
}

// MARK: - Wire fixtures

@Test func theSessionListDecodesWithAndWithoutAUserAgent() throws {
    let list = try decode([SessionEntry].self, """
    [{"handle":"Ab3_-xYz0123456Q","createdAt":1759400000000,"lastSeenAt":1759490000000,"userAgent":"Schermes/1 CFNetwork","current":true},
     {"handle":"zz","createdAt":1759300000000,"lastSeenAt":null,"userAgent":null,"current":false}]
    """)
    #expect(list.map(\.handle) == ["Ab3_-xYz0123456Q", "zz"])
    #expect(list[0].current && list[0].lastSeenAt == 1_759_490_000_000)
    #expect(list[1].userAgent == nil && list[1].lastSeenAt == nil && !list[1].current)
}

@Test func theTotpBodiesDecode() throws {
    #expect(try decode(TotpStatus.self, #"{"enabled":true,"pending":false,"recoveryCodesLeft":9}"#)
        == TotpStatus(enabled: true, pending: false, recoveryCodesLeft: 9))
    let setup = try decode(TotpSetup.self, #"{"secret":"JBSWY3DPEHPK3PXP","uri":"otpauth://totp/Schermes:owner?secret=JBSWY3DPEHPK3PXP&issuer=Schermes"}"#)
    #expect(setup.secret == "JBSWY3DPEHPK3PXP" && setup.uri.hasPrefix("otpauth://totp/"))
    let confirmed = try decode(TotpConfirmed.self, #"{"recoveryCodes":["abcd-efgh-ijkl-mnop","qrst-uvwx-yz23-4567"]}"#)
    #expect(confirmed.recoveryCodes.count == 2)
    #expect(try decode(PasswordChanged.self, #"{"ok":true,"signedOut":3}"#).signedOut == 3)
}

@Test func anAuditPageDecodesItsDetailAndToleratesANewAction() throws {
    let page = try decode([AuditEvent].self, """
    [{"id":12,"at":1759490000000,"action":"settings_changed","ip":"192.168.1.20","userAgent":"Schermes/1",
      "detail":{"method":"PUT","path":"/api/settings","fields":["timezone","imageRetentionDays"]}},
     {"id":11,"at":1759480000000,"action":"login_failed","ip":null,"userAgent":null,"detail":{"reason":"password"}},
     {"id":10,"at":1759470000000,"action":"passkey_added","ip":"10.0.0.2","userAgent":null,"detail":null},
     {"id":9,"at":1759460000000,"action":"recovery_code_used","ip":"10.0.0.2","userAgent":"curl/8","detail":{"left":9}},
     {"id":8,"at":1759450000000,"action":"session_revoked","ip":"10.0.0.2","userAgent":null,"detail":{"handle":"Ab3","own":false}}]
    """)
    #expect(page.map(\.action) == [.settings_changed, .login_failed, .unknown, .recovery_code_used, .session_revoked])
    #expect(page[0].detailLine == "fields: timezone, imageRetentionDays · method: PUT · path: /api/settings")
    #expect(page[0].origin == "192.168.1.20 · Schermes/1")
    #expect(page[1].detailLine == "reason: password" && page[1].origin == nil && page[1].action.isRefusal)
    #expect(page[2].detailLine == nil && page[2].action.title == "Something this app does not know yet")
    #expect(page[3].detailLine == "left: 9")
    #expect(page[4].detailLine == "handle: Ab3 · own: no")
}

@Test func theAuditLogPagesFromTheOldestShownAndStopsOnAShortPage() {
    func event(_ id: Int) -> AuditEvent {
        AuditEvent(id: id, at: id * 1000, action: .login, ip: nil, userAgent: nil, detail: nil)
    }
    var log = AuditLog()
    #expect(log.oldest == nil && !log.exhausted)

    log.append((26...50).reversed().map(event), asked: 25)
    #expect(log.events.count == 25 && log.oldest == 26 && !log.exhausted)

    // An event written between two pages shifts nothing, and one seen twice is not shown twice.
    log.append([event(26)] + (20...25).reversed().map(event), asked: 25)
    #expect(log.events.map(\.id) == Array((20...50).reversed()))
    #expect(log.oldest == 20 && log.exhausted)
}

// MARK: - Requests

@Test func theAccountCallsAskTheRoutesTheDaemonServes() async throws {
    let daemon = Daemon { request in
        switch (request.method, request.path) {
        case ("POST", "/api/auth/password"): Canned(json: #"{"ok":true,"signedOut":2}"#)
        case ("GET", "/api/auth/sessions"): Canned(json: "[]")
        case ("GET", "/api/auth/totp"): Canned(json: #"{"enabled":false,"pending":false,"recoveryCodesLeft":0}"#)
        case ("POST", "/api/auth/totp/setup"): Canned(json: #"{"secret":"S","uri":"otpauth://totp/x?secret=S"}"#)
        case ("POST", "/api/auth/totp/confirm"): Canned(json: #"{"recoveryCodes":["a"]}"#)
        case ("GET", "/api/audit"): Canned(json: "[]")
        default: Canned()
        }
    }
    let api = client(daemon)

    #expect(try await api.changePassword(current: "old password", next: "new password").signedOut == 2)
    _ = try await api.sessions()
    try await api.revokeSession(handle: "Ab3_-xYz0123456Q")
    _ = try await api.totpStatus()
    _ = try await api.setupTotp(password: "pw")
    _ = try await api.confirmTotp(code: "123456")
    try await api.disableTotp(password: "pw", code: "654321")
    try await api.disableTotp(password: "pw", recoveryCode: "abcd-efgh-ijkl-mnop")
    _ = try await api.audit(limit: 25)
    _ = try await api.audit(before: 40, limit: 25)

    let sent = daemon.requests
    #expect(sent.map { "\($0.method) \($0.path)" } == [
        "POST /api/auth/password",
        "GET /api/auth/sessions",
        // The handle's upper case goes out as itself: the daemon compares it byte for byte.
        "DELETE /api/auth/sessions/Ab3_-xYz0123456Q",
        "GET /api/auth/totp",
        "POST /api/auth/totp/setup",
        "POST /api/auth/totp/confirm",
        "DELETE /api/auth/totp",
        "DELETE /api/auth/totp",
        "GET /api/audit",
        "GET /api/audit",
    ])
    #expect(sent[0].body == ["current": "old password", "next": "new password"])
    #expect(sent[4].body == ["password": "pw"])
    #expect(sent[5].body == ["code": "123456"])
    #expect(sent[6].body == ["password": "pw", "code": "654321"])
    #expect(sent[7].body == ["password": "pw", "recoveryCode": "abcd-efgh-ijkl-mnop"])
    #expect(sent[8].query == "limit=25")
    #expect(sent[9].query == "before=40&limit=25")
}

// MARK: - Session

@Test func aChangedPasswordReplacesTheStoredOne() async throws {
    let daemon = Daemon { _ in Canned(json: #"{"ok":true,"signedOut":1}"#) }
    let vault = Vault()
    let owner = session(daemon, vault, phase: .ready)

    #expect(try await owner.changePassword(current: "stored-password", next: "a new password") == 1)
    #expect(vault.saved == ["a new password"])
    #expect(owner.phase == .ready)
}

/// A wrong current password is a 403: shown as the daemon put it, nothing stored, still signed in.
@Test func aWrongCurrentPasswordStoresNothingAndKeepsTheSession() async throws {
    let daemon = Daemon { _ in Canned(status: 403, json: #"{"error":"the current password is wrong"}"#) }
    let vault = Vault()
    let owner = session(daemon, vault, phase: .ready)

    await #expect {
        _ = try await owner.changePassword(current: "nope", next: "a new password")
    } throws: { $0.localizedDescription == "the current password is wrong" }
    #expect(vault.saved.isEmpty && vault.reads == 0)
    #expect(owner.phase == .ready)
    #expect(daemon.requests.map(\.path) == ["/api/auth/password"])
}

@Test func revokingAnotherSessionDeletesItByHandle() async throws {
    let daemon = Daemon()
    let owner = session(daemon, Vault(), phase: .ready)
    let other = SessionEntry(handle: "Other-Handle_01", createdAt: 1, lastSeenAt: nil, userAgent: nil, current: false)

    try await owner.revoke(other)
    #expect(daemon.requests.map { "\($0.method) \($0.path)" } == ["DELETE /api/auth/sessions/Other-Handle_01"])
    #expect(owner.phase == .ready)
}

/// Revoking this app's own session is a log out: the device comes off the push list while the
/// session can still do that, then the same session ends.
@Test func revokingThisSessionLogsOutAndUnregistersFirst() async throws {
    let daemon = Daemon()
    let vault = Vault()
    let owner = session(daemon, vault, phase: .ready)
    owner.registeredDevice = "device-token"
    let mine = SessionEntry(handle: "Mine", createdAt: 1, lastSeenAt: 2, userAgent: "Schermes", current: true)

    try await owner.revoke(mine)
    #expect(owner.phase == .login)
    #expect(daemon.requests.map { "\($0.method) \($0.path)" } == [
        "DELETE /api/devices/device-token",
        "POST /api/auth/logout",
    ])
    #expect(vault.cleared.count == 1)
}

// MARK: - General settings

private let withGeneral = """
{"baseUrl":"","model":"","apiKeySet":false,"extraBody":"","searchUrl":"","searchKeySet":false,
 "timezone":"Europe/Amsterdam","imageRetentionDays":14,
 "push":{"keyId":"K1","teamId":"","bundleId":"","keySet":false,"sandbox":false}}
"""

@Test func theTimezoneAndRetentionDecodeAndAnOlderDaemonHasNeither() throws {
    let settings = try decode(DaemonSettings.self, withGeneral)
    #expect(settings.general == GeneralSettings(timezone: "Europe/Amsterdam", imageRetentionDays: 14))
    let form = SettingsForm(settings)
    #expect(form.timezone == "Europe/Amsterdam" && form.imageRetentionDays == 14)

    let old = try decode(DaemonSettings.self, #"{"searchUrl":"","searchKeySet":false}"#)
    #expect(old.general == GeneralSettings(timezone: nil, imageRetentionDays: nil))
    #expect(SettingsForm(old).imageRetentionDays == defaultImageRetentionDays)
}

@Test func theDaemonPageSendsOnlyItsOwnFields() throws {
    var form = SettingsForm(try decode(DaemonSettings.self, withGeneral))
    #expect(try encoded(form.generalUpdate) == ["timezone": .string("Europe/Amsterdam"), "imageRetentionDays": .number(14)])

    form.timezone = "  America/New_York "
    form.imageRetentionDays = 0
    #expect(try encoded(form.generalUpdate) == ["timezone": .string("America/New_York"), "imageRetentionDays": .number(0)])

    // A blank zone would be refused, so it is left out rather than sent.
    form.timezone = " "
    #expect(try encoded(form.generalUpdate) == ["imageRetentionDays": .number(0)])

    // And the other pages still send none of these.
    #expect(try Set(encoded(form.webUpdate).keys) == ["searchUrl"])
    #expect(try Set(encoded(form.pushUpdate).keys) == ["pushKeyId"])
}

// MARK: - Model capabilities

private func entry(window: String, vision: String) throws -> ModelEntry {
    try decode(ModelEntry.self, """
    {"id":1,"name":"Fast","providerId":2,"providerName":"OpenRouter","baseUrl":"https://openrouter.ai/api/v1",
     "model":"m","apiKeySet":true,"extraBody":""\(window)\(vision),"isDefault":true,"isBackup":false,"createdAt":1}
    """)
}

@Test func aModelsWindowAndVisionDecodeAndAnOlderDaemonSeesImages() throws {
    let current = try entry(window: #","contextWindow":32768"#, vision: #","vision":false"#)
    #expect(current.contextWindow == 32768 && current.vision == false && !current.seesImages)

    let unknown = try entry(window: #","contextWindow":null"#, vision: #","vision":true"#)
    #expect(unknown.contextWindow == nil && unknown.seesImages)

    let old = try entry(window: "", vision: "")
    #expect(old.contextWindow == nil && old.vision == nil && old.seesImages)
    #expect(ModelDraft(old).vision)
}

@Test func aClearedWindowGoesOutAsNullAndAnUntouchedOneNotAtAll() throws {
    #expect(try encoded(ModelUpdate(contextWindow: .some(nil))) == ["contextWindow": .null])
    #expect(try encoded(ModelUpdate(contextWindow: 128_000)) == ["contextWindow": .number(128_000)])
    #expect(try encoded(ModelUpdate(name: "x")) == ["name": .string("x")])
    #expect(try encoded(ModelUpdate(vision: false)) == ["vision": .bool(false)])

    let existing = try entry(window: #","contextWindow":32768"#, vision: #","vision":true"#)
    var draft = ModelDraft(existing)
    #expect(draft.update(from: existing) == ModelUpdate())

    draft.contextWindow = nil
    #expect(try encoded(draft.update(from: existing)) == ["contextWindow": .null])

    draft.contextWindow = 200_000
    draft.vision = false
    #expect(try encoded(draft.update(from: existing)) == ["contextWindow": .number(200_000), "vision": .bool(false)])
}

@Test func aNewModelSendsVisionAndAWindowOnlyWhenOneIsTyped() throws {
    var draft = ModelDraft(providerId: 2)
    draft.name = "Local"
    draft.model = "qwen3"
    #expect(try encoded(draft.update(from: nil)) == [
        "name": .string("Local"), "providerId": .number(2), "model": .string("qwen3"), "vision": .bool(true),
    ])

    draft.contextWindow = 32768
    draft.vision = false
    let body = try encoded(draft.update(from: nil))
    #expect(body["contextWindow"] == .number(32768) && body["vision"] == .bool(false))
}

/// The number fields read their text on every keystroke, so this is what Save sees.
@Test func aTypedNumberIsReadWithItsGroupingAndNothingElse() {
    #expect(typedWholeNumber("14") == 14)
    #expect(typedWholeNumber(" 0 ") == 0)
    #expect(typedWholeNumber("128,000") == 128_000)
    #expect(typedWholeNumber("128.000") == 128_000)
    #expect(typedWholeNumber("1 000 000") == 1_000_000)
    #expect(typedWholeNumber("") == nil)
    #expect(typedWholeNumber("  ") == nil)
    #expect(typedWholeNumber("12k") == nil)
    #expect(typedWholeNumber("-5") == nil)
    #expect(typedWholeNumber("١٢") == nil)
}

// MARK: - QR

@Test func theEnrolmentUriBecomesASquareQrCode() throws {
    let uri = "otpauth://totp/Schermes:owner?secret=JBSWY3DPEHPK3PXP&issuer=Schermes&algorithm=SHA1&digits=6&period=30"
    let image = try #require(qrCode(uri, scale: 4))
    #expect(image.width == image.height)
    #expect(image.width >= 21 * 4)
    #expect(image.width % 4 == 0)
}
