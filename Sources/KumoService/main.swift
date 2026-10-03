import Darwin
import Foundation
import KumoCoreKit

@main
enum KumoServiceMain {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard arguments.first == "service" else {
            print("Usage: KumoService service <install|uninstall|status|run>")
            return
        }
        let command = arguments.dropFirst().first ?? "status"
        let remaining = Array(arguments.dropFirst(2))
        switch command {
        case "install":
            try install(arguments: remaining)
        case "uninstall":
            try uninstall(arguments: remaining)
        case "status":
            try printStatus(arguments: remaining)
        case "run":
            try await runDaemon(arguments: remaining)
        default:
            throw KumoError.invalidArguments("Unknown service command: \(command)")
        }
    }

    private static func install(arguments: [String]) throws {
        let mode = try ServiceMode.parse(arguments: arguments)
        if mode == .user {
            // The user tier registers a LaunchAgent; KumoUserAgentManager owns
            // the launchctl/ServiceManagement details in one place.
            guard let source = value(after: "--source", in: arguments),
                  let appSupport = value(after: "--app-support", in: arguments) else {
                throw KumoError.invalidArguments("Usage: KumoService service install --mode user --source <path> --app-support <path> [--idle-timeout <seconds>]")
            }
            let idleTimeoutSeconds = try ServiceIdlePolicy.parseTimeoutSeconds(arguments: arguments)
            let paths = KumoPaths(applicationSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
            try KumoUserAgentManager(paths: paths, idleTimeoutSeconds: idleTimeoutSeconds)
                .install(executable: URL(fileURLWithPath: source))
            return
        }
        guard geteuid() == 0 else {
            throw KumoError.serviceUnavailable("KumoService install must run with administrator privileges.")
        }
        guard let source = value(after: "--source", in: arguments),
              let appSupport = value(after: "--app-support", in: arguments),
              let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init),
              let keyID = value(after: "--key-id", in: arguments),
              let sharedSecret = value(after: "--shared-secret", in: arguments) else {
            throw KumoError.invalidArguments("Usage: KumoService service install --source <path> --app-support <path> --authorized-uid <uid> --key-id <id> --shared-secret <secret>")
        }

        let paths = KumoPaths(applicationSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try paths.prepare()
        try FileManager.default.createDirectory(
            at: paths.serviceExecutableFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if source != paths.serviceExecutableFile.path,
           FileManager.default.fileExists(atPath: paths.serviceExecutableFile.path) {
            try FileManager.default.removeItem(at: paths.serviceExecutableFile)
        }
        if source != paths.serviceExecutableFile.path {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: paths.serviceExecutableFile)
        }
        chmod(paths.serviceExecutableFile.path, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        chown(paths.serviceExecutableFile.path, 0, 0)

        let credentials = KumoServiceCredentials(keyID: keyID, sharedSecret: sharedSecret)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(credentials).write(to: paths.serviceCredentialsFile, options: .atomic)
        chown(paths.serviceCredentialsFile.path, authorizedUID, getgid())
        chmod(paths.serviceCredentialsFile.path, S_IRUSR | S_IWUSR)

        let plist = ServiceMode.rootLaunchDaemonPlist(paths: paths, authorizedUID: authorizedUID)
        try plist.write(to: paths.serviceLaunchDaemonPlistFile, atomically: true, encoding: .utf8)
        chown(paths.serviceLaunchDaemonPlistFile.path, 0, 0)
        chmod(paths.serviceLaunchDaemonPlistFile.path, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)

        _ = try? runCommand("/bin/launchctl", ["bootout", "system/\(KumoServiceManager.launchDaemonLabel)"])
        try runCommand("/bin/launchctl", ["bootstrap", "system", paths.serviceLaunchDaemonPlistFile.path])
        _ = try? runCommand("/bin/launchctl", ["kickstart", "-k", "system/\(KumoServiceManager.launchDaemonLabel)"])
        try saveStatus(paths: paths, installed: true, running: false)
    }

    private static func uninstall(arguments: [String]) throws {
        let mode = try ServiceMode.parse(arguments: arguments)
        if mode == .user {
            guard let appSupport = value(after: "--app-support", in: arguments) else {
                throw KumoError.invalidArguments("Usage: KumoService service uninstall --mode user --app-support <path>")
            }
            let paths = KumoPaths(applicationSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
            try KumoUserAgentManager(paths: paths).uninstall()
            return
        }
        guard geteuid() == 0 else {
            throw KumoError.serviceUnavailable("KumoService uninstall must run with administrator privileges.")
        }
        let appSupport = value(after: "--app-support", in: arguments)
        let paths = KumoPaths(applicationSupportDirectory: appSupport.map { URL(fileURLWithPath: $0, isDirectory: true) })
        _ = try? runCommand("/bin/launchctl", ["bootout", "system/\(KumoServiceManager.launchDaemonLabel)"])
        try? FileManager.default.removeItem(at: paths.serviceLaunchDaemonPlistFile)
        try? FileManager.default.removeItem(at: paths.serviceExecutableFile)
        try? FileManager.default.removeItem(at: paths.serviceSocketFile)
        try saveStatus(paths: paths, installed: false, running: false)
    }

    private static func printStatus(arguments: [String]) throws {
        let mode = try ServiceMode.parse(arguments: arguments)
        if mode == .user {
            let appSupport = value(after: "--app-support", in: arguments)
            let paths = KumoPaths(applicationSupportDirectory: appSupport.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let status = KumoUserAgentManager(paths: paths).status()
            let data = try JSONEncoder().encode(status)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        let appSupport = value(after: "--app-support", in: arguments)
        let paths = KumoPaths(applicationSupportDirectory: appSupport.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let status = ServiceModeStatus(
            isInstalled: FileManager.default.fileExists(atPath: paths.serviceLaunchDaemonPlistFile.path),
            isRunning: FileManager.default.fileExists(atPath: paths.serviceSocketFile.path),
            isAvailable: geteuid() == 0 || FileManager.default.fileExists(atPath: paths.serviceSocketFile.path),
            isCurrentProcessPrivileged: geteuid() == 0,
            socketPath: paths.serviceSocketFile.path
        )
        let data = try JSONEncoder().encode(status)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func runDaemon(arguments: [String]) async throws {
        let mode = try ServiceMode.parse(arguments: arguments)
        guard let appSupport = value(after: "--app-support", in: arguments) else {
            throw KumoError.invalidArguments("KumoService service run requires --app-support <path>.")
        }
        let authorizedUID = value(after: "--authorized-uid", in: arguments).flatMap(uid_t.init) ?? getuid()
        // The user agent is on-demand: it exits after `--idle-timeout` seconds
        // without traffic and with no core running. Root-mode behavior is
        // unchanged — the privileged daemon stays resident.
        let idleTimeout: TimeInterval = mode == .user
            ? TimeInterval(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: arguments))
            : 0
        let paths = KumoPaths(applicationSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try paths.prepare()
        // Root-mode startup repair. The daemon runs as root, so on a fresh
        // service-mode install it may have created state files, logs or work
        // files as root:staff before the app or CLI ever wrote them (Issue
        // #3). Hand everything back to the authorized user once per launch;
        // that is the upgrade path for installs already in the broken state.
        // The user agent runs as its own owner and never needs this.
        let ownershipRepair: AppSupportOwnershipRepair? = mode.repairsAppSupportOwnership
            ? AppSupportOwnershipRepair(
                applicationSupportDirectory: paths.applicationSupportDirectory,
                authorizedUID: authorizedUID
            )
            : nil
        ownershipRepair?.repair()
        let credentials = try KumoServiceManager(paths: paths).loadCredentials()
        let logger = mode == .user ? KumoServiceLogger(fileURL: paths.userAgentLogFile) : nil
        logger?.log("service starting: mode=\(mode.rawValue) pid=\(getpid()) idle-timeout=\(Int(idleTimeout))s")
        let server = KumoServiceSocketServer(
            paths: paths,
            mode: mode,
            credentials: credentials,
            authorizedUID: authorizedUID,
            ownershipRepair: ownershipRepair,
            idleTimeout: idleTimeout,
            logger: logger
        )
        try await server.run()
    }

    fileprivate static func saveStatus(paths: KumoPaths, installed: Bool, running: Bool) throws {
        let status = ServiceModeStatus(
            isInstalled: installed,
            isRunning: running,
            isAvailable: running || geteuid() == 0,
            isCurrentProcessPrivileged: geteuid() == 0,
            socketPath: paths.serviceSocketFile.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: paths.serviceStatusFile, options: .atomic)
    }

    @discardableResult
    private static func runCommand(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KumoError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

private final class KumoServiceSocketServer: @unchecked Sendable {
    private let paths: KumoPaths
    private let mode: ServiceMode
    private let credentials: KumoServiceCredentials
    private let authorizedUID: uid_t
    private let ownershipRepair: AppSupportOwnershipRepair?
    private let idleTimeout: TimeInterval
    private let logger: KumoServiceLogger?
    private var seenNonces = Set<String>()

    init(
        paths: KumoPaths,
        mode: ServiceMode,
        credentials: KumoServiceCredentials,
        authorizedUID: uid_t,
        ownershipRepair: AppSupportOwnershipRepair?,
        idleTimeout: TimeInterval,
        logger: KumoServiceLogger?
    ) {
        self.paths = paths
        self.mode = mode
        self.credentials = credentials
        self.authorizedUID = authorizedUID
        self.ownershipRepair = ownershipRepair
        self.idleTimeout = idleTimeout
        self.logger = logger
    }

    func run() async throws {
        let socketFile = mode.socketFile(in: paths)
        let listener = try prepareListener(socketFile: socketFile)
        defer { close(listener.descriptor) }

        if mode.writesSharedStatusFile {
            try KumoServiceMain.saveStatus(paths: paths, installed: true, running: true)
        }
        ownershipRepair?.repair()

        // Root mode keeps blocking in accept() forever. The user agent
        // re-evaluates an idle-exit policy between accepts and exits once it
        // has been idle for `idleTimeout` seconds with no core running.
        var idlePolicy = mode == .user
            ? ServiceIdlePolicy(timeout: idleTimeout, now: Date())
            : nil

        while true {
            let isCoreRunning = idlePolicy == nil ? false : ownedCoreIsRunning()
            let pollTimeout = idlePolicy.map { policy in
                Int32((policy.nextCheckIntervalSeconds(at: Date(), isCoreRunning: isCoreRunning) * 1000).rounded())
            } ?? -1

            var descriptorState = pollfd(fd: listener.descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptorState, 1, pollTimeout)
            if pollResult == 0 {
                // Re-check core ownership at the decision point so a core
                // started by another tier during the poll window still
                // suppresses the exit.
                guard idlePolicy != nil, ownedCoreIsRunning() == false else { continue }
                if idlePolicy?.shouldExit(now: Date(), isCoreRunning: false) == true {
                    logger?.log("idle-exit: no client request for \(Int(idleTimeout))s and no core running")
                    close(listener.descriptor)
                    removeSelfBoundSocketIfNeeded(listener, socketFile: socketFile)
                    Foundation.exit(0)
                }
                continue
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw KumoError.serviceUnavailable("Service socket poll failed.")
            }

            let client = accept(listener.descriptor, nil, nil)
            guard client >= 0 else { continue }
            idlePolicy?.requestStarted(at: Date())
            let response = await handleConnection(client)
            try? writeResponse(response, to: client)
            close(client)
            idlePolicy?.requestFinished(at: Date())
        }
    }

    /// A launchd-activated listener (`Sockets` in the user-agent plist) is
    /// adopted instead of binding a fresh socket, so launchd can start the
    /// agent on demand and keep the endpoint alive across idle exits. Root
    /// mode and manual/dev runs fall back to binding the socket themselves.
    private func prepareListener(socketFile: URL) throws -> Listener {
        if mode == .user,
           let activated = LaunchdSocketActivation.activatedListener(named: KumoUserAgentManager.launchdListenerSocketName) {
            logger?.log("socket adopted from launchd at \(socketFile.path)")
            return Listener(descriptor: activated, adoptedFromLaunchd: true)
        }

        try? FileManager.default.removeItem(at: socketFile)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create service socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = socketFile.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            close(descriptor)
            throw KumoError.serviceUnavailable("Service socket path is too long: \(socketPath)")
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                socketPath.withCString { source in
                    strncpy(buffer, source, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw KumoError.serviceUnavailable("Unable to bind service socket at \(socketPath).")
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        if mode.chownsSharedFilesToAuthorizedUID {
            chown(socketPath, authorizedUID, getgid())
        }

        guard listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw KumoError.serviceUnavailable("Unable to listen on service socket.")
        }
        logger?.log("socket bound at \(socketPath)")
        return Listener(descriptor: descriptor, adoptedFromLaunchd: false)
    }

    /// A launchd-created socket must survive the agent: launchd owns the path
    /// and reuses it to start the agent on the next connection.
    private func removeSelfBoundSocketIfNeeded(_ listener: Listener, socketFile: URL) {
        guard !listener.adoptedFromLaunchd else { return }
        try? FileManager.default.removeItem(at: socketFile)
    }

    /// True while a Mihomo core this tier is responsible for is running.
    /// Unknown/unreadable state is treated as running so the agent never
    /// exits out from under a core it cannot observe.
    private func ownedCoreIsRunning() -> Bool {
        do {
            let status = try KumoController(paths: paths, useServiceBackend: false).status()
            return status.state == .running
        } catch {
            logger?.log("idle-check failed to read core status: \(error.localizedDescription)")
            return true
        }
    }

    private func handleConnection(_ descriptor: Int32) async -> KumoServiceTransportResponse {
        do {
            let data = try readAll(from: descriptor)
            let transport = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: data)
            let request = transport.signedRequest
            guard KumoServiceRequestSigner.validate(request, credentials: credentials, seenNonces: &seenNonces) else {
                return KumoServiceTransportResponse(status: 401, error: "Invalid Kumo service signature.")
            }
            // See `routeWritesAppSupportState(_:)`.
            defer {
                if Self.routeWritesAppSupportState(request.path) {
                    ownershipRepair?.repair()
                }
            }
            return try await route(request)
        } catch {
            return KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }
    }

    /// Everything except the couple of pure-read routes runs a
    /// `KumoController` call that can write app-support files as root:
    /// `core/start` and `core/stop` obviously, but also `/status`, whose pid
    /// recovery and stale-pid cleanup persist state. Handing those files back
    /// to the authorized user after the handler (including when it throws after
    /// writing a failed status) keeps the caller-side bookkeeping writable
    /// (Issue #3).
    private static func routeWritesAppSupportState(_ path: String) -> Bool {
        path != "/service/status" && path != "/tun/status"
    }

    private func route(_ request: KumoServiceSignedRequest) async throws -> KumoServiceTransportResponse {
        let controller = KumoController(paths: paths, useServiceBackend: false)
        switch (request.method, request.path) {
        case ("GET", "/service/status"):
            return try json(ServiceModeStatus(
                isInstalled: true,
                isRunning: true,
                isAvailable: true,
                isCurrentProcessPrivileged: geteuid() == 0,
                socketPath: mode.socketFile(in: paths).path,
                message: mode.serviceStatusMessage
            ))
        case ("GET", "/status"), ("GET", "/sysproxy/status"):
            return try json(controller.status())
        case ("POST", "/core/start"):
            let started = try controller.start()
            logger?.log("core start observed: pid \(started.pid.map(String.init) ?? "unknown")")
            try await controller.waitForControllerReady()
            return try json(controller.status())
        case ("POST", "/core/stop"):
            let stopped = try controller.stop()
            logger?.log("core stop observed: state=\(stopped.state.rawValue)")
            return try json(stopped)
        case ("POST", "/core/restart"):
            let restarted = try controller.restart()
            logger?.log("core restart observed: pid \(restarted.pid.map(String.init) ?? "unknown")")
            try await controller.waitForControllerReady()
            return try json(controller.status())
        case ("POST", "/sysproxy/enable"):
            _ = try await controller.setSystemProxy(true)
            return try json(controller.status())
        case ("POST", "/sysproxy/disable"):
            _ = try await controller.setSystemProxy(false)
            return try json(controller.status())
        case ("GET", "/tun/status"):
            return try json(controller.tunStatus())
        case ("POST", "/tun/enable"):
            return try json(try await controller.setTunEnabled(true))
        case ("POST", "/tun/disable"):
            return try json(try await controller.setTunEnabled(false))
        case ("POST", "/tun/settings"):
            let settings = try JSONDecoder().decode(TunSettings.self, from: request.body)
            return try json(try await controller.applyTunSettings(settings))
        default:
            return KumoServiceTransportResponse(status: 404, error: "Unknown Kumo service endpoint: \(request.method) \(request.path)")
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> KumoServiceTransportResponse {
        KumoServiceTransportResponse(status: 200, body: try JSONEncoder().encode(value))
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data
            }
            guard count > 0 else {
                throw KumoError.serviceUnavailable("Failed to read service request.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeResponse(_ response: KumoServiceTransportResponse, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                guard result > 0 else {
                    throw KumoError.serviceUnavailable("Failed to write service response.")
                }
                bytesWritten += result
            }
        }
    }
}

private struct Listener {
    let descriptor: Int32
    /// True when the descriptor came from `launch_activate_socket`, meaning
    /// launchd owns the socket path and must be left to manage it.
    let adoptedFromLaunchd: Bool
}

/// Adapts launchd's on-demand socket activation (`Sockets` in the plist).
/// `<launch.h>` is not part of the Darwin Swift overlay, so the C entry point
/// is declared directly.
private enum LaunchdSocketActivation {
    /// Returns the first activated listener, or nil when the process was not
    /// started by launchd for a `Sockets` entry of this name (manual runs,
    /// root daemon, misconfiguration). Extra descriptors are closed.
    static func activatedListener(named name: String) -> Int32? {
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let result = name.withCString { launch_activate_socket($0, &descriptors, &count) }
        guard result == 0, let descriptors, count > 0 else {
            return nil
        }
        defer { free(descriptors) }
        for index in 1..<count {
            close(descriptors[index])
        }
        return descriptors[0]
    }
}

@_silgen_name("launch_activate_socket")
private func launch_activate_socket(
    _ name: UnsafePointer<CChar>,
    _ descriptors: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ count: UnsafeMutablePointer<Int>
) -> Int32

/// Appends user-agent lifecycle lines to `logs/agent.log`. Under launchd the
/// same file receives stdout/stderr, so when stdout already points at the log
/// file the direct append is skipped and stdout is the only writer (avoiding
/// duplicate lines); in dev runs stdout is a terminal and both are written.
private final class KumoServiceLogger: @unchecked Sendable {
    private let fileURL: URL
    private let writesToStandardOutput: Bool
    private let formatter: ISO8601DateFormatter

    init(fileURL: URL) {
        self.fileURL = fileURL
        Self.ensureLogFile(at: fileURL)
        self.writesToStandardOutput = !Self.standardOutputIsSameFile(as: fileURL)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if writesToStandardOutput {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            fputs("kumod: unable to append agent log: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func ensureLogFile(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private static func standardOutputIsSameFile(as url: URL) -> Bool {
        var outputStat = stat()
        guard fstat(STDOUT_FILENO, &outputStat) == 0 else { return false }
        var fileStat = stat()
        guard stat(url.path, &fileStat) == 0 else { return false }
        return outputStat.st_dev == fileStat.st_dev && outputStat.st_ino == fileStat.st_ino
    }
}
