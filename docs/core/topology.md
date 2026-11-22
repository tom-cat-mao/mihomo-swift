# Configuration Topology

`TopologyBuilder.build(yaml:mode:selections:)` turns a generated Mihomo
configuration into a stable, layout-independent `TopologyGraph`.
`KumoController.topology()` and `CoreRuntimeRunner.topology()` expose the same
graph to the CLI and the native SwiftUI Topology page. No React, WebView, or
second YAML parser is involved.

## Sources and runtime state

The structure always comes from `RuntimeConfigBuilder`: current profile,
active YAML overrides, and Kumo-controlled runtime settings. This keeps the
stopped preview equivalent to the configuration the next launch would write.

When Mihomo is running, the controller additionally reads the actual mode from
`GET /configs` and selections from `GET /proxies`. Selections include the
hidden `GLOBAL` group. They only mark active state; runtime data does not add,
remove, or repair configured references. A stopped graph has no synthetic
selections.

## Nodes

| Column | Kinds |
| --- | --- |
| 0 | `entry` (outbound mode) |
| 1 | `rules` (consecutive inline rules with one target), `ruleSet` (each `RULE-SET`), `final` (`MATCH` / `FINAL`) |
| 2 | `group` (including nested groups), `global` (the implicit global chooser) |
| 3 | `proxy`, `provider`, `builtin`, `missing` |

Node and edge IDs are deterministic. For example: `group:Proxy`,
`proxy:HK 01`, `provider:airport`, `builtin:DIRECT`, `missing:Nowhere`,
`rules:12`, and `ruleset:apple@4`. `order` preserves configuration order within
columns; proxy-provider mappings are sorted for deterministic output.

## Edges and active paths

- `route`: the mode or a rule sends traffic to a policy.
- `member`: a group explicitly lists a node or another group.
- `provider`: a group explicitly uses a proxy provider.
- `dynamic`: `include-all`, `include-all-proxies`,
  `include-all-providers`, `filter`, or `exclude-filter` brings in a target;
  Mihomo resolves the effective membership at runtime.
- `active`: the mode route or an actual selected member. Selections on groups
  unreachable from the entry are cleared.
- `broken`: the target is undefined. Broken edges always point to a `missing`
  node and remain visible in the native UI even when columns are collapsed.

In rule mode, route edges describe possible traffic paths. Current-path
highlighting follows those routes and active member/dynamic edges; the CLI
"Active path" section lists the selected non-route edges.

## Rule aggregation and parsing

Each `RULE-SET` is a separate node. Consecutive inline rules targeting the
same policy form one `rules` node with a count, distinct type list, and up to
three payload examples. `MATCH` and `FINAL` flush the current cluster and
create the `final` node.

Rule parsing splits commas only outside parentheses. Logical rules such as
`AND,((DOMAIN,a.com),(NETWORK,UDP)),Proxy` therefore retain the full logical
payload instead of being split into bogus policies.

## Issues

Undefined proxies, nested groups, proxy providers, and rule providers become
`TopologyIssue` values. Explicit missing policies/providers also get `missing`
nodes and broken edges; an undefined `RULE-SET` remains a visible `ruleSet`
node and records its issue. Issues are available through
`kumo topology --issues [--json]`, the native page's issue list, and each
node's text inspector.

## Native SwiftUI presentation

`TopologyView` uses `HSplitView`, horizontal `ScrollView`, `LazyVStack`, and
small native node/relation views. It provides toolbar search, a dynamic-member
toggle, an always-accessible issue list, active-path highlighting, and a text
inspector for incoming/outgoing relations. Large columns initially show 12
items, but active and missing nodes are never collapsed away. Search results
are never collapsed. No web content is embedded.
