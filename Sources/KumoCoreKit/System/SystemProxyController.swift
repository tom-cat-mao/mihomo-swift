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

public struct PACHost: Sendable {
    public var start: @Sendable (String) async throws -> PACServerStatus
    public var stop: @Sendable () async -> Void
    public var status: @Sendable () async -> PACServerStatus
    let stopSynchronously: @Sendable () -> Void
    let isInProcessRunning: @Sendable () async -> Bool

    public init(
        start: @escaping @Sendable (String) async throws -> PACServerStatus,
        stop: @escaping @Sendable () async -> Void,
        status: @escaping @Sendable () async -> PACServerStatus
    ) {
        self.start = start
        self.stop = stop
        self.status = status
        self.stopSynchronously = {
            Task { await stop() }
        }
        self.isInProcessRunning = { false }
    }

    init(
        start: @escaping @Sendable (String) async throws -> PACServerStatus,
        stop: @escaping @Sendable () async -> Void,
        status: @escaping @Sendable () async -> PACServerStatus,
        stopSynchronously: @escaping @Sendable () -> Void,
        isInProcessRunning: @escaping @Sendable () async -> Bool
    ) {
        self.start = start
        self.stop = stop
        self.status = status
        self.stopSynchronously = stopSynchronously
        self.isInProcessRunning = isInProcessRunning
    }

    public static func inProcess(_ server: PACServer) -> PACHost {
        PACHost(
            start: { script in
                let port = try await server.start(script: script)
                return PACServerStatus(
                    isRunning: true,
                    port: port,
                    url: "http://127.0.0.1:\(port)/proxy.pac"
                )
            },
            stop: {
                await server.stop()
            },
            status: {
                let running = await server.isRunning
                let port = await server.currentPort
                return PACServerStatus(
                    isRunning: running,
                    port: port,
                    url: port.map { "http://127.0.0.1:\($0)/proxy.pac" }
                )
            },
            stopSynchronously: {
                let generation = server.currentGeneration()
                Task { await server.stop(ifGenerationMatches: generation) }
            },
            isInProcessRunning: {
                await server.isRunning
            }
        )
    }

    public static func delegating(
        remoteProvider: @escaping @Sendable () -> KumoServiceClient?,
        fallback: PACServer
    ) -> PACHost {
        PACHost(
            start: { script in
                if let client = remoteProvider() {
                    do {
                        let remoteStatus = try client.startPAC(script: script)
                        await fallback.stop()
                        return remoteStatus
                    } catch KumoError.serviceUnavailable {
                        // kumod is not installed or unreachable; fall back to in-process PACServer.
                    }
                }
                let port = try await fallback.start(script: script)
                return PACServerStatus(
                    isRunning: true,
                    port: port,
                    url: "http://127.0.0.1:\(port)/proxy.pac"
                )
            },
            stop: {
                if let client = remoteProvider() {
                    _ = try? client.stopPAC()
                }
                await fallback.stop()
            },
            status: {
                if let client = remoteProvider(),
                   let remoteStatus = try? client.pacStatus(),
                   remoteStatus.isRunning {
                    return remoteStatus
                }
                let running = await fallback.isRunning
                let port = await fallback.currentPort
                return PACServerStatus(
                    isRunning: running,
                    port: port,
                    url: port.map { "http://127.0.0.1:\($0)/proxy.pac" }
                )
            },
            stopSynchronously: {
                if let client = remoteProvider() {
                    _ = try? client.stopPAC()
                }
                let generation = fallback.currentGeneration()
                Task { await fallback.stop(ifGenerationMatches: generation) }
            },
            isInProcessRunning: {
                await fallback.isRunning
            }
        )
    }
}

public struct SystemProxyController: Sendable {
    private let stateStore: CoreStateStore
    private let pacHost: PACHost
    private let commandRunner: SystemProxyCommandRunner
    private let targetPortProbe: SystemProxyTargetPortProbe?

    public init(
        paths: KumoPaths = KumoPaths(),
        commandRunner: SystemProxyCommandRunner = .live,
        targetPortProbe: SystemProxyTargetPortProbe? = nil,
        pacHost: PACHost = .inProcess(PACServer())
    ) {
        self.stateStore = CoreStateStore(paths: paths)
        self.pacHost = pacHost
        self.commandRunner = commandRunner
        self.targetPortProbe = targetPortProbe
    }

