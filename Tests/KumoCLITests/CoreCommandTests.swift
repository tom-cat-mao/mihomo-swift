import XCTest
@testable import KumoCLIKit
import KumoCoreKit

/// `kumo proxies --geo` and `kumo connections close --ids` behavior.
///
/// Geo tests inject a stub `ProxyGeoFetching` so the lookup path never
/// touches the network.
final class CoreCommandTests: XCTestCase {
    // MARK: - Parsing

    func testProxiesGeoFlagParsesAndDefaultsOff() throws {
        let plain = try XCTUnwrap(try KumoCommand.parseAsRoot(["proxies"]) as? KumoCommand.Proxies)
        XCTAssertFalse(plain.geo)

        let geo = try XCTUnwrap(try KumoCommand.parseAsRoot(["proxy", "--geo", "--json"]) as? KumoCommand.Proxies)
        XCTAssertTrue(geo.geo)
        XCTAssertTrue(geo.options.json)
    }

    func testConnectionsCloseParsesIDList() throws {
        let command = try XCTUnwrap(
            try KumoCommand.parseAsRoot(["connections", "close", "--ids", "a1, b2 ,c3", "--json"]) as? KumoCommand.Connections.Close
        )
        XCTAssertEqual(try KumoCommand.Connections.Close.parseIDs(command.ids), ["a1", "b2", "c3"])
        XCTAssertTrue(command.options.json)
    }

