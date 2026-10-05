import ArgumentParser
import KumoCoreKit

extension KumoCommand {
    struct Agent: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the user-level Kumo agent (kumod).",
            subcommands: [Status.self, Install.self, Uninstall.self, Migrate.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show user-level agent state.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                writeServiceModeStatus(manager().status())
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install the user-level agent.")
            @Flag(name: .long, help: "Preview the installation without writing or registering.")
            var dryRun = false
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                if dryRun {
                    writeDryRun(action: "install")
                    return
                }
                writeServiceModeStatus(try manager().install())
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Uninstall the user-level agent.")
            @Flag(name: .long, help: "Preview the uninstall without removing anything.")
            var dryRun = false
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                if dryRun {
                    writeDryRun(action: "uninstall")
                    return
                }
                writeServiceModeStatus(try manager().uninstall())
            }
        }

        /// Moves a running, root-owned core to the user agent so the GUI can
        /// quit while the core keeps serving without the privileged daemon
        /// owning it. Refuses while TUN is enabled and until the agent is
        /// installed; `--dry-run` reports the same guards without acting.
        struct Migrate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Migrate a root-owned core to the user-level agent.",
                discussion: "The core must not be migrated while TUN is enabled. Install the agent first; this command never installs it."
            )
            @Flag(name: .long, help: "Report the current tier and planned handoff without migrating.")
            var dryRun = false
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller

                if dryRun {
                    let plan = try controller.coreMigrationPlan()
                    CLIRuntime.current.write(plan) { plan in
                        ([tierSummary(plan.tier), plan.coreRunning ? "core=running" : "core=stopped"]
                            + planSummaryLines(plan)).joined(separator: "\n")
                    }
                    return
                }

                let result = try controller.migrateCoreToUserAgent()
                CLIRuntime.current.write(result) { result in
                    let outcome = result.migrated
                        ? "migrated the core from Kumo Helper to the Kumo agent"
                        : "no migration: \(result.plan.reason ?? "nothing to do")"
                    return ([tierSummary(result.plan.tier), outcome]).joined(separator: "\n")
                }
            }
        }

        private static func manager() -> KumoUserAgentManager {
            KumoUserAgentManager(paths: CLIRuntime.current.controller.paths)
        }

        private static func tierSummary(_ tier: TierInstallState) -> String {
            "install=\(tier.installState.rawValue) owner=\(tier.coreOwner.rawValue) tun=\(tier.tunEnabled)"
        }

        private static func planSummaryLines(_ plan: CoreMigrationPlan) -> [String] {
            if !plan.blockers.isEmpty {
                return ["[dry-run] would refuse: " + plan.blockers.joined(separator: " ")]
            }
            switch plan.action {
            case .handoff:
                return ["[dry-run] would hand the core from Kumo Helper to the Kumo agent"]
            case .none:
                return ["[dry-run] nothing to do: \(plan.reason ?? "no handoff needed")"]
            }
        }

        private static func writeDryRun(action: String) {
            let paths = CLIRuntime.current.controller.paths
            let report = AgentActionReport(
                action: action,
                label: manager().launchAgentLabel,
                plistPath: paths.userAgentPlistFile.path,
                socketPath: paths.userAgentSocketFile.path,
                dryRun: true,
                status: manager().status()
            )
            CLIRuntime.current.write(report) { report in
                "[dry-run] would \(report.action) \(report.label) plist=\(report.plistPath) socket=\(report.socketPath)"
            }
        }
    }
}
