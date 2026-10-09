import ArgumentParser
import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class SubStoreContentCommandTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SubStoreCLIMockURLProtocol.responses = [:]
        SubStoreCLIMockURLProtocol.requests = []
    }

    override func tearDown() {
        SubStoreCLIMockURLProtocol.responses = [:]
        SubStoreCLIMockURLProtocol.requests = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTemporaryPaths() throws -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-substore-cli-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return KumoPaths(
            applicationSupportDirectory: root,
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    private func makeClient() -> SubStoreClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubStoreCLIMockURLProtocol.self]
        return SubStoreClient(
            baseURL: URL(string: "http://127.0.0.1:38324")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func entry(_ name: String, displayName: String? = nil, tags: [String] = [], kind: SubStoreEntryKind) -> SubStoreEntry {
        SubStoreEntry(name: name, displayName: displayName, icon: nil, tags: tags, kind: kind)
    }

    // MARK: - Parsing

    func testSubStoreContentCommandsParse() {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "subscriptions", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "collections", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "files", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "modules", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "content", "airport", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "content", "airport", "--kind", "collection", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "preview", "airport", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "import", "airport", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot([
            "substore", "import", "airport", "--name", "Airport A", "--use-proxy", "--json"
        ]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "settings", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["substore", "logs", "--limit", "50", "--json"]))
    }

    func testSubStoreContentCommandsRejectBadArguments() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "content"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "content", "x", "--kind", "module"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "preview"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "import"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "import", "x", "--name", "  "]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["substore", "logs", "--limit", "0"]))
    }

    func testSubStoreContentCommandsCarryParsedValues() throws {
        let content = try XCTUnwrap(
            KumoCommand.parseAsRoot(["substore", "content", "airport", "--kind", "file"]) as? KumoCommand.Substore.Content
        )
        XCTAssertEqual(content.name, "airport")
        XCTAssertEqual(content.kind, .file)

        let preview = try XCTUnwrap(
            KumoCommand.parseAsRoot(["substore", "preview", "airport", "--kind", "collection"]) as? KumoCommand.Substore.Preview
        )
        XCTAssertEqual(preview.kind, .collection)

        let importCommand = try XCTUnwrap(
            KumoCommand.parseAsRoot([
                "substore", "import", "airport", "--name", "Airport A", "--use-proxy"
            ]) as? KumoCommand.Substore.Import
        )
        XCTAssertEqual(importCommand.nameOrPath, "airport")
        XCTAssertEqual(importCommand.name, "Airport A")
        XCTAssertTrue(importCommand.useProxy)

        let logs = try XCTUnwrap(
            KumoCommand.parseAsRoot(["substore", "logs", "--limit", "7"]) as? KumoCommand.Substore.Logs
        )
        XCTAssertEqual(logs.limit, 7)
    }

    // MARK: - Name resolution (import)

    func testResolveImportTargetPrefersSubscriptionsThenCollections() throws {
        let subscriptions = [entry("airport", displayName: "Airport A", tags: ["fast"], kind: .subscription)]
        let collections = [entry("all-servers", displayName: "All Servers", kind: .collection)]

        let subscriptionTarget = try SubStoreCommandSupport.resolveImportTarget(
            "airport",
            subscriptions: subscriptions,
            collections: collections,
            files: []
        )
        XCTAssertEqual(subscriptionTarget.kind, .subscription)
        XCTAssertEqual(subscriptionTarget.path, "/download/airport")
        XCTAssertEqual(subscriptionTarget.profileName, "Airport A")

        let collectionTarget = try SubStoreCommandSupport.resolveImportTarget(
            "all-servers",
            subscriptions: subscriptions,
            collections: collections,
            files: []
        )
        XCTAssertEqual(collectionTarget.kind, .collection)
        XCTAssertEqual(collectionTarget.path, "/download/collection/all-servers")
        XCTAssertEqual(collectionTarget.profileName, "All Servers")
    }

    func testResolveImportTargetMatchesDisplayNameAndRejectsAmbiguity() throws {
        let subscriptions = [
            entry("sub-a", displayName: "Airport", kind: .subscription),
            entry("sub-b", displayName: "Airport", kind: .subscription)
        ]
        XCTAssertThrowsError(try SubStoreCommandSupport.resolveImportTarget(
            "Airport",
            subscriptions: subscriptions,
            collections: [],
            files: []
        )) { error in
            XCTAssertEqual(
                (error as? ValidationError)?.message,
                "`Airport` matches 2 Sub-Store entries by display name; use the canonical name instead."
            )
        }

        let target = try SubStoreCommandSupport.resolveImportTarget(
            "Airport",
            subscriptions: [entry("sub-a", displayName: "Airport", kind: .subscription)],
            collections: [],
            files: []
        )
        XCTAssertEqual(target.path, "/download/sub-a")
        XCTAssertEqual(target.profileName, "Airport")
    }

    func testResolveImportTargetRejectsFilesAndUnknownNames() throws {
        let files = [SubStoreFile(name: "ruleset", displayName: "Ruleset", type: "rule", source: "remote")]
        XCTAssertThrowsError(try SubStoreCommandSupport.resolveImportTarget(
            "ruleset",
            subscriptions: [],
            collections: [],
            files: files
        )) { error in
            let message = (error as? ValidationError)?.message ?? ""
            XCTAssertTrue(message.contains("is a Sub-Store file"), message)
            XCTAssertTrue(message.contains("--kind file"), message)
        }

        XCTAssertThrowsError(try SubStoreCommandSupport.resolveImportTarget(
            "missing",
            subscriptions: [],
            collections: [],
            files: []
        )) { error in
            XCTAssertEqual(
                (error as? ValidationError)?.message,
                "No Sub-Store subscription or collection named `missing`. Run `kumo substore subscriptions` or `kumo substore collections` to list available names."
            )
        }

        XCTAssertThrowsError(try SubStoreCommandSupport.resolveImportTarget(
            "   ",
            subscriptions: [],
            collections: [],
            files: []
        ))
    }

    func testResolveImportTargetPassesThroughExplicitPathsAndURLs() throws {
        let path = try SubStoreCommandSupport.resolveImportTarget(
            "/download/collection/airport",
            subscriptions: [entry("airport", kind: .subscription)],
            collections: [],
            files: []
        )
        XCTAssertEqual(path.kind, .path)
        XCTAssertEqual(path.path, "/download/collection/airport")
        XCTAssertNil(path.profileName)

        let url = try SubStoreCommandSupport.resolveImportTarget(
            "https://example.com/sub.yaml",
            subscriptions: [],
            collections: [],
            files: []
        )
        XCTAssertEqual(url.kind, .path)
        XCTAssertEqual(url.path, "https://example.com/sub.yaml")

        // Explicit paths win even when a same-named subscription exists, the
        // same precedence `KumoController.subStoreProfileDownloadURL` uses.
        XCTAssertEqual(try SubStoreCommandSupport.explicitImportTarget("/download/airport")?.kind, .path)
        XCTAssertNil(SubStoreCommandSupport.explicitImportTarget("airport"))
    }

    // MARK: - Client-backed listings

    func testListingsMapClientPayloads() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/subs"] = .json("""
        {"status":"success","data":[
          {"name":"sub-a","displayName":"Sub A","icon":"icon-a","source":"remote","url":"https://example.com/a","tag":["fast","cheap"]},
          {"name":"sub-b","source":"local"}
        ]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/collections"] = .json("""
        {"status":"success","data":[
          {"name":"col-a","displayName":"Collection A","subscriptions":["sub-a"]}
        ]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/files"] = .json("""
        {"status":"success","data":[
          {"name":"file-a","displayName":"File A","type":"rule","source":"remote","url":"https://example.com/rules.yaml"}
        ]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/modules"] = .json("""
        {"status":"success","data":[
          {"name":"mod-a","content":"// js","description":"Tweak","icon":"wrench"}
        ]}
        """)
        let client = makeClient()

        let subscriptions = try await SubStoreCommandSupport.subscriptions(client: client)
        XCTAssertEqual(subscriptions.count, 2)
        XCTAssertEqual(subscriptions[0].kind, .subscription)
        XCTAssertEqual(subscriptions[0].icon, "icon-a")
        XCTAssertEqual(subscriptions[0].tags, ["fast", "cheap"])
        XCTAssertEqual(SubStoreCommandSupport.entryLine(subscriptions[0]), "sub-a Sub A #fast #cheap")
        XCTAssertEqual(SubStoreCommandSupport.entryLine(subscriptions[1]), "sub-b")

        let collections = try await SubStoreCommandSupport.collections(client: client)
        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections[0].kind, .collection)
        XCTAssertEqual(collections[0].tags, [])
        XCTAssertEqual(SubStoreCommandSupport.entryLine(collections[0]), "col-a Collection A")

        let files = try await SubStoreCommandSupport.files(client: client)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].name, "file-a")
        XCTAssertEqual(files[0].type, "rule")
        XCTAssertEqual(files[0].source, "remote")
        XCTAssertEqual(files[0].url, "https://example.com/rules.yaml")
        XCTAssertEqual(SubStoreCommandSupport.fileLine(files[0]), "file-a File A rule remote")

        let modules = try await SubStoreCommandSupport.modules(client: client)
        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules[0].name, "mod-a")
        XCTAssertEqual(modules[0].description, "Tweak")
        XCTAssertEqual(SubStoreCommandSupport.moduleLine(modules[0]), "mod-a Tweak")
    }

    // MARK: - Content and preview

    func testContentSelectsExplicitKindAndInfersAuto() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/subs"] = .json("""
        {"status":"success","data":[
          {"name":"airport","displayName":"Airport A","source":"remote","url":"https://example.com/a","tag":["fast"],"process":[{"type":"Script"}]}
        ]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/collections"] = .json("""
        {"status":"success","data":[{"name":"all-servers","subscriptions":["airport"]}]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/files"] = .json("""
        {"status":"success","data":[{"name":"ruleset","type":"rule"}]}
        """)
        let client = makeClient()

        let auto = try await SubStoreCommandSupport.content(name: "Airport A", kind: nil, client: client)
        XCTAssertEqual(auto.kind, "subscription")
        XCTAssertEqual(auto.name, "airport")
        XCTAssertEqual(auto.entry.objectValue?["source"]?.stringValue, "remote")
        XCTAssertEqual(auto.entry.objectValue?["tag"]?.arrayValue?.count, 1)
        XCTAssertTrue(SubStoreCommandSupport.contentText(auto).contains("tags=1"))

        let file = try await SubStoreCommandSupport.content(name: "ruleset", kind: .file, client: client)
        XCTAssertEqual(file.kind, "file")
        XCTAssertEqual(file.name, "ruleset")
        XCTAssertTrue(SubStoreCommandSupport.contentText(file).contains("type=rule"))
    }

    func testContentFailsWithGuidanceWhenKindHasNoMatch() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/subs"] = .json("""
        {"status":"success","data":[]}
        """)
        let client = makeClient()

        do {
            _ = try await SubStoreCommandSupport.content(name: "ruleset", kind: .subscription, client: client)
            XCTFail("expected a missing-subscription error")
        } catch {
            XCTAssertEqual(
                (error as? ValidationError)?.message,
                "No Sub-Store subscription named `ruleset`. Run `kumo substore subscriptions` to list available names."
            )
        }
    }

    func testPreviewPrintsParsedNodeArraysNotYAML() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/subs"] = .json("""
        {"status":"success","data":[{"name":"airport","source":"remote","url":"https://example.com/a"}]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/preview/sub"] = .json("""
        {"status":"success","data":{
          "original":[{"name":"HK-01","type":"ss"}],
          "processed":[{"name":"HK-01","type":"ss"},{"name":"US-01","type":"ss"}]
        }}
        """)
        let client = makeClient()

        let payload = try await SubStoreCommandSupport.preview(name: "airport", kind: nil, client: client)

        XCTAssertEqual(payload.kind, "subscription")
        XCTAssertEqual(payload.name, "airport")
        XCTAssertEqual(payload.originalCount, 1)
        XCTAssertEqual(payload.processedCount, 2)
        XCTAssertEqual(payload.processed[1].objectValue?["name"]?.stringValue, "US-01")
        XCTAssertNil(payload.processed[0].objectValue?["proxies"])

        let request = try XCTUnwrap(SubStoreCLIMockURLProtocol.requests.first { $0.url?.path == "/api/preview/sub" })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.query?.contains("target=JSON") == true, request.url?.query ?? "no query")

        let text = SubStoreCommandSupport.previewText(payload)
        XCTAssertTrue(text.contains("airport: original=1 processed=2"), text)
        XCTAssertTrue(text.contains("HK-01"), text)
        XCTAssertTrue(text.contains("US-01"), text)
        XCTAssertFalse(text.contains("proxies:"), text)

        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["processed"] as? [Any])?.count, 2)
        XCTAssertEqual((object["original"] as? [Any])?.count, 1)
    }

    func testPreviewSupportsFiles() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/subs"] = .json("""
        {"status":"success","data":[]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/collections"] = .json("""
        {"status":"success","data":[]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/files"] = .json("""
        {"status":"success","data":[{"name":"ruleset","type":"rule"}]}
        """)
        SubStoreCLIMockURLProtocol.responses["/api/preview/file"] = .json("""
        {"status":"success","data":{"original":[],"processed":[{"name":"DOMAIN-SUFFIX,example.com"}]}}
        """)
        let client = makeClient()

        let payload = try await SubStoreCommandSupport.preview(name: "ruleset", kind: nil, client: client)

        XCTAssertEqual(payload.kind, "file")
        XCTAssertEqual(payload.processedCount, 1)
        XCTAssertTrue(SubStoreCLIMockURLProtocol.requests.contains { $0.url?.path == "/api/preview/file" })
    }

    // MARK: - Import report

    func testImportReportEncodesResolvedTargetAndProfile() throws {
        let profile = ProfileSummary(
            id: "profile-1",
            name: "Airport A",
            sourceDescription: "Sub-Store",
            isCurrent: false,
            kind: .local,
            autoUpdate: false,
            useProxy: true,
            isSubStoreManaged: true,
            subStorePath: "/download/airport"
        )
        let report = SubStoreImportReport(
            input: "airport",
            kind: "subscription",
            path: "/download/airport",
            useProxy: true,
            profile: profile
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(object["input"] as? String, "airport")
        XCTAssertEqual(object["kind"] as? String, "subscription")
        XCTAssertEqual(object["path"] as? String, "/download/airport")
        XCTAssertEqual(object["useProxy"] as? Bool, true)
        let profileObject = try XCTUnwrap(object["profile"] as? [String: Any])
        XCTAssertEqual(profileObject["id"] as? String, "profile-1")
        XCTAssertEqual(profileObject["subStorePath"] as? String, "/download/airport")
    }

    // MARK: - JSON envelope

    func testSubStorePayloadsEncodeInsideTheCLIEnvelope() throws {
        let payload = SubStorePreviewPayload(
            kind: "subscription",
            name: "airport",
            originalCount: 1,
            processedCount: 1,
            original: [.object(["name": .string("HK-01")])],
            processed: [.object(["name": .string("HK-01")])]
        )

        let data = try JSONEncoder().encode(CLIResponse(ok: true, data: payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["error"] is NSNull)
        let dataObject = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(dataObject["kind"] as? String, "subscription")
        XCTAssertEqual(dataObject["name"] as? String, "airport")
        XCTAssertEqual((dataObject["processed"] as? [Any])?.count, 1)
        XCTAssertEqual((dataObject["original"] as? [Any])?.count, 1)
    }

    // MARK: - Settings

    func testSettingsReportWithoutBackendStillReportsModeAndReason() async throws {
        let controller = KumoController(paths: try makeTemporaryPaths())

        let report = try await SubStoreCommandSupport.settingsReport(controller: controller)

        XCTAssertNil(report.backendURL)
        XCTAssertEqual(report.backendMode, "bundled")
        XCTAssertFalse(report.isEnabled)
        XCTAssertFalse(report.isBackendRunning)
        XCTAssertNil(report.settings)
        XCTAssertEqual(report.settingsError, "Sub-Store backend is not configured.")

        let text = SubStoreCommandSupport.settingsText(report)
        XCTAssertTrue(text.contains("backend=-"), text)
        XCTAssertTrue(text.contains("mode=bundled"), text)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(object["backendMode"] as? String, "bundled")
        XCTAssertEqual(object["settingsError"] as? String, "Sub-Store backend is not configured.")
    }

    func testSettingsReportReportsCustomBackendMode() async throws {
        let paths = try makeTemporaryPaths()
        let controller = KumoController(paths: paths)
        var status = SubStoreStatus()
        status.usesCustomBackend = true
        status.isEnabled = true
        try controller.updateSubStoreStatus(status)

        let report = try await SubStoreCommandSupport.settingsReport(controller: controller)

        XCTAssertEqual(report.backendMode, "custom")
        XCTAssertNil(report.backendURL)
        XCTAssertTrue(report.isEnabled)
        XCTAssertEqual(report.settingsError, "Sub-Store backend is not configured.")
    }

    // MARK: - Logs

    func testLogsReadsBackendLogBuffer() async throws {
        // `SubStoreClient.logs` embeds `?limit=` in the path string, so the
        // stub keys on the recorded (decoded) path. The wrapper decodes the
        // typed client's array envelope when the backend answers it.
        SubStoreCLIMockURLProtocol.responses["/api/logs?limit=10"] = .json("""
        {"status":"success","data":[
          {"id":"1","level":"info","message":"synced","time":1700000000}
        ]}
        """)
        let client = makeClient()
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-substore-missing-\(UUID().uuidString).log")

        let payload = try await SubStoreCommandSupport.logs(client: client, logFileURL: missingFile, limit: 10)

        XCTAssertEqual(payload.source, "backend")
        XCTAssertNil(payload.backendError)
        XCTAssertNil(payload.path)
        XCTAssertEqual(payload.entries.map(\.message), ["synced"])
        XCTAssertTrue(SubStoreCLIMockURLProtocol.requests.contains {
            $0.url?.absoluteString.contains("/api/logs") == true && $0.url?.absoluteString.contains("limit=10") == true
        })
        XCTAssertTrue(SubStoreCommandSupport.logLine(payload.entries[0]).contains("INFO synced"))
    }

    func testLogsFallsBackToSubStoreLogFile() async throws {
        SubStoreCLIMockURLProtocol.responses["/api/logs?limit=3"] = .status(500, "{\"status\":\"failed\"}")
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-substore-\(UUID().uuidString).log")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: logFile)
        }
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: logFile, atomically: true, encoding: .utf8)

        let payload = try await SubStoreCommandSupport.logs(client: makeClient(), logFileURL: logFile, limit: 3)

        XCTAssertEqual(payload.source, "file")
        XCTAssertEqual(payload.path, logFile.path)
        XCTAssertTrue(payload.backendError?.contains("HTTP 500") == true, payload.backendError ?? "nil")
        XCTAssertEqual(payload.entries.map(\.message), ["line 3", "line 4", "line 5"])
    }

    func testLogsWithoutBackendOrFileFails() async throws {
        let controller = KumoController(paths: try makeTemporaryPaths())

        do {
            _ = try await SubStoreCommandSupport.logs(controller: controller, limit: 5)
            XCTFail("expected a backend-configuration failure")
        } catch {
            XCTAssertEqual(
                (error as? KumoError)?.errorDescription,
                "Sub-Store backend is not configured."
            )
        }
    }

    // MARK: - Help

    func testHelpCoversSubStoreContentCommands() {
        let help = HelpText.topic(["substore"])
        XCTAssertTrue(help.contains("kumo substore subscriptions|collections [--json]"), help)
        XCTAssertTrue(help.contains("kumo substore content <name>"), help)
        XCTAssertTrue(help.contains("kumo substore import <name-or-path>"), help)
        XCTAssertTrue(help.contains("kumo substore logs [--limit <count>]"), help)
        XCTAssertTrue(help.contains("read-only"), help)

        XCTAssertTrue(HelpText.topic(["substore", "import"]).contains("resolves against subscriptions first"))
        XCTAssertTrue(HelpText.topic(["substore", "preview"]).contains("node arrays"))
        XCTAssertTrue(HelpText.long.contains("substore preview"))
        XCTAssertTrue(CompletionScripts.commandNames.contains("substore"))

        let paths = [
            ["substore", "subscriptions"],
            ["substore", "collections"],
            ["substore", "files"],
            ["substore", "modules"],
            ["substore", "content"],
            ["substore", "preview"],
            ["substore", "import"],
            ["substore", "settings"],
            ["substore", "logs"]
        ]
        for path in paths {
            let topic = HelpText.topic(path)
            XCTAssertFalse(topic.contains("No detailed help found"), "missing help for: \(path.joined(separator: " "))")
        }
    }
}

// MARK: - URLProtocol stub

private final class SubStoreCLIMockURLProtocol: URLProtocol {
    enum Response {
        case json(String)
        case status(Int, String)
    }

    nonisolated(unsafe) static var responses: [String: Response] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        switch Self.responses[path] ?? .status(404, "{}") {
        case .json(let payload):
            sendResponse(statusCode: 200, body: payload)
        case .status(let code, let body):
            sendResponse(statusCode: code, body: body)
        }
    }

    override func stopLoading() {}

    private func sendResponse(statusCode: Int, body: String) {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
