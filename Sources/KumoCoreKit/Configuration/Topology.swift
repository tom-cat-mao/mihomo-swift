import Foundation
import Yams

public enum TopologyNodeKind: String, Codable, Sendable {
    case entry
    case ruleSet
    case rules
    case final
    case group
    case proxy
    case provider
    case builtin
    case missing
    case global
}

public enum TopologyColumn: Int, Codable, Sendable {
    case entry = 0
    case rules = 1
    case groups = 2
    case nodes = 3
}

public struct TopologyNode: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: TopologyNodeKind
    public var column: TopologyColumn
    public var label: String
    public var type: String?
    public var count: Int
    public var country: String?
    public var order: Int
    public var selected: String?
    public var payloads: [String]?

    public init(
        id: String,
        kind: TopologyNodeKind,
        column: TopologyColumn,
        label: String,
        type: String? = nil,
        count: Int = 0,
        country: String? = nil,
        order: Int = 0,
        selected: String? = nil,
        payloads: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.column = column
        self.label = label
        self.type = type
        self.count = count
        self.country = country
        self.order = order
        self.selected = selected
        self.payloads = payloads
    }
}

public enum TopologyEdgeKind: String, Codable, Sendable {
    case route
    case member
    case provider
    case dynamic
}

public struct TopologyEdge: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var target: String
    public var kind: TopologyEdgeKind
    public var active: Bool
    public var broken: Bool

    public init(
        id: String = "",
        source: String,
        target: String,
        kind: TopologyEdgeKind,
        active: Bool = false,
        broken: Bool = false
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
        self.active = active
        self.broken = broken
    }
}

public struct TopologyIssue: Codable, Equatable, Sendable {
    public var from: String
    public var missing: String
    public var message: String

    public init(from: String, missing: String, message: String) {
        self.from = from
        self.missing = missing
        self.message = message
    }
}

/// A stable, layout-independent description of how traffic flows through the
/// generated Mihomo configuration. Runtime selections only add active state;
/// they never replace the configuration's nodes or references.
public struct TopologyGraph: Codable, Equatable, Sendable {
    public var mode: String
    public var nodes: [TopologyNode]
    public var edges: [TopologyEdge]
    public var issues: [TopologyIssue]

    public init(
        mode: String,
        nodes: [TopologyNode] = [],
        edges: [TopologyEdge] = [],
        issues: [TopologyIssue] = []
    ) {
        self.mode = mode
        self.nodes = nodes
        self.edges = edges
        self.issues = issues
    }
}

public enum TopologyBuilder {
    public static func build(
        yaml: String,
        mode: OutboundMode,
        selections: [String: String] = [:]
    ) throws -> TopologyGraph {
        let document = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
        var builder = Builder(mode: mode, selections: selections)
        builder.collect(document)
        builder.addEntry()
        builder.addGroups()
        builder.addRules(document)
        return builder.finish()
    }
}

private struct Builder {
    let mode: OutboundMode
    let selections: [String: String]
    var graph: TopologyGraph
    var nodeIDs: Set<String> = []
    var edgeIDs: Set<String> = []

    var proxyNames: [String] = []
    var proxyNameSet: Set<String> = []
    var groupNames: [String] = []
    var groupDefinitions: [String: [String: Any]] = [:]
    var providerNames: [String] = []
    var providerNameSet: Set<String> = []
    var ruleProviders: [String: String] = [:]

    init(mode: OutboundMode, selections: [String: String]) {
        self.mode = mode
        self.selections = selections
        self.graph = TopologyGraph(mode: mode.rawValue)
    }

    mutating func collect(_ configuration: [String: Any]) {
        for case let proxy as [String: Any] in sequence(configuration["proxies"]) {
            guard let name = scalar(proxy["name"]), !name.isEmpty else { continue }
            proxyNames.append(name)
            proxyNameSet.insert(name)
            addNode(TopologyNode(
                id: Self.proxyID(name),
                kind: .proxy,
                column: .nodes,
                label: name,
                type: scalar(proxy["type"]),
                country: ProxyCountry.code(for: name)
            ))
        }

        if let providers = mapping(configuration["proxy-providers"]) {
            for name in providers.keys.sorted() {
                providerNames.append(name)
                providerNameSet.insert(name)
                addNode(TopologyNode(
                    id: Self.providerID(name),
                    kind: .provider,
                    column: .nodes,
                    label: name,
                    type: scalar(providers[name].flatMap(mapping))
                ))
            }
        }

        if let providers = mapping(configuration["rule-providers"]) {
            for (name, value) in providers {
                ruleProviders[name] = mapping(value).flatMap { scalar($0["behavior"]) } ?? ""
            }
        }

        for case let group as [String: Any] in sequence(configuration["proxy-groups"]) {
            guard let name = scalar(group["name"]), !name.isEmpty else { continue }
            groupNames.append(name)
            groupDefinitions[name] = group
        }
    }

