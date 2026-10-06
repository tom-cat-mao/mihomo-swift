import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct CLILink: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cli-link",
            abstract: "Manage the `kumo` command-line tool link on PATH.",
            subcommands: [Status.self, Install.self, Uninstall.self],
            defaultSubcommand: Status.self
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the `kumo` CLI link state.")
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let status = CLIRuntime.current.controller.cliLinkStatus()
                CLIRuntime.current.write(status) { cliLinkStatusText($0) }
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Create the `kumo` symlink.",
                discussion: "Links \(CLILinkInstaller.defaultTargetPath) to the kumo binary shipped in the Kumo app bundle. The target directory is not user-writable, so macOS shows a one-time administrator authorization prompt (osascript). --dry-run reports the current link state and the intended action without prompting or writing."
            )

            @Flag(name: .long, help: "Report the current link state and intended action without prompting or writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let status = dryRun
                    ? controller.cliLinkStatus()
                    : try controller.installCLILink()
                let report = CLILinkActionReport(action: "install", dryRun: dryRun, status: status)
                CLIRuntime.current.write(report) { cliLinkActionText($0) }
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove the `kumo` symlink.",
                discussion: "Removes \(CLILinkInstaller.defaultTargetPath) only when it is a symlink that points at the bundled kumo binary; a symlink or file that Kumo does not manage is left alone. Removing from the default target directory needs administrator authorization (osascript). --dry-run reports the current link state and the intended action without prompting or writing."
            )

            @Flag(name: .long, help: "Report the current link state and intended action without prompting or writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let status = dryRun
                    ? controller.cliLinkStatus()
                    : try controller.uninstallCLILink()
                let report = CLILinkActionReport(action: "uninstall", dryRun: dryRun, status: status)
                CLIRuntime.current.write(report) { cliLinkActionText($0) }
            }
        }
    }
}

func cliLinkStatusSummary(_ status: CLILinkStatus) -> String {
    [
        "state=\(status.state.rawValue)",
        "target=\(status.targetPath)",
        "bundled=\(status.bundledCLIPath ?? "-")",
        "link=\(status.linkResolvedPath ?? "-")"
    ].joined(separator: " ")
}

func cliLinkStatusText(_ status: CLILinkStatus) -> String {
    [cliLinkStatusSummary(status), status.message].joined(separator: "\n")
}

func cliLinkActionText(_ report: CLILinkActionReport) -> String {
    var lines: [String] = []
    if report.dryRun {
        lines.append("[dry-run] would \(report.action) the kumo CLI link at \(report.status.targetPath)")
    }
    lines.append(cliLinkStatusSummary(report.status))
    lines.append(report.status.message)
    return lines.joined(separator: "\n")
}
