import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand.Config {
    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preview generated configuration changes without writing.",
            discussion: "With no input, compares the current generated configuration with work/config.yaml. --file/--stdin supplies replacement YAML for the current profile; ordered overrides and Kumo-owned settings still apply."
        )

        @Option(name: .long, help: "Read candidate current-profile YAML from a file.")
        var file: String?
        @Flag(name: .long, help: "Read candidate current-profile YAML from stdin.")
        var stdin = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if file != nil && stdin {
                throw ValidationError("Use either --file <path> or --stdin, not both.")
            }
        }

        mutating func run() async throws {
            try options.install()
            let rawYAML = try candidateProfileYAML(file: file, stdin: stdin)
            let report = try CLIRuntime.current.controller.diffConfiguration(profileYAML: rawYAML)
            CLIRuntime.current.write(report) { report in
                report.changed ? report.diff : "changed=false"
            }
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate generated configuration without writing.",
            discussion: "Runs the selected Mihomo core's real configuration test in an isolated temporary directory. With no input, validates the current generated configuration; --file/--stdin supplies replacement current-profile YAML."
        )

        @Option(name: .long, help: "Read candidate current-profile YAML from a file.")
        var file: String?
        @Flag(name: .long, help: "Read candidate current-profile YAML from stdin.")
        var stdin = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if file != nil && stdin {
                throw ValidationError("Use either --file <path> or --stdin, not both.")
            }
        }

        mutating func run() async throws {
            try options.install()
            let rawYAML = try candidateProfileYAML(file: file, stdin: stdin)
            let report = CLIRuntime.current.controller.validateConfiguration(profileYAML: rawYAML)
            CLIRuntime.current.write(report) { report in
                (["valid=\(report.valid)"] + report.diagnostics).joined(separator: "\n")
            }
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate and apply replacement current-profile YAML.",
            discussion: "Requires --file/--stdin. Uses the shared profile transaction, hot-reloads a running core, and commits a bounded pre-apply rollback point only after success."
        )

        @Option(name: .long, help: "Read replacement current-profile YAML from a file.")
        var file: String?
        @Flag(name: .long, help: "Read replacement current-profile YAML from stdin.")
        var stdin = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if file != nil && stdin {
                throw ValidationError("Use either --file <path> or --stdin, not both.")
            }
            if file == nil && !stdin {
                throw ValidationError("Provide --file <path> or --stdin with the replacement profile YAML.")
            }
        }

        mutating func run() async throws {
            try options.install()
            let rawYAML = try readProfileYAML(file: file, stdin: stdin)
            let report = try await CLIRuntime.current.controller.applyConfiguration(profileYAML: rawYAML)
            CLIRuntime.current.write(report) { report in
                "applied rollbackPoint=\(report.rollbackPointID) snapshots=\(report.snapshotCount) reloaded=\(report.reloaded)"
            }
        }
    }

    struct Rollback: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore the newest successful pre-apply state.",
            discussion: "Preflights and hot-reloads a running core before consuming the rollback point. Failure retains the point for retry and preserves current process and system-proxy observations."
        )

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let report = try await CLIRuntime.current.controller.rollbackConfiguration()
            CLIRuntime.current.write(report) { report in
                "rolled back rollbackPoint=\(report.rollbackPointID) remaining=\(report.remainingSnapshots) reloaded=\(report.reloaded)"
            }
        }
    }
}

private func candidateProfileYAML(file: String?, stdin: Bool) throws -> String? {
    guard file != nil || stdin else { return nil }
    return try readProfileYAML(file: file, stdin: stdin)
}
