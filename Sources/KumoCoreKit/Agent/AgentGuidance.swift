import Foundation

/// One command in an agent task and the reason for running it.
public struct AgentPromptStep: Codable, Equatable, Sendable {
    public let command: String
    public let why: String

    public init(command: String, why: String) {
        self.command = command
        self.why = why
    }
}

/// One page-level task an agent can perform with the current CLI.
public struct AgentIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let goal: String
    public let steps: [AgentPromptStep]

    public init(id: String, goal: String, steps: [AgentPromptStep]) {
        self.id = id
        self.goal = goal
        self.steps = steps
    }
}

public struct AgentGuide: Codable, Equatable, Sendable {
    public let page: String
    public let intents: [AgentIntent]

    public init(page: String, intents: [AgentIntent]) {
        self.page = page
        self.intents = intents
    }
}

public enum AgentGuidanceError: LocalizedError, Equatable {
    case unknownPage(String, available: [String])
    case unknownIntent(page: String, intent: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .unknownPage(let page, let available):
            "Unknown prompt page '\(page)'. Valid pages: \(available.joined(separator: ", "))."
        case .unknownIntent(let page, let intent, let available):
            "Unknown intent '\(intent)' for \(page). Valid intents: \(available.joined(separator: ", "))."
        }
    }
}

/// Shared CLI/SwiftUI task guidance. Every command referenced here is registered
/// in the executable CLI surface, including configuration transactions and
/// topology diagnostics.
public enum AgentGuidance {
    public static var guides: [AgentGuide] {
        merge(baseGuides, with: supplementalGuides)
    }

    public static func guide(for page: String) -> AgentGuide? {
        guides.first { $0.page == page }
    }

    public static func prompt(page: String, intent: String? = nil) throws -> String {
        guard let guide = guide(for: page) else {
            throw AgentGuidanceError.unknownPage(page, available: guides.map(\.page))
        }
        let selected: AgentIntent
        if let intent {
            guard let match = guide.intents.first(where: { $0.id == intent }) else {
                throw AgentGuidanceError.unknownIntent(page: page, intent: intent, available: guide.intents.map(\.id))
            }
            selected = match
        } else {
            guard let first = guide.intents.first else {
                throw AgentGuidanceError.unknownIntent(page: page, intent: "", available: [])
            }
            selected = first
        }

        var lines = [
            "Goal: \(selected.goal).",
            "",
            "Use Kumo's command-line tool, `kumo`, which controls the Kumo app and its Mihomo core on this computer.",
            "- Run `kumo capabilities --json` first to discover the protocol and exact command metadata; do not guess commands.",
            "- Add --json to data commands and read `ok`, `data` and `error`; exit code 0 means success.",
            "- Use --dry-run where capabilities marks it supported, and verify writes with the relevant read command.",
            "- If `kumo` is not on PATH, ask me to install it from Kumo > Agents or Settings > Command Line Tool.",
            "- Do not edit Kumo's state, profile, or generated runtime files directly.",
            "",
            "Steps:"
        ]
        for (index, step) in selected.steps.enumerated() {
            lines.append("\(index + 1). `\(step.command)` — \(step.why).")
        }
        lines.append("")
        lines.append("Report what you changed and the final `kumo status --json`.")
        return lines.joined(separator: "\n")
    }

    // Extension seam for additional pages or intents without changing Prompt's
    // output contract. Register guidance only with its executable CLI command.
    private static let supplementalGuides: [AgentGuide] = []

    private static func merge(_ base: [AgentGuide], with supplemental: [AgentGuide]) -> [AgentGuide] {
        var merged = base
        for guide in supplemental {
            if let index = merged.firstIndex(where: { $0.page == guide.page }) {
                merged[index] = AgentGuide(page: guide.page, intents: merged[index].intents + guide.intents)
            } else {
                merged.append(guide)
            }
        }
        return merged
    }

