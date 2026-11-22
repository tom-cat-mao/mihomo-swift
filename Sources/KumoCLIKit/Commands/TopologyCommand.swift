import ArgumentParser
import KumoCoreKit

extension KumoCommand {
    struct Topology: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show how traffic flows through rules, groups, and nodes.",
            aliases: ["graph"]
        )

        @Flag(name: .long, help: "List only unresolved proxy, group, provider, or rule-set references.")
        var issues = false
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let graph = try await CLIRuntime.current.controller.topology()
            if issues {
                CLIRuntime.current.write(graph.issues, text: Self.issuesText)
            } else {
                CLIRuntime.current.write(graph, text: Self.summaryText)
            }
        }

        static func summaryText(_ graph: TopologyGraph) -> String {
            let labels = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.label) })
            let ruleCount = graph.nodes.filter { [.rules, .ruleSet, .final].contains($0.kind) }.count
            var lines = [
                "mode: \(graph.mode)",
                "rule nodes: \(ruleCount)",
                "groups: \(graph.nodes.filter { $0.kind == .group }.count)",
                "proxies: \(graph.nodes.filter { $0.kind == .proxy }.count)",
                "providers: \(graph.nodes.filter { $0.kind == .provider }.count)",
                "issues: \(graph.issues.count)"
            ]
            let active = graph.edges.filter { $0.active && $0.kind != .route }
            if !active.isEmpty {
                lines.append("")
                lines.append("Active path")
                lines.append(contentsOf: active.map { edge in
                    "  \(labels[edge.source] ?? edge.source) → \(labels[edge.target] ?? edge.target)"
                })
            }
            return lines.joined(separator: "\n")
        }

        static func issuesText(_ issues: [TopologyIssue]) -> String {
            guard !issues.isEmpty else { return "[ok] every reference resolves" }
            return issues.map { "[warn] \($0.message)" }.joined(separator: "\n")
        }
    }
}