    mutating func addEntry() {
        addNode(TopologyNode(id: "entry", kind: .entry, column: .entry, label: mode.rawValue))
    }

    mutating func addGroups() {
        for name in groupNames {
            guard let definition = groupDefinitions[name] else { continue }
            let id = Self.groupID(name)
            let members = strings(definition["proxies"])
            let uses = strings(definition["use"])
            addNode(TopologyNode(
                id: id,
                kind: .group,
                column: .groups,
                label: name,
                type: scalar(definition["type"]),
                selected: selections[name]
            ))
            var count = members.count

            for member in members {
                let (target, resolves) = policy(member, from: "group \(quoted(name))")
                addEdge(TopologyEdge(
                    source: id,
                    target: target,
                    kind: .member,
                    active: selections[name] == member,
                    broken: !resolves
                ))
            }

            for provider in uses {
                guard providerNameSet.contains(provider) else {
                    let target = addMissing(
                        provider,
                        from: "group \(quoted(name))",
                        message: "group \(quoted(name)) uses provider \(quoted(provider)), which the configuration does not define"
                    )
                    addEdge(TopologyEdge(source: id, target: target, kind: .provider, broken: true))
                    continue
                }
                addEdge(TopologyEdge(source: id, target: Self.providerID(provider), kind: .provider))
            }

            let includeAll = truthy(definition["include-all"])
            let includeProxies = includeAll || truthy(definition["include-all-proxies"])
            let includeProviders = includeAll || truthy(definition["include-all-providers"])
            let filter = regularExpression(scalar(definition["filter"]))
            let exclude = regularExpression(scalar(definition["exclude-filter"]))

            if includeProxies {
                for proxy in proxyNames where !members.contains(proxy) && matches(filter, exclude, proxy) {
                    count += 1
                    addEdge(TopologyEdge(
                        source: id,
                        target: Self.proxyID(proxy),
                        kind: .dynamic,
                        active: selections[name] == proxy
                    ))
                }
            }
            if includeProviders {
                for provider in providerNames where !uses.contains(provider) {
                    addEdge(TopologyEdge(source: id, target: Self.providerID(provider), kind: .dynamic))
                }
            }
            setCount(count + uses.count, for: id)
        }
    }

    mutating func addRules(_ configuration: [String: Any]) {
        switch mode {
        case .global:
            let target: String
            if groupDefinitions["GLOBAL"] != nil {
                target = Self.groupID("GLOBAL")
            } else {
                target = "global"
                addNode(TopologyNode(
                    id: target,
                    kind: .global,
                    column: .groups,
                    label: "GLOBAL",
                    selected: selections["GLOBAL"]
                ))
                for name in groupNames + proxyNames {
                    let (id, _) = policy(name, from: "GLOBAL")
                    addEdge(TopologyEdge(
                        source: target,
                        target: id,
                        kind: .member,
                        active: selections["GLOBAL"] == name
                    ))
                }
            }
            addEdge(TopologyEdge(source: "entry", target: target, kind: .route, active: true))
        case .direct:
            let (target, _) = policy("DIRECT", from: "mode")
            addEdge(TopologyEdge(source: "entry", target: target, kind: .route, active: true))
        case .rule:
            break
        }

        struct Cluster {
            var id: String
            var target: String
            var types: [String] = []
            var payloads: [String] = []
            var count = 0
        }
        var current: Cluster?

        func flush() {
            guard let cluster = current else { return }
            addNode(TopologyNode(
                id: cluster.id,
                kind: .rules,
                column: .rules,
                label: cluster.target,
                type: cluster.types.joined(separator: ", "),
                count: cluster.count,
                payloads: cluster.payloads
            ))
            linkRule(cluster.id, target: cluster.target)
            current = nil
        }

        for (index, item) in sequence(configuration["rules"]).enumerated() {
            guard let rule = item as? String else { continue }
            let parts = Self.splitRule(rule)
            guard parts.count >= 2 else { continue }
            let kind = parts[0].uppercased()

            switch kind {
            case "MATCH", "FINAL":
                flush()
                addNode(TopologyNode(
                    id: "final",
                    kind: .final,
                    column: .rules,
                    label: parts[1],
                    type: "MATCH"
                ))
                linkRule("final", target: parts[1])
                continue
            case "RULE-SET":
                flush()
                guard parts.count >= 3 else { continue }
                let name = parts[1]
                let id = "ruleset:\(name)@\(index)"
                addNode(TopologyNode(
                    id: id,
                    kind: .ruleSet,
                    column: .rules,
                    label: name,
                    type: ruleProviders[name],
                    payloads: [parts[2]]
                ))
                if ruleProviders[name] == nil {
                    graph.issues.append(TopologyIssue(
                        from: "rules",
                        missing: name,
                        message: "RULE-SET \(quoted(name)) is not defined in rule-providers"
                    ))
                }
                linkRule(id, target: parts[2])
                continue
            default:
                break
            }

            guard parts.count >= 3 else { continue }
            let target = parts[2]
            if current == nil || current?.target != target {
                flush()
                current = Cluster(id: "rules:\(index)", target: target)
            }
            current?.count += 1
            if current?.types.contains(kind) == false {
                current?.types.append(kind)
            }
            if current?.payloads.count ?? 0 < 3 {
                current?.payloads.append(parts[1])
            }
        }
        flush()
    }