    private static let baseGuides: [AgentGuide] = [
        AgentGuide(page: "overview", intents: [
            AgentIntent(id: "connect", goal: "Start Kumo and route this Mac's traffic through it", steps: [
                AgentPromptStep(command: "kumo status --json", why: "Check whether Mihomo already runs"),
                AgentPromptStep(command: "kumo start --json", why: "Start Mihomo with the current profile"),
                AgentPromptStep(command: "kumo sysproxy on --dry-run --json", why: "Preview the system-proxy change"),
                AgentPromptStep(command: "kumo sysproxy on --json", why: "Point the system proxy at Kumo"),
                AgentPromptStep(command: "kumo status --json", why: "Confirm the final runtime and proxy state")
            ]),
            AgentIntent(id: "diagnose", goal: "Find out why Kumo is not connecting", steps: [
                AgentPromptStep(command: "kumo doctor --json", why: "Collect runtime, profile, and core diagnostics"),
                AgentPromptStep(command: "kumo logs runtime --limit 50 --level warning --json", why: "Read recent Mihomo warnings and errors"),
                AgentPromptStep(command: "kumo status --json", why: "Inspect the current core and system-proxy state")
            ]),
            AgentIntent(id: "mode", goal: "Switch the outbound mode", steps: [
                AgentPromptStep(command: "kumo status --json", why: "Read the current mode"),
                AgentPromptStep(command: "kumo mode rule --json", why: "Use rule mode; substitute global or direct when requested"),
                AgentPromptStep(command: "kumo status --json", why: "Verify the selected mode")
            ])
        ]),
        AgentGuide(page: "profiles", intents: [
            AgentIntent(id: "import", goal: "Import a remote subscription and use it", steps: [
                AgentPromptStep(command: "kumo profile refresh '<subscription URL>' --json", why: "Download a remote subscription; an existing URL refreshes in place"),
                AgentPromptStep(command: "kumo profile list --json", why: "Confirm the imported profile and current selection")
            ]),
            AgentIntent(id: "importLocal", goal: "Import a local YAML profile", steps: [
                AgentPromptStep(command: "kumo profile import <path> --json", why: "Import the local YAML file"),
                AgentPromptStep(command: "kumo profile list --json", why: "Confirm the imported profile and current selection")
            ]),
            AgentIntent(id: "refresh", goal: "Refresh a stored subscription", steps: [
                AgentPromptStep(command: "kumo profile list --json", why: "Find the remote profile id"),
                AgentPromptStep(command: "kumo profile refresh --id <id> --json", why: "Download the profile again without changing its id")
            ]),
            AgentIntent(id: "switch", goal: "Switch to another profile", steps: [
                AgentPromptStep(command: "kumo profile list --json", why: "Find the profile id"),
                AgentPromptStep(command: "kumo profile use <id> --json", why: "Make it current"),
                AgentPromptStep(command: "kumo status --json", why: "Verify the active profile and runtime state")
            ]),
            AgentIntent(id: "apply", goal: "Preview, validate, and apply a candidate for the current profile", steps: [
                AgentPromptStep(command: "kumo config diff --file <path> --json", why: "Preview the generated unified diff without writing files"),
                AgentPromptStep(command: "kumo config validate --file <path> --json", why: "Run real Mihomo validation and read diagnostics without mutating state"),
                AgentPromptStep(command: "kumo config apply --file <path> --json", why: "Apply transactionally and record the rollback point id"),
                AgentPromptStep(command: "kumo config diff --json", why: "Verify that installed and generated configuration now match")
            ]),
            AgentIntent(id: "rollback", goal: "Undo the most recent successful configuration apply", steps: [
                AgentPromptStep(command: "kumo config rollback --json", why: "Restore and hot-reload the newest pre-apply state, retaining the point if it fails"),
                AgentPromptStep(command: "kumo config diff --json", why: "Confirm the restored generated configuration is installed"),
                AgentPromptStep(command: "kumo status --json", why: "Verify that the same core process and system-proxy state remain")
            ])
        ]),
        AgentGuide(page: "proxies", intents: [
            AgentIntent(id: "fastest", goal: "Pick the fastest node of a group", steps: [
                AgentPromptStep(command: "kumo proxies --json", why: "List groups and their current selections"),
                AgentPromptStep(command: "kumo test '<group>' --json", why: "Measure every member when the target is a group"),
                AgentPromptStep(command: "kumo select '<group>' '<node>' --json", why: "Select the responsive node with the lowest delay")
            ]),
            AgentIntent(id: "select", goal: "Use a specific proxy node", steps: [
                AgentPromptStep(command: "kumo proxies --json", why: "Find the exact group and node names"),
                AgentPromptStep(command: "kumo select '<group>' '<node>' --json", why: "Select the node"),
                AgentPromptStep(command: "kumo proxies --json", why: "Verify the group's selection")
            ])
        ]),
        AgentGuide(page: "topology", intents: [
            AgentIntent(id: "explain", goal: "Explain how traffic flows through my configuration", steps: [
                AgentPromptStep(command: "kumo status --json", why: "Start with the active outbound mode and profile"),
                AgentPromptStep(command: "kumo topology --issues --json", why: "Inspect unresolved references in the generated configuration graph"),
                AgentPromptStep(command: "kumo proxies --json", why: "Follow policies to groups and their selected nodes")
            ]),
            AgentIntent(id: "route", goal: "Find which proxy a domain is configured to use", steps: [
                AgentPromptStep(command: "kumo rules --json", why: "Find the first matching rule in evaluation order"),
                AgentPromptStep(command: "kumo proxies --json", why: "Resolve the rule's target group to its selected node"),
                AgentPromptStep(command: "kumo profile content <id> --json", why: "Inspect the source profile when an offline rule or group reference needs checking")
            ])
        ]),
        AgentGuide(page: "connections", intents: [
            AgentIntent(id: "inspect", goal: "See which apps use the proxy", steps: [
                AgentPromptStep(command: "kumo connections --json", why: "List connections with host, process, rule, and chain")
            ]),
            AgentIntent(id: "close", goal: "Close stuck connections", steps: [
                AgentPromptStep(command: "kumo connections --json", why: "Identify the connection ids"),
                AgentPromptStep(command: "kumo connections close --ids <id1,id2> --json", why: "Close only the selected connections"),
                AgentPromptStep(command: "kumo connections --json", why: "Confirm they are gone")
            ])
        ]),
        AgentGuide(page: "logs", intents: [
            AgentIntent(id: "errors", goal: "Summarize recent errors", steps: [
                AgentPromptStep(command: "kumo logs runtime --limit 200 --level warning --json", why: "Read recent warnings and errors")
            ]),
            AgentIntent(id: "follow", goal: "Watch the Mihomo log live", steps: [
                AgentPromptStep(command: "kumo logs runtime --follow --level info --json", why: "Stream one JSON envelope per line until interrupted")
            ])
        ]),
        AgentGuide(page: "rules", intents: [
            AgentIntent(id: "toggle", goal: "Turn a rule off or on", steps: [
                AgentPromptStep(command: "kumo rules --json", why: "Find the rule's current index"),
                AgentPromptStep(command: "kumo rules disable <index> --json", why: "Disable it; use `kumo rules enable <index> --json` to restore it"),
                AgentPromptStep(command: "kumo rules --json", why: "Verify the enabled state")
            ])
        ]),
        AgentGuide(page: "core", intents: [
            AgentIntent(id: "install", goal: "Install or update the Mihomo core", steps: [
                AgentPromptStep(command: "kumo doctor --json", why: "Inspect the current core and available candidates"),
                AgentPromptStep(command: "kumo core install --json", why: "Install the managed Mihomo core"),
                AgentPromptStep(command: "kumo restart --json", why: "Run the new core")
            ]),
            AgentIntent(id: "settings", goal: "Change core ports, LAN access, or logging", steps: [
                AgentPromptStep(command: "kumo config get --json", why: "Read the current runtime settings"),
                AgentPromptStep(command: "kumo config set --mixed-port 7890 --dry-run --json", why: "Preview the merged settings"),
                AgentPromptStep(command: "kumo config set --mixed-port 7890 --json", why: "Apply the validated settings"),
                AgentPromptStep(command: "kumo config get --json", why: "Verify the stored values")
            ])
        ]),
        AgentGuide(page: "systemProxy", intents: [
            AgentIntent(id: "enable", goal: "Turn the macOS system proxy on", steps: [
                AgentPromptStep(command: "kumo status --json", why: "Check the core and current system-proxy state"),
                AgentPromptStep(command: "kumo sysproxy on --dry-run --json", why: "Preview the networksetup commands"),
                AgentPromptStep(command: "kumo sysproxy on --json", why: "Apply the protected system change"),
                AgentPromptStep(command: "kumo status --json", why: "Verify the result")
            ]),
            AgentIntent(id: "configure", goal: "Update system-proxy settings", steps: [
                AgentPromptStep(command: "kumo status --json", why: "Read the stored endpoint and bypass settings"),
                AgentPromptStep(command: "kumo sysproxy set --add-defaults --dry-run --json", why: "Preview adding the standard bypass entries"),
                AgentPromptStep(command: "kumo sysproxy set --add-defaults --json", why: "Apply the settings")
            ])
        ]),
        AgentGuide(page: "dns", intents: [
            AgentIntent(id: "manage", goal: "Manage Kumo's DNS settings", steps: [
                AgentPromptStep(command: "kumo dns --json", why: "Read the current DNS settings"),
                AgentPromptStep(command: "kumo dns enable --json", why: "Enable Kumo-managed DNS; use disable to turn it off"),
                AgentPromptStep(command: "kumo dns --json", why: "Verify the settings")
            ]),
            AgentIntent(id: "patch", goal: "Validate and apply a DNS settings patch", steps: [
                AgentPromptStep(command: "kumo dns set --file <path> --dry-run --json", why: "Validate and preview the merged JSON patch"),
                AgentPromptStep(command: "kumo dns set --file <path> --json", why: "Apply it, restarting a running core when required")
            ])
        ]),
        AgentGuide(page: "tun", intents: [
            AgentIntent(id: "enable", goal: "Route traffic with TUN", steps: [
                AgentPromptStep(command: "kumo tun status --json", why: "Check TUN state and whether the privileged service is required"),
                AgentPromptStep(command: "kumo service status --json", why: "Inspect Kumo Helper before the protected change"),
                AgentPromptStep(command: "kumo tun enable --json", why: "Enable TUN through the privileged executor"),
                AgentPromptStep(command: "kumo tun status --json", why: "Verify the interface state")
            ]),
            AgentIntent(id: "settings", goal: "Validate and apply TUN settings", steps: [
                AgentPromptStep(command: "kumo tun settings --json", why: "Read current settings"),
                AgentPromptStep(command: "kumo tun settings --file <path> --dry-run --json", why: "Validate and preview a JSON patch"),
                AgentPromptStep(command: "kumo tun settings --file <path> --json", why: "Apply the settings")
            ])
        ]),
        AgentGuide(page: "sniffer", intents: [
            AgentIntent(id: "manage", goal: "Manage Kumo's sniffer settings", steps: [
                AgentPromptStep(command: "kumo sniffer --json", why: "Read current sniffer settings"),
                AgentPromptStep(command: "kumo sniffer enable --json", why: "Enable the sniffer; use disable to turn it off"),
                AgentPromptStep(command: "kumo sniffer --json", why: "Verify the settings")
            ]),
            AgentIntent(id: "patch", goal: "Validate and apply a sniffer settings patch", steps: [
                AgentPromptStep(command: "kumo sniffer set --file <path> --dry-run --json", why: "Validate and preview the JSON patch"),
                AgentPromptStep(command: "kumo sniffer set --file <path> --json", why: "Apply it, restarting a running core when required")
            ])
        ]),
        AgentGuide(page: "resources", intents: [
            AgentIntent(id: "update", goal: "Update providers and Geo data", steps: [
                AgentPromptStep(command: "kumo providers --json", why: "List proxy and rule providers"),
                AgentPromptStep(command: "kumo providers update --all --geo --json", why: "Update all providers and GeoIP/GeoSite data while collecting individual failures"),
                AgentPromptStep(command: "kumo providers --json", why: "Inspect the resulting provider state")
            ])
        ]),
        AgentGuide(page: "overrides", intents: [
            AgentIntent(id: "add", goal: "Add a YAML override", steps: [
                AgentPromptStep(command: "kumo override add --name 'Extra rules' --file <path> --dry-run --json", why: "Validate the YAML without writing"),
                AgentPromptStep(command: "kumo override add --name 'Extra rules' --file <path> --json", why: "Store it for the next core start"),
                AgentPromptStep(command: "kumo override list --json", why: "Verify its merge position")
            ]),
            AgentIntent(id: "order", goal: "Inspect or reorder overrides", steps: [
                AgentPromptStep(command: "kumo override list --json", why: "Read the current merge order and ids"),
                AgentPromptStep(command: "kumo override reorder --ids <id1,id2> --json", why: "Move listed ids to the front and preserve the remaining relative order")
            ])
        ]),
        AgentGuide(page: "agents", intents: [
            AgentIntent(id: "discover", goal: "Discover Kumo's agent protocol and page prompts", steps: [
                AgentPromptStep(command: "kumo capabilities --json", why: "Read the versioned protocol, commands, parameters, and safety metadata"),
                AgentPromptStep(command: "kumo prompt --list --json", why: "List page and intent ids without guessing")
            ]),
            AgentIntent(id: "skills", goal: "Install the Kumo skill for coding agents", steps: [
                AgentPromptStep(command: "kumo skills status --json", why: "See which agents have the skill"),
                AgentPromptStep(command: "kumo skills install --agent all --dry-run --json", why: "Preview every destination"),
                AgentPromptStep(command: "kumo skills install --agent all --json", why: "Install the bundled skill")
            ])
        ]),
        AgentGuide(page: "settings", intents: [
            AgentIntent(id: "cli", goal: "Install the kumo command on PATH", steps: [
                AgentPromptStep(command: "kumo cli-link status --json", why: "Inspect the current symlink"),
                AgentPromptStep(command: "kumo cli-link install --dry-run --json", why: "Preview the protected link installation without prompting"),
                AgentPromptStep(command: "kumo cli-link install --json", why: "Install the link with macOS authorization")
            ]),
            AgentIntent(id: "preferences", goal: "Inspect or update GUI preferences", steps: [
                AgentPromptStep(command: "kumo prefs get --json", why: "Read the exposed preference keys"),
                AgentPromptStep(command: "kumo prefs set keepCoreRunningOnQuit true --dry-run --json", why: "Preview a typed preference change"),
                AgentPromptStep(command: "kumo prefs set keepCoreRunningOnQuit true --json", why: "Apply it while preserving unrelated preferences")
            ])
        ])
    ]
}
