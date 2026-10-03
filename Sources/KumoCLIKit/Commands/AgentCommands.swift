import ArgumentParser
import KumoCoreKit

extension KumoCommand {
    struct Agent: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the user-level Kumo agent (kumod).",
            subcommands: [Status.self, Install.self, Uninstall.self]
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

        private static func manager() -> KumoUserAgentManager {
            KumoUserAgentManager(paths: CLIRuntime.current.controller.paths)
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