    mutating func linkRule(_ id: String, target: String) {
        let (policyID, resolves) = policy(target, from: "rule \(quoted(target))")
        addEdge(TopologyEdge(source: "entry", target: id, kind: .route))
        addEdge(TopologyEdge(source: id, target: policyID, kind: .route, broken: !resolves))
    }

    mutating func policy(_ name: String, from: String) -> (String, Bool) {
        if groupDefinitions[name] != nil {
            return (Self.groupID(name), true)
        }
        if proxyNameSet.contains(name) {
            return (Self.proxyID(name), true)
        }
        let uppercase = name.uppercased()
        if Self.builtins.contains(uppercase) {
            let id = Self.builtinID(uppercase)
            addNode(TopologyNode(id: id, kind: .builtin, column: .nodes, label: uppercase))
            return (id, true)
        }
        let id = addMissing(
            name,
            from: from,
            message: "\(from) refers to \(quoted(name)), which the configuration does not define"
        )
        return (id, false)
    }

    mutating func addMissing(_ name: String, from: String, message: String) -> String {
        let id = "missing:\(name)"
        addNode(TopologyNode(id: id, kind: .missing, column: .nodes, label: name))
        graph.issues.append(TopologyIssue(from: from, missing: name, message: message))
        return id
    }

    mutating func addNode(_ node: TopologyNode) {
        guard !nodeIDs.contains(node.id) else { return }
        nodeIDs.insert(node.id)
        var ordered = node
        ordered.order = graph.nodes.count
        graph.nodes.append(ordered)
    }

    mutating func addEdge(_ edge: TopologyEdge) {
        var identified = edge
        identified.id = "\(edge.kind.rawValue):\(edge.source)->\(edge.target)"
        guard !edgeIDs.contains(identified.id) else { return }
        edgeIDs.insert(identified.id)
        graph.edges.append(identified)
    }

    mutating func setCount(_ count: Int, for id: String) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].count = count
    }

    func finish() -> TopologyGraph {
        var result = graph
        var reached: Set<String> = ["entry"]
        var changed = true
        while changed {
            changed = false
            for edge in result.edges {
                let follows = edge.active || (edge.kind == .route && mode == .rule)
                if follows && reached.contains(edge.source) && !reached.contains(edge.target) {
                    reached.insert(edge.target)
                    changed = true
                }
            }
        }
        for index in result.edges.indices where result.edges[index].kind != .route {
            if !reached.contains(result.edges[index].source) {
                result.edges[index].active = false
            }
        }
        result.nodes.sort {
            if $0.column.rawValue != $1.column.rawValue {
                return $0.column.rawValue < $1.column.rawValue
            }
            return $0.order < $1.order
        }
        for index in result.nodes.indices {
            result.nodes[index].order = index
        }
        return result
    }

    static let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    static func groupID(_ name: String) -> String { "group:\(name)" }
    static func proxyID(_ name: String) -> String { "proxy:\(name)" }
    static func providerID(_ name: String) -> String { "provider:\(name)" }
    static func builtinID(_ name: String) -> String { "builtin:\(name)" }

    /// Splits only on top-level commas so logical rules such as
    /// `AND,((DOMAIN,a.com),(NETWORK,UDP)),Proxy` retain their whole payload.
    static func splitRule(_ rule: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in rule {
            switch character {
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }
}

private func mapping(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func sequence(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func scalar(_ value: Any?) -> String? {
    value as? String
}

private func strings(_ value: Any?) -> [String] {
    sequence(value).compactMap { $0 as? String }
}

private func truthy(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    return scalar(value) == "true"
}

private func regularExpression(_ pattern: String?) -> NSRegularExpression? {
    guard let pattern, !pattern.isEmpty else { return nil }
    return try? NSRegularExpression(pattern: pattern)
}

private func matches(_ filter: NSRegularExpression?, _ exclude: NSRegularExpression?, _ name: String) -> Bool {
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    if let filter, filter.firstMatch(in: name, range: range) == nil {
        return false
    }
    if let exclude, exclude.firstMatch(in: name, range: range) != nil {
        return false
    }
    return true
}

private func quoted(_ value: String) -> String {
    "\"\(value)\""
}
