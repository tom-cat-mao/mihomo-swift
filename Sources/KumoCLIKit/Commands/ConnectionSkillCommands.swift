import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Connections: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List or close active connections.",
            subcommands: [Close.self]
        )

        @Option(name: .long, help: "Close a specific connection id.")
        var close: String?
        @Flag(name: .long, help: "Close all active connections.")
        var closeAll = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if close != nil && closeAll {
                throw ValidationError("Use either --close <id> or --close-all, not both.")
            }
        }

        mutating func run() async throws {
            try options.install()
            if closeAll {
                try await CLIRuntime.current.controller.closeConnections()
                CLIRuntime.current.write(["closed": "all"]) { _ in "closed all connections" }
                return
            }
            if let close {
                try await CLIRuntime.current.controller.closeConnection(id: close)
                CLIRuntime.current.write(["closed": close]) { _ in "closed \(close)" }
                return
            }
            let connections = try await CLIRuntime.current.controller.connections()
            CLIRuntime.current.write(connections) { connections in
                connections.map { "\($0.host) \($0.chain.joined(separator: " > "))" }.joined(separator: "\n")
            }
        }

        struct Close: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Close specific active connections by id.")

            @Option(name: .long, help: "Comma-separated connection ids, for example from `kumo connections --json`.")
            var ids: String
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                _ = try Self.parseIDs(ids)
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let report = await Self.perform(ids: try Self.parseIDs(ids)) { id in
                    try await controller.closeConnection(id: id)
                }
                CLIRuntime.current.write(report) { report in
                    let closed = report.closed.map { "closed \($0)" }
                    let failed = report.failed.map { "failed \($0.id): \($0.error)" }
                    return (closed + failed).joined(separator: "\n")
                }
            }

            /// Splits the comma-separated `--ids` value into an ordered,
            /// de-duplicated id list; empty entries are dropped and a list
            /// with no id left is rejected.
            static func parseIDs(_ raw: String) throws -> [String] {
                var seen = Set<String>()
                let ids = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                guard !ids.isEmpty else {
                    throw ValidationError("--ids must contain at least one connection id.")
                }
                return ids
            }

            /// Closes each id independently: a failing id is reported in
            /// `failed` and never aborts the remaining ids.
            static func perform(
                ids: [String],
                close: (String) async throws -> Void
            ) async -> ConnectionCloseReport {
                var closed: [String] = []
                var failed: [ConnectionCloseFailure] = []
                for id in ids {
                    do {
                        try await close(id)
                        closed.append(id)
                    } catch {
                        failed.append(ConnectionCloseFailure(id: id, error: Self.message(for: error)))
                    }
                }
                return ConnectionCloseReport(closed: closed, failed: failed)
            }

            /// Mirrors `CLIRuntime`'s display formatting for one per-id error,
            /// with a short `localizedDescription` fallback for bridged errors
            /// (`URLError` and friends) instead of the full `NSError` dump.
            private static func message(for error: Error) -> String {
                if let validation = error as? ValidationError {
                    return validation.message
                }
                if let localized = error as? LocalizedError, let description = localized.errorDescription {
                    return description
                }
                let description = (error as NSError).localizedDescription
                return description.isEmpty ? String(describing: error) : description
            }
        }
    }

    struct Skills: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage bundled Kumo agent skills.",
            subcommands: [Status.self, Install.self, Uninstall.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show agent skill installation state.")
            @OptionGroup var selection: SkillSelection
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let installer = try AgentSkillsInstaller(paths: CLIRuntime.current.controller.paths)
                let status = try installer.status(
                    targets: try selection.targets(),
                    scope: selection.scope,
                    projectWorkingDirectory: currentDirectoryURL()
                )
                CLIRuntime.current.write(status) { status in
                    status.targets.map { targetStatus in
                        [
                            targetStatus.target.rawValue,
                            "scope=\(targetStatus.scope.rawValue)",
                            "installed=\(targetStatus.installed)",
                            "upToDate=\(targetStatus.upToDate)",
                            "path=\(targetStatus.destinationRoot)"
                        ].joined(separator: " ")
                    }.joined(separator: "\n")
                }
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install bundled Kumo agent skills.", aliases: ["add"])
            @OptionGroup var selection: SkillSelection
            @Flag(name: .long, help: "Preview installation without writing files.")
            var dryRun = false
            @Flag(name: .long, help: "Replace an existing untracked skill directory.")
            var force = false
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let installer = try AgentSkillsInstaller(paths: CLIRuntime.current.controller.paths)
                let report = try installer.install(
                    targets: try selection.targets(),
                    scope: selection.scope,
                    projectWorkingDirectory: currentDirectoryURL(),
                    dryRun: dryRun,
                    force: force
                )
                CLIRuntime.current.write(report) { report in
                    let action = report.dryRun ? "[dry-run] would install" : "installed"
                    return "\(action) \(report.copiedSkillIds.joined(separator: ", ")) to \(report.destinationRoots.joined(separator: ", "))"
                }
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Uninstall bundled Kumo agent skills.")
            @OptionGroup var selection: SkillSelection
            @Flag(name: .long, help: "Preview uninstall without writing files.")
            var dryRun = false
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let installer = try AgentSkillsInstaller(paths: CLIRuntime.current.controller.paths)
                let report = try installer.uninstall(
                    targets: try selection.targets(),
                    scope: selection.scope,
                    projectWorkingDirectory: currentDirectoryURL(),
                    dryRun: dryRun
                )
                CLIRuntime.current.write(report) { report in
                    let action = report.dryRun ? "[dry-run] would uninstall" : "uninstalled"
                    return "\(action) \(report.copiedSkillIds.joined(separator: ", ")) from \(report.destinationRoots.joined(separator: ", "))"
                }
            }
        }
    }
}