    func testConnectionsCloseRejectsMissingOrEmptyIDs() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["connections", "close"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["connections", "close", "--ids", " , "]))
    }

    func testConnectionsExistingFlagSurfaceKeepsParsing() throws {
        let close = try XCTUnwrap(
            try KumoCommand.parseAsRoot(["connections", "--close", "abc"]) as? KumoCommand.Connections
        )
        XCTAssertEqual(close.close, "abc")
        XCTAssertFalse(close.closeAll)

        let all = try XCTUnwrap(
            try KumoCommand.parseAsRoot(["connections", "--close-all", "--json"]) as? KumoCommand.Connections
        )
        XCTAssertTrue(all.closeAll)

        // List mode (no flags) still parses as the parent command.
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["connections", "--json"]))
    }

    // MARK: - ID parsing

    func testConnectionsCloseParseIDsTrimsAndDeduplicates() throws {
        XCTAssertEqual(
            try KumoCommand.Connections.Close.parseIDs(" a1, b2 ,,a1, c3 "),
            ["a1", "b2", "c3"]
        )
        XCTAssertThrowsError(try KumoCommand.Connections.Close.parseIDs("")) { error in
            XCTAssertEqual(
                String(describing: error),
                "--ids must contain at least one connection id."
            )
        }
    }

    // MARK: - Batch close

    func testConnectionsCloseReportsPartialFailuresAndContinues() async {
        let report = await KumoCommand.Connections.Close.perform(ids: ["a", "b", "c"]) { id in
            if id == "b" {
                throw KumoError.coreNotRunning
            }
        }

        XCTAssertEqual(report.closed, ["a", "c"], "a bad id must not abort the remaining ids")
        XCTAssertEqual(report.failed.map(\.id), ["b"])
        XCTAssertEqual(report.failed.first?.error, "Mihomo core is not running.")
    }

    func testConnectionsCloseReportsEveryIDWhenAllFail() async {
        let report = await KumoCommand.Connections.Close.perform(ids: ["a", "b"]) { _ in
            throw KumoError.coreNotRunning
        }

        XCTAssertTrue(report.closed.isEmpty)
        XCTAssertEqual(report.failed.map(\.id), ["a", "b"])
    }

    func testConnectionsCloseKeepsBridgedErrorsReadable() async {
        // URLSession failures arrive as NSErrors with a localized
        // description; the full UserInfo dump must not leak into the report.
        let bridged = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server.", "UserInfo": "raw"]
        )
        let report = await KumoCommand.Connections.Close.perform(ids: ["a"]) { _ in
            throw bridged
        }

        let message = report.failed.first?.error ?? ""
        XCTAssertEqual(message, "Could not connect to the server.")
        XCTAssertFalse(message.contains("UserInfo"), "the raw NSError dump must not leak: \(message)")
    }

    func testConnectionCloseReportEncodesStableKeys() throws {
        let report = ConnectionCloseReport(
            closed: ["a"],
            failed: [ConnectionCloseFailure(id: "b", error: "boom")]
        )
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["closed"] as? [String], ["a"])
        let failed = try XCTUnwrap(object["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.first?["id"] as? String, "b")
        XCTAssertEqual(failed.first?["error"] as? String, "boom")
    }

    // MARK: - Geo gating

    func testGeoResolveIsSkippedWithoutTheFlag() async throws {
        let fetcher = GeoFetcherStub(countries: ["hk.example.com": "HK"])
        let lookup = ProxyGeoLookup(cacheURL: Self.makeTempCacheURL(), fetcher: fetcher)
        let latch = Latch()
        let groups = [
            ProxyGroup(name: "Proxy", selectedProxyName: "HK-01", proxies: [ProxyNode(name: "HK-01")])
        ]

        let resolved = try await KumoCommand.Proxies.resolve(
            groups: groups,
            geo: false,
            nodes: {
                latch.isSet = true
                return ["HK-01": ProfileNodeInfo(name: "HK-01", server: "hk.example.com", port: 443)]
            },
            lookup: { lookup }
        )

        XCTAssertEqual(resolved, groups)
        XCTAssertFalse(latch.isSet, "the profile must not be parsed without --geo")
        let requested = await fetcher.requestedHosts
        XCTAssertTrue(requested.isEmpty, "no hostname may be sent without --geo")
    }

    func testGeoResolveStampsCountriesAndDeduplicatesServerLookups() async throws {
        let fetcher = GeoFetcherStub(countries: [
            "hk.example.com": "HK",
            "us.example.com": "US"
        ])
        let lookup = ProxyGeoLookup(cacheURL: Self.makeTempCacheURL(), fetcher: fetcher)
        let groups = [
            ProxyGroup(name: "Auto", selectedProxyName: "HK-01", proxies: [
                ProxyNode(name: "HK-01"),
                ProxyNode(name: "HK-Backup"),
                ProxyNode(name: "US-01"),
                ProxyNode(name: "DIRECT")
            ])
        ]
        let nodes = [
            "HK-01": ProfileNodeInfo(name: "HK-01", server: "hk.example.com", port: 443),
            "HK-Backup": ProfileNodeInfo(name: "HK-Backup", server: "HK.example.com", port: 8443),
            "US-01": ProfileNodeInfo(name: "US-01", server: "us.example.com", port: 443)
        ]

        let resolved = try await KumoCommand.Proxies.resolve(
            groups: groups,
            geo: true,
            nodes: { nodes },
            lookup: { lookup }
        )

        XCTAssertEqual(
            resolved.first?.proxies.map(\.detectedCountry),
            ["HK", "HK", "US", nil],
            "a node with no profile server stays unresolved"
        )
        let requested = await fetcher.requestedHosts.sorted()
        XCTAssertEqual(
            requested,
            ["hk.example.com", "us.example.com"],
            "two nodes sharing an upstream server must resolve it once"
        )
    }

    func testProxiesTextShapesKeepLegacyOutputWithoutGeo() {
        let groups = [
            ProxyGroup(name: "Proxy", selectedProxyName: "HK-01", proxies: [
                ProxyNode(name: "HK-01", detectedCountry: "HK"),
                ProxyNode(name: "US-01")
            ])
        ]

        XCTAssertEqual(KumoCommand.Proxies.text(groups), "Proxy: HK-01")
        XCTAssertEqual(
            KumoCommand.Proxies.geoText(groups),
            "Proxy: HK-01\n  HK-01 [HK]\n  US-01"
        )
    }

    // MARK: - Helpers

    private static func makeTempCacheURL() -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kumo-cli-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp.appendingPathComponent("proxy-geo-cache.json")
    }
}

/// Records a one-way side effect from a `@Sendable` closure.
private final class Latch: @unchecked Sendable {
    var isSet = false
}

/// Stub geo fetcher: answers from a fixed map and records every requested
/// host so tests can prove no lookup (and no network) happened.
private actor GeoFetcherStub: ProxyGeoFetching {
    private let countries: [String: String]
    private(set) var requestedHosts: [String] = []

    init(countries: [String: String]) {
        self.countries = Dictionary(uniqueKeysWithValues: countries.map { ($0.key.lowercased(), $0.value) })
    }

    func countryCode(for hostOrIP: String) async throws -> String? {
        let key = hostOrIP.lowercased()
        requestedHosts.append(key)
        return countries[key]
    }
}