    func isInProcessPACRunning() async -> Bool {
        await pacHost.isInProcessRunning()
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

    public func restoreCommands(from snapshot: SystemProxySnapshot) -> [ShellCommand] {
        let executable = "/usr/sbin/networksetup"
        let service = snapshot.networkService
        var commands: [ShellCommand] = []

        if snapshot.web.isEnabled && !snapshot.web.host.isEmpty && snapshot.web.port > 0 {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setwebproxy", service, snapshot.web.host, "\(snapshot.web.port)"]
            ))
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setwebproxystate", service, "on"]
            ))
        } else {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setwebproxystate", service, "off"]
            ))
        }

        if snapshot.secureWeb.isEnabled && !snapshot.secureWeb.host.isEmpty && snapshot.secureWeb.port > 0 {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsecurewebproxy", service, snapshot.secureWeb.host, "\(snapshot.secureWeb.port)"]
            ))
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsecurewebproxystate", service, "on"]
            ))
        } else {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsecurewebproxystate", service, "off"]
            ))
        }

        if snapshot.socks.isEnabled && !snapshot.socks.host.isEmpty && snapshot.socks.port > 0 {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsocksfirewallproxy", service, snapshot.socks.host, "\(snapshot.socks.port)"]
            ))
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsocksfirewallproxystate", service, "on"]
            ))
        } else {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setsocksfirewallproxystate", service, "off"]
            ))
        }

        commands.append(ShellCommand(
            executable: executable,
            arguments: ["-setproxybypassdomains", service] + (snapshot.bypassList.isEmpty ? ["Empty"] : snapshot.bypassList)
        ))

        if snapshot.autoProxyEnabled && !snapshot.pacURL.isEmpty {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setautoproxyurl", service, snapshot.pacURL]
            ))
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setautoproxystate", service, "on"]
            ))
        } else {
            commands.append(ShellCommand(
                executable: executable,
                arguments: ["-setautoproxystate", service, "off"]
            ))
        }

        return commands
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
                let status = (try? stateStore.load()) ?? CoreStatus()
                if let applied = status.systemProxyApplied {
                    if status.systemProxyOwnership == .takenOver {
                        return []
                    }
                    if let previous = status.previousSystemProxySnapshot,
                       previous.networkService == applied.networkService,
                       previous.hasRestorableSettings {
                        return restoreCommands(from: previous)
                    }
                    return disableCommands(networkService: applied.networkService)
                        + pacDisableCommands(networkService: applied.networkService)
                }
                if let previous = status.previousSystemProxySnapshot,
                   previous.networkService == configuration.networkService,
                   previous.hasRestorableSettings {
                    return restoreCommands(from: previous)
                }
                return disableCommands(networkService: configuration.networkService)
                    + pacDisableCommands(networkService: configuration.networkService)
            }
            await pacHost.stop()
            return try disableSynchronously(configuration: configuration, preserveIntent: false, stopPAC: false)
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
        if previousApplied == nil {
            status.previousSystemProxySnapshot = before
        } else if previousApplied?.ownership(of: before) != .owned, !before.isCleared {
            status.previousSystemProxySnapshot = before
        }

        try await verifyTargetPort(configuration: configuration)
        switch configuration.mode {
        case .manual:
            await pacHost.stop()
        case .pac:
            let pacStatus = try await pacHost.start(
                Self.renderPACScript(configuration.pacScript, port: configuration.port)
            )
            guard let url = pacStatus.url else {
                await pacHost.stop()
                throw KumoError.commandFailed("PAC server did not return a URL.")
            }
            pacURL = url
        }
        do {
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
        } catch {
            if configuration.mode == .pac {
                await pacHost.stop()
            }
            throw error
        }
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
        try disableSynchronously(
            configuration: configuration,
            preserveIntent: preserveIntent,
            stopPAC: true
        )
    }

    private func disableSynchronously(
        configuration: SystemProxyConfiguration,
        preserveIntent: Bool,
        stopPAC: Bool
    ) throws -> [ShellCommand] {
        if stopPAC {
            pacHost.stopSynchronously()
        }
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
            if let previous = status.previousSystemProxySnapshot,
               previous.networkService == applied.networkService,
               previous.hasRestorableSettings {
                commands = restoreCommands(from: previous)
                try commands.forEach(commandRunner.run)
                let after = try snapshot(networkService: applied.networkService)
                guard after.matchesRestoredState(of: previous) else {
                    throw KumoError.commandFailed("macOS did not restore the previous proxy settings for \(applied.networkService).")
                }
                status.previousSystemProxySnapshot = nil
            } else {
                commands = disableCommands(networkService: applied.networkService)
                    + pacDisableCommands(networkService: applied.networkService)
                try commands.forEach(commandRunner.run)
                let after = try snapshot(networkService: applied.networkService)
                guard after.isCleared else {
                    throw KumoError.commandFailed("macOS did not clear Kumo's proxy settings for \(applied.networkService).")
                }
                if status.previousSystemProxySnapshot?.networkService == applied.networkService {
                    status.previousSystemProxySnapshot = nil
                }
            }
        }

        if !preserveIntent { status.systemProxyEnabled = false }
        status.systemProxyApplied = nil
        status.systemProxyOwnership = nil
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
