import Foundation
import Testing
@testable import Schermes

/// What `GET /api/settings` answers, the body a save sends, and the MCP box, against fixtures.

private let answered = """
{"baseUrl":"https://api.example.com/v1","model":"m","apiKeySet":true,
 "extraBody":"{\\"reasoning\\":{\\"effort\\":\\"high\\"}}","searchUrl":"","searchKeySet":false,
 "push":{"keyId":"K1","teamId":"T1","bundleId":"dev.schermes.Schermes","keySet":false,"sandbox":true}}
"""

private func stored() throws -> DaemonSettings {
    try JSONDecoder().decode(DaemonSettings.self, from: Data(answered.utf8))
}

private func body(_ value: some Encodable) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
}

@Test func theSettingsBodyDecodesAsBothHalves() throws {
    let settings = try stored()
    #expect(settings.provider.baseUrl == "https://api.example.com/v1")
    #expect(settings.provider.apiKeySet)
    #expect(settings.provider.extraBody == #"{"reasoning":{"effort":"high"}}"#)
    #expect(settings.web.searchUrl.isEmpty)
    #expect(!settings.web.searchKeySet)
    #expect(settings.push.keyId == "K1" && settings.push.sandbox && !settings.push.keySet)
}

@Test func aDaemonWithoutPushStillDecodes() throws {
    let old = #"{"baseUrl":"","model":"","apiKeySet":false,"extraBody":"","searchUrl":"","searchKeySet":false}"#
    let settings = try JSONDecoder().decode(DaemonSettings.self, from: Data(old.utf8))
    #expect(settings.push.bundleId.isEmpty && !settings.push.sandbox)
}

@Test func aPageSendsItsOwnFieldsAndNoOthers() throws {
    var form = SettingsForm(try stored())
    #expect(form.apiKey.isEmpty && form.searchKey.isEmpty && form.pushKey.isEmpty)

    // An empty field still goes: that is how a search endpoint or extra body is cleared. A field
    // another page owns must not, or saving here would overwrite what that page holds.
    #expect(try body(form.modelUpdate) == [
        "baseUrl": .string("https://api.example.com/v1"),
        "model": .string("m"),
        "extraBody": .string(#"{"reasoning":{"effort":"high"}}"#),
    ])
    #expect(try body(form.webUpdate) == ["searchUrl": .string("")])
    #expect(try body(form.pushUpdate) == [
        "pushKeyId": .string("K1"),
        "pushTeamId": .string("T1"),
        "pushBundleId": .string("dev.schermes.Schermes"),
        "pushSandbox": .bool(true),
    ])

    form.apiKey = "sk-new"
    form.searchKey = "brave"
    form.pushKey = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
    #expect(try Set(body(form.modelUpdate).keys) == ["baseUrl", "model", "extraBody", "apiKey"])
    #expect(try body(form.modelUpdate)["apiKey"] == .string("sk-new"))
    #expect(try Set(body(form.webUpdate).keys) == ["searchUrl", "searchKey"])
    #expect(try body(form.webUpdate)["searchKey"] == .string("brave"))
    #expect(try Set(body(form.pushUpdate).keys) == [
        "pushKeyId", "pushTeamId", "pushBundleId", "pushSandbox", "pushKey",
    ])
    #expect(try body(form.pushUpdate)["pushKey"] == .string("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"))
}

@Test func curlyQuotesFromTheKeyboardAreStraightenedOnlyWhenThatMakesJson() throws {
    #expect(typedJSON("{“a”:1}") == #"{"a":1}"#)
    #expect(typedJSON("{„a”:1}") == #"{"a":1}"#)
    #expect(typedJSON(#"{"q":"“hi”"}"#) == #"{"q":"“hi”"}"#)
    #expect(typedJSON("{“a”:") == "{“a”:")
    #expect(typedJSON("") == "")

    var form = SettingsForm(try stored())
    form.extraBody = "{“reasoning”:{“effort”:“low”}}"
    #expect(try body(form.modelUpdate)["extraBody"] == .string(#"{"reasoning":{"effort":"low"}}"#))

    #expect(try mcpServers(fromDraft: "[{“name”: “files”, “command”: “npx”}]") == [
        McpServerDraft(name: "files", transport: .stdio, command: "npx"),
    ])
}

@Test func anEmptyServerBoxIsNoServers() throws {
    #expect(try mcpServers(fromDraft: "").isEmpty)
    #expect(try mcpServers(fromDraft: " \n ").isEmpty)
}

@Test func theServerBoxGoesOutAsTypedSecretsIncluded() throws {
    let draft = """
    [{"name": "docs", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer t"}},
     {"name": "files", "command": "npx", "args": ["-y", "pkg"], "env": {"TOKEN": "x"}}]
    """
    let parsed = try mcpServers(fromDraft: draft)
    #expect(parsed.map(\.name) == ["docs", "files"])
    #expect(try body(parsed[0])["headers"] == .object(["Authorization": .string("Bearer t")]))
    #expect(try body(parsed[1])["env"] == .object(["TOKEN": .string("x")]))
}

