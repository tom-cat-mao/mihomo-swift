import XCTest
@testable import KumoCoreKit

final class MihomoControllerClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.asynchronousRequestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.asynchronousRequestHandler = nil
        super.tearDown()
    }

    func testProxyGroupsMapControllerResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/proxies")
            let data = Data(
                """
                {
                  "proxies": {
                    "Proxy": { "type": "Selector", "now": "HK", "all": ["HK", "US"] },
                    "HK": { "type": "Shadowsocks", "history": [{ "delay": 120 }] },
                    "US": { "type": "Shadowsocks", "history": [{ "delay": 200 }] },
                    "Hidden": { "type": "Selector", "hidden": true, "all": ["HK"] }
                  }
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = MihomoControllerClient(session: mockSession())

        let groups = try await client.proxyGroups()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Proxy")
        XCTAssertEqual(groups.first?.selectedProxyName, "HK")
        XCTAssertEqual(groups.first?.proxies.map(\.delay), [120, 200])
    }

    func testProxySelectionsIncludeHiddenGlobalGroup() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/proxies")
            let data = Data(
                """
                {
                  "proxies": {
                    "Proxy": { "type": "Selector", "now": "HK", "all": ["HK", "US"] },
                    "GLOBAL": { "type": "Selector", "hidden": true, "now": "Proxy", "all": ["Proxy", "DIRECT"] },
                    "HK": { "type": "Shadowsocks" },
                    "Empty": { "type": "Selector", "now": "", "all": [] }
                  }
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = MihomoControllerClient(session: mockSession())

        let selections = try await client.proxySelections()

        XCTAssertEqual(selections, ["Proxy": "HK", "GLOBAL": "Proxy"])
    }

    func testTrafficStreamParserMapsMihomoMetaPayload() throws {
        // Mihomo Meta emits per-second speeds as `up`/`down` and cumulative totals as
        // `upTotal`/`downTotal`. Verify the WS parser routes them into the right fields so the
        // overview's traffic card stops permanently displaying zero.
        let payload = """
        {"up":1234,"down":5678,"upTotal":111,"downTotal":222}
        """
        let snapshot = try parseTrafficSnapshot(payload)
        XCTAssertEqual(snapshot.uploadSpeed, 1234)
        XCTAssertEqual(snapshot.downloadSpeed, 5678)
        XCTAssertEqual(snapshot.upload, 111)
        XCTAssertEqual(snapshot.download, 222)
    }

    func testTrafficStreamParserFallsBackToLegacyFieldNames() throws {
        // Older mihomo builds (and some forks) only emit `{up, down}` without totals.
        let payload = """
        {"up":42,"down":99}
        """
        let snapshot = try parseTrafficSnapshot(payload)
        XCTAssertEqual(snapshot.uploadSpeed, 42)
        XCTAssertEqual(snapshot.downloadSpeed, 99)
        XCTAssertEqual(snapshot.upload, 0)
        XCTAssertEqual(snapshot.download, 0)
    }

    func testConnectionsMapControllerResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/connections")
            let data = Data(
                """
                {
                  "connections": [
                    {
                      "id": "abc",
                      "metadata": {
                        "host": "example.com",
                        "process": "Safari",
                        "processPath": "/Applications/Safari.app/Contents/MacOS/Safari"
                      },
                      "rule": "MATCH",
                      "chains": ["Proxy", "HK"],
                      "upload": 10,
                      "download": 20
                    }
                  ]
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = MihomoControllerClient(session: mockSession())

        let connections = try await client.connections()

        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.id, "abc")
        XCTAssertEqual(connections.first?.host, "example.com")
        XCTAssertEqual(connections.first?.process, "Safari")
        XCTAssertEqual(connections.first?.processPath, "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertEqual(connections.first?.chain, ["Proxy", "HK"])
    }

    func testGroupDelayUsesBatchEndpointAndMapsCurrentResults() async throws {
        let group = ProxyGroup(
            name: "Proxy",
            proxies: [
                ProxyNode(name: "HK", type: "Shadowsocks", delay: 999, delayStatus: .stale),
                ProxyNode(name: "Timeout", delay: 120, delayStatus: .stale)
            ],
            testURL: "https://example.com/generate_204"
        )
        let tracker = DelayRequestTracker()
        MockURLProtocol.requestHandler = { request in
            tracker.record(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/group/Proxy/delay")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "url" })?.value, "https://example.com/generate_204")
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "timeout" })?.value, "5000")
            return try self.response(request, json: #"{"HK":123,"Timeout":0}"#)
        }
        let client = MihomoControllerClient(session: mockSession())

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(tracker.paths, ["/group/Proxy/delay"])
        XCTAssertEqual(nodes.map(\.name), ["HK", "Timeout"])
        XCTAssertEqual(nodes.map(\.delay), [123, 0])
        XCTAssertEqual(nodes.map(\.delayStatus), [.success, .timeout])
        XCTAssertNil(nodes[0].delayError)
        XCTAssertNotNil(nodes[1].delayError)
        XCTAssertEqual(nodes[0].type, "Shadowsocks", "batch results preserve node metadata")
    }

    func testGroupDelayFallsBackOnlyWhenBatchIsUnsupported() async throws {
        let group = ProxyGroup(name: "Proxy", proxies: [
            ProxyNode(name: "A"),
            ProxyNode(name: "B")
        ])
        let tracker = DelayRequestTracker()
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            tracker.record(path)
            switch path {
            case "/group/Proxy/delay":
                return try self.response(request, status: 405, json: #"{"message":"unsupported"}"#)
            case "/proxies/A/delay":
                return try self.response(request, json: #"{"delay":101}"#)
            case "/proxies/B/delay":
                return try self.response(request, json: #"{"delay":202}"#)
            default:
                XCTFail("Unexpected request: \(path)")
                throw KumoError.invalidArguments("Unexpected request: \(path)")
            }
        }
        let client = MihomoControllerClient(session: mockSession())

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(nodes.map(\.delay), [101, 202])
        XCTAssertEqual(nodes.map(\.delayStatus), [.success, .success])
        XCTAssertEqual(tracker.paths.first, "/group/Proxy/delay")
        XCTAssertEqual(tracker.paths.count, 3)
    }

    func testGroupDelayFallbackLimitsConcurrencyToEight() async throws {
        let group = ProxyGroup(
            name: "Proxy",
            proxies: (0..<20).map { ProxyNode(name: "Node-\($0)") }
        )
        let tracker = DelayRequestTracker()
        MockURLProtocol.asynchronousRequestHandler = { request, completion in
            let path = request.url?.path ?? ""
            if path == "/group/Proxy/delay" {
                completion(Result { try self.response(request, status: 404, json: #"{"message":"unsupported"}"#) })
                return
            }
            tracker.begin(path)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"delay":42}"#.utf8)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                tracker.end()
                completion(.success((response, data)))
            }
        }
        let client = MihomoControllerClient(session: mockSession())

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(nodes.count, 20)
        XCTAssertTrue(nodes.allSatisfy { $0.delayStatus == .success && $0.delay == 42 })
        XCTAssertEqual(tracker.activeRequestCount, 20)
        XCTAssertEqual(tracker.maximumActiveRequests, 8)
    }

    func testGroupDelayFallbackReportsHTTPFailuresWithoutReusingOldDelays() async throws {
        let names = ["NotFound", "RequestTimeout", "Unavailable", "GatewayTimeout"]
        let statuses = [404, 408, 503, 504]
        let group = ProxyGroup(
            name: "Proxy",
            proxies: names.map { ProxyNode(name: $0, delay: 111, delayStatus: .stale) }
        )
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/group/Proxy/delay" {
                return try self.response(request, status: 404, json: #"{"message":"unsupported"}"#)
            }
            guard let index = names.firstIndex(where: { path == "/proxies/\($0)/delay" }) else {
                XCTFail("Unexpected request: \(path)")
                throw KumoError.invalidArguments("Unexpected request: \(path)")
            }
            return try self.response(request, status: statuses[index], json: #"{"message":"failure"}"#)
        }
        let client = MihomoControllerClient(session: mockSession())

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(nodes.map(\.delayStatus), [.error, .timeout, .error, .timeout])
        XCTAssertEqual(nodes.map(\.delay), [nil, 0, nil, 0])
        for (index, node) in nodes.enumerated() {
            XCTAssertTrue(node.delayError?.contains("HTTP \(statuses[index])") == true)
            XCTAssertTrue(node.delayError?.contains("failure") == true)
            XCTAssertNotEqual(node.delay, 111, "an old delay must never stand in for a failed current test")
        }
    }

    func testGroupDelayDoesNotFallBackOnControllerFailures() async throws {
        for status in [408, 503, 504] {
            let group = ProxyGroup(name: "Proxy", proxies: [ProxyNode(name: "A")])
            let tracker = DelayRequestTracker()
            MockURLProtocol.requestHandler = { request in
                let path = request.url?.path ?? ""
                tracker.record(path)
                return try self.response(request, status: status, json: #"{"message":"controller down"}"#)
            }
            let client = MihomoControllerClient(session: mockSession())

            do {
                _ = try await client.groupDelay(group: group)
                XCTFail("HTTP \(status) must fail the group request")
            } catch {
                XCTAssertEqual(error as? KumoError, .controllerResponse(status, #"{"message":"controller down"}"#))
            }
            XCTAssertEqual(tracker.paths, ["/group/Proxy/delay"], "HTTP \(status) is not an unsupported-endpoint response")
        }
    }

    func testDelayPathsEncodeSlashWithinSingleSegments() async throws {
        let group = ProxyGroup(name: "Proxy/Asia", proxies: [ProxyNode(name: "HK/01")])
        let tracker = DelayRequestTracker()
        MockURLProtocol.requestHandler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            tracker.record(path)
            switch path {
            case "/group/Proxy%2FAsia/delay":
                return try self.response(request, status: 405, json: #"{"message":"unsupported"}"#)
            case "/proxies/HK%2F01/delay":
                return try self.response(request, json: #"{"delay":88}"#)
            default:
                XCTFail("Incorrectly encoded request path: \(path)")
                throw KumoError.invalidArguments("Incorrectly encoded request path: \(path)")
            }
        }
        let client = MihomoControllerClient(session: mockSession())

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(nodes.first?.delay, 88)
        XCTAssertEqual(nodes.first?.delayStatus, .success)
        XCTAssertEqual(Set(tracker.paths), ["/group/Proxy%2FAsia/delay", "/proxies/HK%2F01/delay"])
        XCTAssertFalse(tracker.paths.contains { $0.contains("%252F") })
    }

    func testMissingProxyReferencesAreMarkedAndNeverRequested() async throws {
        let client = MihomoControllerClient(session: mockSession())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/proxies")
            return try self.response(request, json: """
            {"proxies":{
              "Proxy":{"type":"Selector","all":["Present","Ghost"]},
              "Present":{"type":"Shadowsocks","history":[{"delay":77}]}
            }}
            """)
        }
        let groups = try await client.proxyGroups()
        let group = try XCTUnwrap(groups.first)

        XCTAssertEqual(group.proxies.map(\.delayStatus), [.stale, .missing])
        XCTAssertEqual(group.proxies.map(\.delay), [77, nil])
        XCTAssertTrue(group.proxies[1].delayError?.contains("missing from GET /proxies") == true)

        let tracker = DelayRequestTracker()
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            tracker.record(path)
            switch path {
            case "/group/Proxy/delay":
                return try self.response(request, status: 405, json: #"{"message":"unsupported"}"#)
            case "/proxies/Present/delay":
                return try self.response(request, json: #"{"delay":101}"#)
            default:
                XCTFail("A missing reference must not be requested: \(path)")
                throw KumoError.invalidArguments("Unexpected request: \(path)")
            }
        }

        let nodes = try await client.groupDelay(group: group)

        XCTAssertEqual(nodes.map(\.delayStatus), [.success, .missing])
        XCTAssertEqual(nodes.map(\.delay), [101, nil])
        XCTAssertFalse(tracker.paths.contains { $0.contains("Ghost") })
        XCTAssertEqual(tracker.paths.count, 2)
    }

    func testSingleProxyDelayStillThrowsRealHTTPErrors() async throws {
        for status in [404, 408, 503, 504] {
            MockURLProtocol.requestHandler = { request in
                try self.response(request, status: status, json: #"{"message":"single failure"}"#)
            }
            let client = MihomoControllerClient(session: mockSession())

            do {
                _ = try await client.proxyDelay(proxy: "A")
                XCTFail("HTTP \(status) must not be swallowed")
            } catch {
                XCTAssertEqual(error as? KumoError, .controllerResponse(status, #"{"message":"single failure"}"#))
            }
        }
    }

    func testDefaultControllerSessionDisablesSystemProxy() {
        let client = MihomoControllerClient()

        XCTAssertFalse(client.session === URLSession.shared)
        XCTAssertEqual(client.session.configuration.connectionProxyDictionary?.isEmpty, true)
    }

    func testReloadConfigurationUsesForcedPUTAndPathBody() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/configs")
            XCTAssertEqual(request.url?.query, "force=true")
            let body = try XCTUnwrap(request.kumo_bodyData)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["path"] as? String, "/tmp/kumo/config.yaml")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await MihomoControllerClient(session: mockSession()).reloadConfiguration(path: "/tmp/kumo/config.yaml")
    }

    private func response(
        _ request: URLRequest,
        status: Int = 200,
        json: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func parseTrafficSnapshot(_ text: String) throws -> TrafficSnapshot {
        let client = MihomoControllerClient()
        let snapshot = client.trafficSnapshot(from: text)
        return try XCTUnwrap(snapshot)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias HTTPResult = Result<(HTTPURLResponse, Data), Error>

    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var asynchronousRequestHandler: (
        (URLRequest, @escaping @Sendable (HTTPResult) -> Void) -> Void
    )?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let asynchronousRequestHandler = Self.asynchronousRequestHandler {
            asynchronousRequestHandler(request) { [self] result in
                complete(with: result)
            }
            return
        }
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: KumoError.invalidArguments("Missing mock request handler."))
            return
        }
        complete(with: Result { try requestHandler(request) })
    }

    private func complete(with result: HTTPResult) {
        switch result {
        case .success(let payload):
            client?.urlProtocol(self, didReceive: payload.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload.1)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class DelayRequestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var startedRequests = 0

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    var maximumActiveRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }

    var activeRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedRequests
    }

    func record(_ path: String) {
        lock.lock()
        recordedPaths.append(path)
        lock.unlock()
    }

    func begin(_ path: String) {
        lock.lock()
        recordedPaths.append(path)
        active += 1
        startedRequests += 1
        maximumActive = max(maximumActive, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}


private extension URLRequest {
    var kumo_bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
