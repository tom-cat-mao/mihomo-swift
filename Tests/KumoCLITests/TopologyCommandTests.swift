import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class TopologyCommandTests: XCTestCase {
    func testTopologyFlagsAndAliasParse() throws {
        let plain = try XCTUnwrap(try KumoCommand.parseAsRoot(["topology", "--json"]) as? KumoCommand.Topology)
        XCTAssertFalse(plain.issues)
        XCTAssertTrue(plain.options.json)

        let issues = try XCTUnwrap(try KumoCommand.parseAsRoot(["graph", "--issues", "--json"]) as? KumoCommand.Topology)
        XCTAssertTrue(issues.issues)
        XCTAssertTrue(issues.options.json)
    }

    func testTopologyHelpCoversCommandAndIssues() {
        XCTAssertTrue(HelpText.topLevel.contains("topology"))
        XCTAssertTrue(HelpText.long.contains("kumo topology --issues [--json]"))
        XCTAssertTrue(HelpText.topic(["graph"]).contains("TopologyGraph"))
        XCTAssertTrue(CommandIndex.completionWords.contains("topology"))
        XCTAssertTrue(CommandIndex.completionWords.contains("graph"))
    }

    func testTopologyTextSummarizesCountsAndActiveSelections() throws {
        let graph = try TopologyBuilder.build(
            yaml: """
            proxies:
              - {name: HK, type: ss}
            proxy-providers:
              airport: {type: http}
            proxy-groups:
              - {name: Proxy, type: select, proxies: [HK, Missing]}
            rules:
              - MATCH,Proxy
            """,
            mode: .rule,
            selections: ["Proxy": "HK"]
        )

        let text = KumoCommand.Topology.summaryText(graph)
        XCTAssertTrue(text.contains("mode: rule"))
        XCTAssertTrue(text.contains("rule nodes: 1"))
        XCTAssertTrue(text.contains("groups: 1"))
        XCTAssertTrue(text.contains("proxies: 1"))
        XCTAssertTrue(text.contains("providers: 1"))
        XCTAssertTrue(text.contains("issues: 1"))
        XCTAssertTrue(text.contains("Proxy → HK"))
        XCTAssertTrue(KumoCommand.Topology.issuesText(graph.issues).contains("Missing"))
        XCTAssertEqual(KumoCommand.Topology.issuesText([]), "[ok] every reference resolves")
    }
}
