import XCTest
@testable import KumoCoreKit

final class TopologyTests: XCTestCase {
    private let upstreamShape = """
    proxies:
      - {name: "🇯🇵 Tokyo", type: vless}
      - {name: "HK 01", type: ss}
      - {name: "US 01", type: trojan}
    proxy-providers:
      sub: {type: http, url: "https://example.com"}
    rule-providers:
      ads: {type: http, behavior: domain}
    proxy-groups:
      - {name: Proxy, type: select, proxies: [Auto, "🇯🇵 Tokyo", DIRECT]}
      - {name: Auto, type: url-test, include-all: true, filter: "HK|US"}
      - {name: Broken, type: select, proxies: [Nowhere], use: [gone]}
    rules:
      - RULE-SET,ads,REJECT
      - DOMAIN-SUFFIX,a.com,Proxy
      - DOMAIN-KEYWORD,b,Proxy
      - AND,((DOMAIN,c.com),(NETWORK,UDP)),DIRECT
      - RULE-SET,missing,Proxy
      - MATCH,Proxy
    """

    func testRuleModeClustersRulesAndMarksNestedDynamicActivePath() throws {
        let graph = try TopologyBuilder.build(
            yaml: upstreamShape,
            mode: .rule,
            selections: ["Proxy": "Auto", "Auto": "HK 01"]
        )

        let inline = try XCTUnwrap(node("rules:1", in: graph))
        XCTAssertEqual(inline.count, 2)
        XCTAssertEqual(inline.label, "Proxy")
        XCTAssertEqual(inline.type, "DOMAIN-SUFFIX, DOMAIN-KEYWORD")

        let logical = try XCTUnwrap(node("rules:3", in: graph))
        XCTAssertEqual(logical.label, "DIRECT")
        XCTAssertEqual(logical.payloads?.first, "((DOMAIN,c.com),(NETWORK,UDP))")
        XCTAssertNotNil(edge(from: "rules:3", to: "builtin:DIRECT", in: graph))

        let nested = try XCTUnwrap(edge(from: "group:Proxy", to: "group:Auto", in: graph))
        XCTAssertTrue(nested.active)
        let dynamic = try XCTUnwrap(edge(from: "group:Auto", to: "proxy:HK 01", in: graph))
        XCTAssertEqual(dynamic.kind, .dynamic)
        XCTAssertTrue(dynamic.active)
        XCTAssertNil(edge(from: "group:Auto", to: "proxy:🇯🇵 Tokyo", in: graph))
        XCTAssertEqual(node("group:Auto", in: graph)?.count, 2)
        XCTAssertEqual(node("proxy:🇯🇵 Tokyo", in: graph)?.country, "JP")

        XCTAssertNotNil(node("ruleset:ads@0", in: graph))
        XCTAssertNotNil(node("ruleset:missing@4", in: graph))
        XCTAssertEqual(graph.issues.count, 3)
        XCTAssertTrue(graph.issues.contains { $0.missing == "Nowhere" })
        XCTAssertTrue(graph.issues.contains { $0.missing == "gone" })
        XCTAssertTrue(graph.issues.contains { $0.missing == "missing" })
        XCTAssertTrue(edge(from: "group:Broken", to: "missing:Nowhere", in: graph)?.broken == true)
        XCTAssertEqual(graph.nodes.map(\.column.rawValue), graph.nodes.map(\.column.rawValue).sorted())
    }

