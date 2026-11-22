import Foundation
import Network

private final class ConnectionProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ value: Bool, connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        connection.cancel()
        continuation.resume(returning: value)
    }
}

public struct ShellCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct SystemProxyCommandRunner: Sendable {
    public var run: @Sendable (ShellCommand) throws -> Void
    public var captureOutput: @Sendable (ShellCommand) throws -> String

    public init(
        run: @escaping @Sendable (ShellCommand) throws -> Void,
        captureOutput: @escaping @Sendable (ShellCommand) throws -> String
    ) {
        self.run = run
        self.captureOutput = captureOutput
    }

    public static let live = SystemProxyCommandRunner(
        run: { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments

            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                throw KumoError.commandFailed(String(decoding: data, as: UTF8.self))
            }
        },
        captureOutput: { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = error.fileHandleForReading.readDataToEndOfFile()
                throw KumoError.commandFailed(String(decoding: data, as: UTF8.self))
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )
}

public struct SystemProxyConfiguration: Codable, Equatable, Sendable {
    public var networkService: String
    public var host: String
    public var port: Int
    public var bypassList: [String]
    public var mode: SystemProxyMode
    public var pacScript: String

    public init(
        networkService: String = "Wi-Fi",
        host: String = "127.0.0.1",
        port: Int = 7890,
        bypassList: [String] = SystemProxySettings.defaultBypassList,
        mode: SystemProxyMode = .manual,
        pacScript: String = ""
    ) {
        self.networkService = networkService
        self.host = host
        self.port = port
        self.bypassList = bypassList
        self.mode = mode
        self.pacScript = pacScript
    }
}

public typealias SystemProxyTargetPortProbe = @Sendable (String, Int) async -> Bool

public struct SystemProxyController: Sendable {
    private let stateStore: CoreStateStore
    private let pacServer: PACServer
    private let commandRunner: SystemProxyCommandRunner
    private let targetPortProbe: SystemProxyTargetPortProbe?

    public init(
        paths: KumoPaths = KumoPaths(),
        commandRunner: SystemProxyCommandRunner = .live,
        targetPortProbe: SystemProxyTargetPortProbe? = nil
    ) {
        self.stateStore = CoreStateStore(paths: paths)
        self.pacServer = PACServer()
        self.commandRunner = commandRunner
        self.targetPortProbe = targetPortProbe
    }

    public func availableNetworkServices() throws -> [String] {
        let output = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
        )
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            .map { service in
                var normalized = service
                if normalized.hasPrefix("*") {
                    normalized.removeFirst()
                }
                return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    public func activeNetworkService() throws -> String {
        let routeOutput = try commandRunner.captureOutput(
            ShellCommand(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        )
        guard let interface = routeOutput
            .split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("interface:") })?
            .split(separator: " ")
            .last
            .map(String.init) else {
            throw KumoError.commandFailed("Unable to determine active network interface.")
        }

        let orderOutput = try commandRunner.captureOutput(
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
        )
        return try Self.networkService(in: orderOutput, matchingDevice: interface)
    }

