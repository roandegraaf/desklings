import Foundation
import Testing
@testable import Schermes

private let launch = Goal(
    id: 7, title: "Launch the site", lead: "mo", state: "open", steps: [], results: [],
    nextFromYou: [], helpers: [], createdAt: 0, updatedAt: 0, doneAt: nil
)

@Test func aLinkFollowsTheInstruction() {
    let item = SharedItem.link(URL(string: "https://example.com/a?b=1")!)
    #expect(sharedMessage(item, instruction: "  Summarise this ", goal: nil) == "Summarise this\n\nhttps://example.com/a?b=1")
    #expect(sharedMessage(item, instruction: "", goal: nil) == "Have a look at this.\n\nhttps://example.com/a?b=1")
}

@Test func textIsQuotedLineByLine() {
    let item = SharedItem.text("first\n\nthird")
    #expect(sharedMessage(item, instruction: "Reply to this", goal: nil) == "Reply to this\n\n> first\n> \n> third")
}

@Test func aFileIsNamedByWhereTheDaemonPutIt() {
    let item = SharedItem.file(name: "Résumé.pdf", data: Data([1, 2]))
    #expect(
        sharedMessage(item, instruction: "File this", goal: launch, uploadedTo: "/home/mo/uploads/Resume.pdf")
            == "File this\n\nThis is for the goal \"Launch the site\".\n\nI put the file in your home: /home/mo/uploads/Resume.pdf"
    )
}

@Test func aGoalGoesToItsLead() {
    #expect(ShareTarget(recipient: launch.lead, goal: launch).recipient == "mo")
    #expect(ShareTarget(recipient: "mo", goal: launch).id != ShareTarget(recipient: "mo").id)
}

@Test func filenamesFitTheUploadsRoute() {
    let route = /^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,127}$/
    #expect(uploadFilename("Résumé.pdf") == "Resume.pdf")
    #expect(uploadFilename("Screenshot 2026-09-30 at 22.03.png") == "Screenshot 2026-09-30 at 22.03.png")
    #expect(uploadFilename(".env") == "env")
    #expect(uploadFilename("__init__.py") == "init__.py")
    #expect(uploadFilename("a..b/../c.txt") == "a.b_._c.txt")
    #expect(uploadFilename("写真.jpg") == "jpg")
    #expect(uploadFilename("") == "shared")
    let long = uploadFilename(String(repeating: "x", count: 300) + ".tar.gz")
    #expect(long.count == 128)
    #expect(long.hasSuffix(".gz"))
    for name in ["Résumé.pdf", ".env", "a..b/../c.txt", "写真.jpg", "", String(repeating: "é", count: 400) + ".md"] {
        let cleaned = uploadFilename(name)
        #expect(cleaned.wholeMatch(of: route) != nil, "\(cleaned)")
        #expect(!cleaned.contains(".."))
    }
}

@Test func theUploadBodyIsTheSameJSONWhateverTheChunking() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "upload-body-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let name = #"Ré "sumé"\.pdf"#
    for size in [0, 1, 2, 5, 6, 7, 13] {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
        try writeUploadBody(name: name, data: data, to: file, chunk: 6)
        let body = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        #expect(body == ["name": name, "base64": data.base64EncodedString()], "size \(size)")
    }
}

@Test func anUploadSendsItsBodyFromAFileAndLeavesNoneBehind() async throws {
    let daemon = Daemon { _ in Canned(json: #"{"path":"/home/agent-mo/uploads/a.bin","bytes":200000}"#) }
    let client = SchermesClient(baseURL: URL(string: "http://\(daemon.host)")!, urlSession: canned)
    let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
    let before = try leftoverUploadBodies()

    let landed = try await client.upload(agent: "mo", name: "a.bin", data: data)

    #expect(landed.path == "/home/agent-mo/uploads/a.bin")
    let sent = try #require(daemon.requests.first)
    #expect(sent.method == "POST")
    #expect(sent.path == "/api/agents/mo/uploads")
    #expect(sent.headers["Content-Type"] ?? sent.headers["content-type"] == "application/json")
    #expect(sent.body == ["name": "a.bin", "base64": data.base64EncodedString()])
    #expect(try leftoverUploadBodies().subtracting(before).isEmpty)
}

private func leftoverUploadBodies() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
        .filter { $0.hasPrefix("upload-") && $0.hasSuffix(".json") && !$0.hasPrefix("upload-body-") })
}

@Test func aMappedShareOutlivesItsName() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "mapped-\(UUID().uuidString).bin")
    let bytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    try bytes.write(to: file)
    let mapped = try mappedFile(file)
    try FileManager.default.removeItem(at: file)
    #expect(mapped == bytes)
}

@Test func onlyPlainHTTPOffThisDeviceIsCleartext() {
    func cleartext(_ text: String) -> Bool { Session.isCleartext(URL(string: text)!) }
    #expect(cleartext("http://192.168.1.20:7777"))
    #expect(cleartext("http://schermes.local:7777"))
    #expect(cleartext("HTTP://desklings.example.com"))
    #expect(!cleartext("https://desklings.example.com"))
    #expect(!cleartext("http://127.0.0.1:7777"))
    #expect(!cleartext("http://localhost:7777"))
    #expect(!cleartext("http://[::1]:7777"))
    #expect(Session.parse("192.168.1.20:7777").map(Session.isCleartext) == true)
    #expect(Session.parse("desklings.example.com").map(Session.isCleartext) == false)
}

@Test func anImageFileIsNamedByItsBytes() {
    let one = Data("one".utf8)
    #expect(imageFolderName(one) == imageFolderName(Data("one".utf8)))
    #expect(imageFolderName(one) != imageFolderName(Data("two".utf8)))
    #expect(imageFolderName(one).hasPrefix("images-"))
}