@Test func aPastedReadmeSnippetFillsTheSameFormAsTheDaemonsOwnArray() throws {
    let readme = """
    {"mcpServers": {"files": {"command": "npx", "args": ["-y", "pkg"], "env": {"TOKEN": "x"}},
                    "docs": {"url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer t"}}}}
    """
    let array = """
    [{"name": "docs", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer t"}},
     {"name": "files", "command": "npx", "args": ["-y", "pkg"], "env": {"TOKEN": "x"}}]
    """
    // A JSON object carries no order, so the names come back sorted; the array keeps the owner's,
    // which here is already that.
    #expect(try mcpServers(fromDraft: readme) == mcpServers(fromDraft: array))

    let servers = try mcpServers(fromDraft: readme)
    #expect(servers.map(\.name) == ["docs", "files"])
    #expect(servers[0].transport == .http && servers[0].url == "https://mcp.example.com/mcp")
    #expect(servers[0].secrets == [.init(key: "Authorization", value: "Bearer t")])
    #expect(servers[1].command == "npx" && servers[1].args == ["-y", "pkg"])
    #expect(servers[1].secrets == [.init(key: "TOKEN", value: "x")])
}

/// The daemon refuses this too, but a draft has one transport and would otherwise have to drop
/// half of it silently.
@Test func anEntryThatIsBothStdioAndHttpIsRefusedRatherThanHalfKept() throws {
    for draft in [#"[{"name": "files", "command": "npx", "url": "https://x/mcp"}]"#, #"[{"name": "files"}]"#] {
        let error = #expect(throws: SchermesError.self) { try mcpServers(fromDraft: draft) }
        #expect(error?.localizedDescription
            == "files must have either a command (stdio) or a url (http), not both")
    }
    #expect(throws: SchermesError.self) { try mcpServers(fromDraft: #"{"servers": []}"#) }
    #expect(throws: SchermesError.self) { try mcpServers(fromDraft: #"[{"command": "npx"}]"#) }
}

@Test func aStoredSecretGoesOutBlankRatherThanBeingLeftOut() throws {
    var server = McpServerDraft(
        name: "files", transport: .stdio, command: "npx", args: ["-y", "pkg"],
        secrets: [.init(key: "TOKEN", value: ""), .init(key: "NEW", value: "v")]
    )
    #expect(try body(server) == [
        "name": .string("files"),
        "command": .string("npx"),
        "args": .array([.string("-y"), .string("pkg")]),
        "env": .object(["TOKEN": .string(""), "NEW": .string("v")]),
    ])

    // Blank keeps, absent removes, so clearing the last row has to send an empty block, not none.
    server.secrets = []
    #expect(try body(server)["env"] == .object([:]))

    let remote = McpServerDraft(
        name: "docs", transport: .http, url: "https://mcp.example.com/mcp",
        secrets: [.init(key: "Authorization", value: "")]
    )
    #expect(try Set(body(remote).keys) == ["name", "url", "headers"])
    #expect(try body(remote)["headers"] == .object(["Authorization": .string("")]))
}

/// The editor sheet holds one server, so the paste that fills it takes one.
@Test func aSnippetWithAnythingButOneServerIsRefusedRatherThanHalfRead() throws {
    #expect(try mcpServer(fromDraft: #"{"mcpServers": {"files": {"command": "npx"}}}"#)
        == McpServerDraft(name: "files", transport: .stdio, command: "npx"))

    for (draft, said) in [
        ("", "that snippet has no server in it"),
        ("[]", "that snippet has no server in it"),
        (#"[{"name": "a", "url": "https://a/mcp"}, {"name": "b", "url": "https://b/mcp"}]"#,
         "that snippet has 2 servers in it, so add them one at a time"),
    ] {
        let error = #expect(throws: SchermesError.self) { try mcpServer(fromDraft: draft) }
        #expect(error?.localizedDescription == said)
    }
}

@Test func aTypoInTheServerBoxSaysWhereItIs() {
    let error = #expect(throws: SchermesError.self) { try mcpServers(fromDraft: #"[{"name": }]"#) }
    let text = error?.localizedDescription ?? ""
    #expect(text.hasPrefix("that is not JSON: "))
    #expect(text.contains("column"))
}

@Test func aConnectionTestReadsAsOneLine() {
    #expect(McpTestResult(ok: true, tools: ["read_file", "write_file"]).report == "2 tools: read_file, write_file")
    #expect(McpTestResult(ok: true, tools: ["search"]).report == "1 tool: search")
    #expect(McpTestResult(ok: true, tools: []).report == "Connected, no tools offered")
    #expect(McpTestResult(ok: false, tools: [], error: "spawn nope ENOENT").report == "spawn nope ENOENT")
    #expect(McpTestResult(ok: false, tools: []).report == "Could not be reached")
}