    public static func networkService(in serviceOrderOutput: String, matchingDevice device: String) throws -> String {
        let blocks = serviceOrderOutput.components(separatedBy: "\n\n")
        guard let block = blocks.first(where: { $0.contains("Device: \(device)") }) else {
            throw KumoError.commandFailed("Unable to find a network service for interface \(device).")
        }

        for line in block.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("("), let closeIndex = trimmed.firstIndex(of: ")") else {
                continue
            }
            return String(trimmed[trimmed.index(after: closeIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw KumoError.commandFailed("Unable to parse network service for interface \(device).")
    }

    public func snapshot(networkService: String) throws -> SystemProxySnapshot {
        try SystemProxySnapshot(
            networkService: networkService,
            webProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getwebproxy", networkService])
            ),
            secureWebProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsecurewebproxy", networkService])
            ),
            socksProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getsocksfirewallproxy", networkService])
            ),
            bypassDomains: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getproxybypassdomains", networkService])
            ),
            autoProxy: commandRunner.captureOutput(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-getautoproxyurl", networkService])
            )
        )
    }

    /// Manual proxy enable commands (web / secure web / socks + bypass).
    public func enableCommands(configuration: SystemProxyConfiguration) -> [ShellCommand] {
        var commands = [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setwebproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setsecurewebproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setsocksfirewallproxy", configuration.networkService, configuration.host, "\(configuration.port)"]
            )
        ]
        if !configuration.bypassList.isEmpty {
            commands.append(
                ShellCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: ["-setproxybypassdomains", configuration.networkService] + configuration.bypassList
                )
            )
        }
        return commands
    }

    /// Disable manual web/secure/socks proxies. Used both when turning off
    /// system proxy entirely and when switching from manual to PAC.
    public func disableCommands(networkService: String = "Wi-Fi") -> [ShellCommand] {
        [
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setwebproxystate", networkService, "off"]),
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setsecurewebproxystate", networkService, "off"]),
            ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setsocksfirewallproxystate", networkService, "off"])
        ]
    }

    /// PAC enable commands (set autoproxy URL + turn autoproxy state on).
    public func pacEnableCommands(networkService: String, pacURL: String) -> [ShellCommand] {
        [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxyurl", networkService, pacURL]
            ),
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxystate", networkService, "on"]
            )
        ]
    }

    /// PAC disable commands (turn autoproxy state off).
    public func pacDisableCommands(networkService: String) -> [ShellCommand] {
        [
            ShellCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setautoproxystate", networkService, "off"]
            )
        ]
    }

    /// Apply system proxy settings, branching on `configuration.mode`.
    /// Successful writes record the exact applied values. Dry-run returns the
    /// would-be commands without starting PAC, executing commands, or writing state.
    @discardableResult
    public func setEnabled(
        _ isEnabled: Bool,
        configuration: SystemProxyConfiguration = SystemProxyConfiguration(),
        dryRun: Bool = false
    ) async throws -> [ShellCommand] {
        guard isEnabled else {
            if dryRun {
                return disableCommands(networkService: configuration.networkService)
                    + pacDisableCommands(networkService: configuration.networkService)
            }
            await pacServer.stop()
            return try disableSynchronously(configuration: configuration)
        }

        let commands: [ShellCommand]
        var pacURL: String?
        switch configuration.mode {
        case .manual:
            commands = enableCommands(configuration: configuration)
                + pacDisableCommands(networkService: configuration.networkService)
        case .pac:
            pacURL = dryRun ? "http://127.0.0.1:0/proxy.pac" : nil
            commands = disableCommands(networkService: configuration.networkService)
                + pacEnableCommands(
                    networkService: configuration.networkService,
                    pacURL: pacURL ?? "http://127.0.0.1:0/proxy.pac"
                )
        }
        if dryRun { return commands }

        // Settings may point at a new service. Release only the old applied
        // record, and only if the old service still shows Kumo's values.
        try releasePreviousServiceIfNeeded(configuration: configuration)
        var status = try stateStore.load()
        let before = try snapshot(networkService: configuration.networkService)
        let previousApplied = status.systemProxyApplied
        if previousApplied == nil || previousApplied?.ownership(of: before) != .owned {
            if previousApplied == nil || !before.isCleared {
                status.previousSystemProxySnapshot = before
            }
        }

        try await verifyTargetPort(configuration: configuration)
        switch configuration.mode {
        case .manual:
            await pacServer.stop()
        case .pac:
            let port = try await pacServer.start(
                script: Self.renderPACScript(configuration.pacScript, port: configuration.port)
            )
            pacURL = "http://127.0.0.1:\(port)/proxy.pac"
        }
        let appliedCommands: [ShellCommand]
        if configuration.mode == .pac, let pacURL {
            appliedCommands = disableCommands(networkService: configuration.networkService)
                + pacEnableCommands(networkService: configuration.networkService, pacURL: pacURL)
        } else {
            appliedCommands = commands
        }
        try appliedCommands.forEach(commandRunner.run)

        let after = try snapshot(networkService: configuration.networkService)
        let applied = SystemProxyApplied(
            networkService: configuration.networkService,
            mode: configuration.mode,
            host: configuration.host,
            port: configuration.port,
            pacURL: pacURL,
            bypassList: configuration.mode == .manual ? after.bypassList : []
        )
        guard applied.ownership(of: after) == .owned else {
            throw KumoError.commandFailed("macOS did not apply Kumo's \(configuration.mode.rawValue) proxy settings to \(configuration.networkService).")
        }

        status.systemProxyEnabled = true
        status.systemProxyApplied = applied
        status.systemProxyOwnership = .owned
        status.systemProxySettings = SystemProxySettings(
            networkService: configuration.networkService,
            host: configuration.host,
            port: configuration.port,
            mode: configuration.mode,
            bypassList: configuration.bypassList,
            pacScript: configuration.pacScript
        )
        try stateStore.save(status)
        return appliedCommands
    }

    /// Re-reads only the service in the applied record. A foreign takeover is
    /// retained for Reclaim; a foreign clear ends Kumo's enable intent so the
    /// next poll cannot repeatedly turn it back on.
    @discardableResult
    public func reconcileOwnership() throws -> CoreStatus {
        var status = try stateStore.load()
        guard let applied = status.systemProxyApplied else { return status }
        let ownership = applied.ownership(of: try snapshot(networkService: applied.networkService))
        var changed = status.systemProxyOwnership != ownership
        status.systemProxyOwnership = ownership
        if ownership == .cleared {
            status.systemProxyEnabled = false
            status.systemProxyApplied = nil
            changed = true
        }
        if changed { try stateStore.save(status) }
        return status
    }

    /// Releases Kumo's applied record without touching values written by
    /// another application. `preserveIntent` is used by stop/guardian cleanup;
    /// explicit disable and quit pass false.
    @discardableResult
    public func disableSynchronously(
        configuration: SystemProxyConfiguration = SystemProxyConfiguration(),
        preserveIntent: Bool = false
    ) throws -> [ShellCommand] {
        var status = try stateStore.load()
        guard let applied = status.systemProxyApplied else {
            if !preserveIntent { status.systemProxyEnabled = false }
            status.systemProxyOwnership = nil
            try stateStore.save(status)
            return []
        }

        let observed = try snapshot(networkService: applied.networkService)
        let ownership = applied.ownership(of: observed)
        var commands: [ShellCommand] = []
        if ownership == .owned {
            commands = disableCommands(networkService: applied.networkService)
                + pacDisableCommands(networkService: applied.networkService)
            try commands.forEach(commandRunner.run)
            let after = try snapshot(networkService: applied.networkService)
            guard after.isCleared else {
                throw KumoError.commandFailed("macOS did not clear Kumo's proxy settings for \(applied.networkService).")
            }
        }

        if !preserveIntent { status.systemProxyEnabled = false }
        status.systemProxyApplied = nil
        status.systemProxyOwnership = nil
        // Keep the previous snapshot for the existing restoration workflow.
        try stateStore.save(status)
        return commands
    }

    private func releasePreviousServiceIfNeeded(configuration: SystemProxyConfiguration) throws {
        let status = try stateStore.load()
        guard let applied = status.systemProxyApplied,
              applied.networkService != configuration.networkService else { return }
        _ = try disableSynchronously(configuration: configuration, preserveIntent: true)
    }

    public static func renderPACScript(_ script: String, port: Int) -> String {
        script.replacingOccurrences(of: "%mixed-port%", with: "\(port)")
    }

    private func verifyTargetPort(configuration: SystemProxyConfiguration) async throws {
        guard configuration.port > 0 else {
            throw KumoError.commandFailed("System proxy port must be greater than zero.")
        }
        let canConnect = if let targetPortProbe {
            await targetPortProbe(configuration.host, configuration.port)
        } else {
            await canConnect(to: configuration.host, port: configuration.port)
        }
        guard canConnect else {
            throw KumoError.commandFailed("System proxy target \(configuration.host):\(configuration.port) is not accepting connections.")
        }
    }

    private func canConnect(to host: String, port: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let connection = NWConnection(
                        host: NWEndpoint.Host(host),
                        port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                        using: .tcp
                    )
                    let probeState = ConnectionProbeState()
                    connection.stateUpdateHandler = { connectionState in
                        switch connectionState {
                        case .ready:
                            probeState.resumeOnce(true, connection: connection, continuation: continuation)
                        case .failed, .cancelled:
                            probeState.resumeOnce(false, connection: connection, continuation: continuation)
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            guard let result = await group.next() else {
                return false
            }
            group.cancelAll()
            return result
        }
    }

}
