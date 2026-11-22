import SwiftUI
import KumoCoreKit

struct TopologyGraphView: View {
    let graph: TopologyGraph
    let searchText: String
    @Binding var selectedNodeID: String?
    @State private var expandedColumns: Set<Int> = []

    private let columns: [(TopologyColumn, String)] = [
        (.entry, "Entry"),
        (.rules, "Rules"),
        (.groups, "Groups"),
        (.nodes, "Outbound")
    ]
    private var activeNodeIDs: Set<String> {
        var reached: Set<String> = ["entry"]
        var changed = true
        while changed {
            changed = false
            for edge in graph.edges {
                let follows = edge.active || (edge.kind == .route && graph.mode == OutboundMode.rule.rawValue)
                if follows && reached.contains(edge.source) && !reached.contains(edge.target) {
                    reached.insert(edge.target)
                    changed = true
                }
            }
        }
        return reached
    }
    private var dynamicNodeIDs: Set<String> {
        Set(graph.edges.filter { $0.kind == .dynamic }.map(\.target))
    }
    private var hasMatches: Bool {
        graph.nodes.contains { matches($0) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(columns, id: \.0.rawValue) { column, title in
                    if column != .entry {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 10)
                            .accessibilityHidden(true)
                    }
                    TopologyColumnView(
                        title: title,
                        column: column,
                        nodes: graph.nodes.filter { $0.column == column },
                        searchText: searchText,
                        activeNodeIDs: activeNodeIDs,
                        dynamicNodeIDs: dynamicNodeIDs,
                        selectedNodeID: $selectedNodeID,
                        isExpanded: expandedColumns.contains(column.rawValue),
                        onToggleExpanded: { toggleColumn(column) }
                    )
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if !searchText.isEmpty && !hasMatches {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .onChange(of: graph.nodes.map(\.id)) { _, ids in
            if let selectedNodeID, !ids.contains(selectedNodeID) {
                self.selectedNodeID = "entry"
            }
        }
    }

    private func toggleColumn(_ column: TopologyColumn) {
        if expandedColumns.contains(column.rawValue) {
            expandedColumns.remove(column.rawValue)
        } else {
            expandedColumns.insert(column.rawValue)
        }
    }

    private func matches(_ node: TopologyNode) -> Bool {
        searchText.isEmpty
            || node.label.localizedCaseInsensitiveContains(searchText)
            || node.type?.localizedCaseInsensitiveContains(searchText) == true
            || node.payloads?.contains { $0.localizedCaseInsensitiveContains(searchText) } == true
    }
}

private struct TopologyColumnView: View {
    let title: String
    let column: TopologyColumn
    let nodes: [TopologyNode]
    let searchText: String
    let activeNodeIDs: Set<String>
    let dynamicNodeIDs: Set<String>
    @Binding var selectedNodeID: String?
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    private var matchingNodes: [TopologyNode] {
        guard !searchText.isEmpty else { return nodes }
        return nodes.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.type?.localizedCaseInsensitiveContains(searchText) == true
                || $0.payloads?.contains { $0.localizedCaseInsensitiveContains(searchText) } == true
        }
    }
    private var visibleNodes: [TopologyNode] {
        guard searchText.isEmpty, !isExpanded, matchingNodes.count > 12 else {
            return matchingNodes
        }
        let required = matchingNodes.filter {
            $0.kind == .missing || activeNodeIDs.contains($0.id)
        }
        let requiredIDs = Set(required.map(\.id))
        let remaining = matchingNodes.filter { !requiredIDs.contains($0.id) }
            .prefix(max(0, 12 - required.count))
        return (required + remaining).sorted { $0.order < $1.order }
    }
    private var hiddenCount: Int {
        matchingNodes.count - visibleNodes.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleNodes) { node in
                        TopologyNodeCard(
                            node: node,
                            isActive: activeNodeIDs.contains(node.id),
                            isDynamic: dynamicNodeIDs.contains(node.id),
                            isSelected: selectedNodeID == node.id
                        ) {
                            selectedNodeID = node.id
                        }
                    }
                    if hiddenCount > 0 {
                        Button("Show \(hiddenCount) more", action: onToggleExpanded)
                            .buttonStyle(.link)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 224)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct TopologyNodeCard: View {
    let node: TopologyNode
    let isActive: Bool
    let isDynamic: Bool
    let isSelected: Bool
    let action: () -> Void

    private var borderColor: Color {
        if node.kind == .missing { return .red }
        if isSelected || isActive { return .accentColor }
        return .secondary.opacity(0.35)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbolName)
                        .foregroundStyle(node.kind == .missing ? .red : .secondary)
                        .accessibilityHidden(true)
                    Text(node.label)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isDynamic {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dynamic member")
                    }
                }
                HStack(spacing: 6) {
                    Text(node.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let type = node.type, !type.isEmpty {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if node.count > 0 {
                        Text("\(node.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let selected = node.selected, !selected.isEmpty {
                    Text(selected)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 210, alignment: .leading)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        borderColor,
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isDynamic && !isActive ? [4] : [])
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.label)
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbolName: String {
        switch node.kind {
        case .entry: "arrow.right.circle"
        case .ruleSet: "shippingbox"
        case .rules, .final: "list.bullet"
        case .group, .global: "point.3.connected.trianglepath.dotted"
        case .proxy: "server.rack"
        case .provider: "externaldrive"
        case .builtin: "checkmark.circle"
        case .missing: "exclamationmark.triangle"
        }
    }

    private var accessibilityState: String {
        var states: [String] = []
        if isActive { states.append("active") }
        if isDynamic { states.append("dynamic") }
        if node.kind == .missing { states.append("missing reference") }
        return states.joined(separator: ", ")
    }
}
