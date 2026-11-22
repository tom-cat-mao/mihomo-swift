import SwiftUI
import KumoCoreKit

struct TopologyInspectorView: View {
    let graph: TopologyGraph
    let selectedNodeID: String?
    let showsDynamicMembers: Bool

    private var node: TopologyNode? {
        graph.nodes.first { $0.id == selectedNodeID }
    }
    private var labels: [String: String] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.label) })
    }
    private var incoming: [TopologyEdge] {
        relations.filter { $0.target == selectedNodeID }
    }
    private var outgoing: [TopologyEdge] {
        relations.filter { $0.source == selectedNodeID }
    }
    private var relations: [TopologyEdge] {
        graph.edges.filter { showsDynamicMembers || $0.kind != .dynamic || $0.broken }
    }
    private var issues: [TopologyIssue] {
        graph.issues.filter { issue in
            issue.missing == node?.label
                || issue.from.contains(node?.label ?? "")
        }
    }

    var body: some View {
        ScrollView {
            if let node {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.label)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(node.kind.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TopologyInspectorDetails(node: node)

                    if !issues.isEmpty {
                        TopologyRelationSection(title: "Issues") {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.message)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !incoming.isEmpty {
                        TopologyRelationSection(title: "Incoming") {
                            ForEach(incoming) { edge in
                                TopologyRelationRow(
                                    edge: edge,
                                    endpoint: labels[edge.source] ?? edge.source,
                                    direction: .incoming
                                )
                            }
                        }
                    }
                    if !outgoing.isEmpty {
                        TopologyRelationSection(title: "Outgoing") {
                            ForEach(outgoing) { edge in
                                TopologyRelationRow(
                                    edge: edge,
                                    endpoint: labels[edge.target] ?? edge.target,
                                    direction: .outgoing
                                )
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(
                    "Select a Node",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Relations and configuration details appear here.")
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TopologyInspectorDetails: View {
    let node: TopologyNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let type = node.type, !type.isEmpty {
                LabeledContent("Type", value: type)
            }
            if node.count > 0 {
                LabeledContent("Count", value: "\(node.count)")
            }
            if let selected = node.selected, !selected.isEmpty {
                LabeledContent("Selected", value: selected)
            }
            if let country = node.country {
                LabeledContent("Country", value: country)
            }
            if let payloads = node.payloads, !payloads.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Payloads")
                        .foregroundStyle(.secondary)
                    ForEach(payloads, id: \.self) { payload in
                        Text(payload)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.callout)
    }
}

private struct TopologyRelationSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private enum TopologyRelationDirection {
    case incoming
    case outgoing
}

private struct TopologyRelationRow: View {
    let edge: TopologyEdge
    let endpoint: String
    let direction: TopologyRelationDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: direction == .incoming ? "arrow.left" : "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(endpoint)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text(edge.kind.rawValue)
                if edge.active {
                    Text("active").foregroundStyle(Color.accentColor)
                }
                if edge.broken {
                    Text("broken").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