    func testCurrentProfileStyleFindsMissingGroupAndNodeWithoutHidingRuleSet() throws {
        let yaml = """
        proxies:
          - name: 🇭🇰 tomcat-hk-server-hysteria2
            type: hysteria2
        rule-providers:
          apple: {type: http, behavior: domain}
        proxy-groups:
          - name: 🚀 节点选择
            type: select
            proxies: [⚡ 自动选择, 不存在的嵌套组, 不存在的节点, DIRECT]
          - name: ⚡ 自动选择
            type: url-test
            include-all-proxies: true
          - name: 🐟 漏网之鱼
            type: select
            proxies: [🚀 节点选择]
        rules:
          - RULE-SET,apple,🚀 节点选择
          - MATCH,🐟 漏网之鱼
        """

        let graph = try TopologyBuilder.build(
            yaml: yaml,
            mode: .rule,
            selections: ["🚀 节点选择": "⚡ 自动选择", "⚡ 自动选择": "🇭🇰 tomcat-hk-server-hysteria2"]
        )

        XCTAssertNotNil(edge(from: "group:🚀 节点选择", to: "group:⚡ 自动选择", in: graph))
        XCTAssertTrue(edge(from: "group:🚀 节点选择", to: "missing:不存在的嵌套组", in: graph)?.broken == true)
        XCTAssertTrue(edge(from: "group:🚀 节点选择", to: "missing:不存在的节点", in: graph)?.broken == true)
        XCTAssertEqual(Set(graph.issues.map(\.missing)), ["不存在的嵌套组", "不存在的节点"])
        XCTAssertEqual(node("ruleset:apple@0", in: graph)?.kind, .ruleSet)
        XCTAssertTrue(edge(from: "group:⚡ 自动选择", to: "proxy:🇭🇰 tomcat-hk-server-hysteria2", in: graph)?.active == true)
        XCTAssertTrue(edge(from: "final", to: "group:🐟 漏网之鱼", in: graph) != nil)
    }

    func testGlobalAndDirectModesOnlyActivateReachableSelections() throws {
        let global = try TopologyBuilder.build(
            yaml: upstreamShape,
            mode: .global,
            selections: ["GLOBAL": "Proxy", "Proxy": "Auto"]
        )
        XCTAssertTrue(edge(from: "entry", to: "global", in: global)?.active == true)
        XCTAssertTrue(edge(from: "global", to: "group:Proxy", in: global)?.active == true)

        let direct = try TopologyBuilder.build(
            yaml: upstreamShape,
            mode: .direct,
            selections: ["Proxy": "Auto"]
        )
        XCTAssertTrue(edge(from: "entry", to: "builtin:DIRECT", in: direct)?.active == true)
        XCTAssertFalse(edge(from: "group:Proxy", to: "group:Auto", in: direct)?.active == true)
    }

    func testStableCodableShapeRoundTripsGraph() throws {
        let graph = try TopologyBuilder.build(
            yaml: upstreamShape,
            mode: .rule,
            selections: ["Proxy": "Auto"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["mode"] as? String, "rule")
        XCTAssertNotNil(object["nodes"] as? [[String: Any]])
        XCTAssertNotNil(object["edges"] as? [[String: Any]])
        XCTAssertNotNil(object["issues"] as? [[String: Any]])
        XCTAssertEqual(try JSONDecoder().decode(TopologyGraph.self, from: data), graph)
    }

    func testStoppedControllerUsesGeneratedConfigurationAndOverrides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-topology-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KumoPaths(applicationSupportDirectory: root, launchAgentsDirectory: root)
        let repository = ProfileRepository(paths: paths)
        try repository.saveDefaultProfile(Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            proxies: []
            proxy-groups:
              - name: Proxy
                type: select
                proxies: [DIRECT]
            rules:
              - MATCH,Proxy
            """
        ))
        let controller = KumoController(paths: paths, useServiceBackend: false)
        _ = try controller.addLocalOverride(
            name: "broken",
            format: .yaml,
            content: """
            +rules:
              - DOMAIN-SUFFIX,example.com,Missing Group
            """,
            isGlobal: false
        )

        let graph = try await controller.topology()

        XCTAssertEqual(graph.mode, "rule")
        XCTAssertEqual(graph.nodes.first(where: { $0.kind == .rules })?.label, "Missing Group")
        XCTAssertEqual(graph.nodes.first(where: { $0.kind == .final })?.label, "Proxy")
        XCTAssertTrue(graph.issues.contains { $0.missing == "Missing Group" })
        XCTAssertNil(graph.nodes.first(where: { $0.id == "group:Proxy" })?.selected)
        XCTAssertFalse(graph.edges.contains(where: \.active))
    }

    private func node(_ id: String, in graph: TopologyGraph) -> TopologyNode? {
        graph.nodes.first { $0.id == id }
    }

    private func edge(from source: String, to target: String, in graph: TopologyGraph) -> TopologyEdge? {
        graph.edges.first { $0.source == source && $0.target == target }
    }
}
