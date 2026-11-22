import SwiftUI
import KumoCoreKit

struct TopologyView: View {
    @Environment(KumoAppStore.self) private var store
    @State private var searchText = ""
    @State private var selectedNodeID: String? = "entry"
    @State private var showsDynamicMembers = false

    var body: some View {
        KumoPage(title: "Topology") {
            if let graph = store.topology {
                VStack(alignment: .leading, spacing: 12) {
                    TopologyIssueList(issues: graph.issues, onSelect: selectIssue)
                    HSplitView {
                        TopologyGraphView(
                            graph: graph,
                            searchText: searchText,
                            selectedNodeID: $selectedNodeID
                        )
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                        TopologyInspectorView(
                            graph: graph,
                            selectedNodeID: selectedNodeID,
                            showsDynamicMembers: showsDynamicMembers
                        )
                        .frame(minWidth: 240, maxWidth: 360, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                KumoEmptyState(
                    title: "Topology Unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    message: "Refresh to inspect the generated configuration."
                ) {
                    Button(String(localized: "Refresh")) {
                        Task { await store.loadTopology() }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search topology")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(String(localized: "Dynamic members"), isOn: $showsDynamicMembers)
                    .toggleStyle(.checkbox)
                    .help(String(localized: "Show members resolved from include-all and filters"))
            }
        }
        .task {
            await store.loadTopology()
        }
    }

    private func selectIssue(_ issue: TopologyIssue) {
        guard let graph = store.topology else { return }
        let missingID = "missing:\(issue.missing)"
        if graph.nodes.contains(where: { $0.id == missingID }) {
            selectedNodeID = missingID
        } else {
            selectedNodeID = graph.nodes.first {
                $0.kind == .ruleSet && $0.label == issue.missing
            }?.id
        }
    }
}

private struct TopologyIssueList: View {
    let issues: [TopologyIssue]
    let onSelect: (TopologyIssue) -> Void
    @State private var isExpanded = true

    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Button {
                                onSelect(issue)
                            } label: {
                                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(issue.message)
                            .help(issue.from)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxHeight: 160)
            } label: {
                Label("Issues (\(issues.count))", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
