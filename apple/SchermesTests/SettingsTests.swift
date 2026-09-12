import Foundation
import Testing
@testable import Schermes

/// What `GET /api/settings` answers, the body a save sends, and the MCP box, against fixtures.

private let answered = """
{"baseUrl":"https://api.example.com/v1","model":"m","apiKeySet":true,
 "extraBody":"{\\"reasoning\\":{\\"effort\\":\\"high\\"}}","searchUrl":"","searchKeySet":false}
"""

private func stored() throws -> DaemonSettings {
    try JSONDecoder().decode(DaemonSettings.self, from: Data(answered.utf8))
}

private func body(_ form: SettingsForm) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(form.update))
    return try #require(object as? [String: String])
}

@Test func theSettingsBodyDecodesAsBothHalves() throws {
    let settings = try stored()
    #expect(settings.provider.baseUrl == "https://api.example.com/v1")
    #expect(settings.provider.apiKeySet)
    #expect(settings.provider.extraBody == #"{"reasoning":{"effort":"high"}}"#)
    #expect(settings.web.searchUrl.isEmpty)
    #expect(!settings.web.searchKeySet)
}

@Test func aSaveSendsEveryFieldButABlankKey() throws {
    var form = SettingsForm(try stored())
    #expect(form.apiKey.isEmpty && form.searchKey.isEmpty)
    // An empty field still goes: that is how a search endpoint or extra body is cleared.
    #expect(try body(form) == [
        "baseUrl": "https://api.example.com/v1",
        "model": "m",
        "extraBody": #"{"reasoning":{"effort":"high"}}"#,
        "searchUrl": "",
    ])

    form.apiKey = "sk-new"
    #expect(try body(form).count == 5)
    #expect(try body(form)["apiKey"] == "sk-new")

    form.searchKey = "brave"
    #expect(try body(form).count == 6)
    #expect(try body(form)["searchKey"] == "brave")
}

@Test func curlyQuotesFromTheKeyboardAreStraightenedOnlyWhenThatMakesJson() throws {
    #expect(typedJSON("{“a”:1}") == #"{"a":1}"#)
    #expect(typedJSON("{„a”:1}") == #"{"a":1}"#)
    #expect(typedJSON(#"{"q":"“hi”"}"#) == #"{"q":"“hi”"}"#)
    #expect(typedJSON("{“a”:") == "{“a”:")
    #expect(typedJSON("") == "")

    var form = SettingsForm(try stored())
    form.extraBody = "{“reasoning”:{“effort”:“low”}}"
    #expect(try body(form)["extraBody"] == #"{"reasoning":{"effort":"low"}}"#)

    #expect(try mcpServers(fromDraft: "[{“name”: “files”, “command”: “npx”}]") == .array([
        .object(["name": .string("files"), "command": .string("npx")]),
    ]))
}

@Test func anEmptyServerBoxIsNoServers() throws {
    #expect(try mcpServers(fromDraft: "") == .array([]))
    #expect(try mcpServers(fromDraft: " \n ") == .array([]))
}

@Test func theServerBoxGoesOutAsTypedSecretsIncluded() throws {
    let draft = """
    [{"name": "docs", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer t"}},
     {"name": "files", "command": "npx", "args": ["-y", "pkg"], "env": {"TOKEN": "x"}}]
    """
    #expect(try mcpServers(fromDraft: draft) == .array([
        .object([
            "name": .string("docs"),
            "url": .string("https://mcp.example.com/mcp"),
            "headers": .object(["Authorization": .string("Bearer t")]),
        ]),
        .object([
            "name": .string("files"),
            "command": .string("npx"),
            "args": .array([.string("-y"), .string("pkg")]),
            "env": .object(["TOKEN": .string("x")]),
        ]),
    ]))
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
