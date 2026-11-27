import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class PACServiceHostingTests: XCTestCase {
    func testSignedPACClientRequestsAndRoundTrip() throws {
        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let expectedURL = "http://127.0.0.1:41234/proxy.pac"

        let socket = try FakePACServiceSocket(socketPath: paths.userAgentSocketFile.path) { request in
            var seenNonces = Set<String>()
            XCTAssertTrue(
                KumoServiceRequestSigner.validate(
                    request,
                    credentials: credentials,
                    seenNonces: &seenNonces
                )
            )
            switch (request.method, request.path) {
            case ("POST", "/pac/start"):
                let payload = try JSONDecoder().decode(PACStartRequest.self, from: request.body)
                XCTAssertEqual(payload.script, "function FindProxyForURL() { return \"DIRECT\"; }")
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(isRunning: true, port: 41234, url: expectedURL)
                    )
                )
            case ("GET", "/pac/status"):
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(isRunning: true, port: 41234, url: expectedURL)
                    )
                )
            case ("POST", "/pac/stop"):
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(PACServerStatus(isRunning: false, port: nil, url: nil))
                )
            default:
                return KumoServiceTransportResponse(status: 404, error: "Unexpected route")
            }
        }
        defer { socket.stop() }

        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: paths.userAgentSocketFile.path),
            credentials: credentials
        )

        let started = try client.startPAC(script: "function FindProxyForURL() { return \"DIRECT\"; }")
        XCTAssertEqual(started, PACServerStatus(isRunning: true, port: 41234, url: expectedURL))

        let status = try client.pacStatus()
        XCTAssertEqual(status, started)

        let stopped = try client.stopPAC()
        XCTAssertEqual(stopped, PACServerStatus(isRunning: false, port: nil, url: nil))
        XCTAssertEqual(socket.receivedPaths(), ["/pac/start", "/pac/status", "/pac/stop"])
    }

    func testDelegatingPACHostRoutesEnableAndDisableThroughKumodSocket() async throws {
        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let hostedServer = PACServer()
        defer { Task { await hostedServer.stop() } }

        let socket = try FakePACServiceSocket(socketPath: paths.userAgentSocketFile.path) { request in
            switch (request.method, request.path) {
            case ("POST", "/pac/start"):
                let payload = try JSONDecoder().decode(PACStartRequest.self, from: request.body)
                let port = try await hostedServer.start(script: payload.script)
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(
                            isRunning: true,
                            port: port,
                            url: "http://127.0.0.1:\(port)/proxy.pac"
                        )
                    )
                )
            case ("POST", "/pac/stop"):
                await hostedServer.stop()
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(PACServerStatus(isRunning: false, port: nil, url: nil))
                )
            case ("GET", "/pac/status"):
                let running = await hostedServer.isRunning
                let port = await hostedServer.currentPort
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(
                            isRunning: running,
                            port: port,
                            url: port.map { "http://127.0.0.1:\($0)/proxy.pac" }
                        )
                    )
                )
            default:
                return KumoServiceTransportResponse(status: 404, error: "Unexpected route")
            }
        }
        defer { socket.stop() }

        let fallback = PACServer()
        let runner = FakePACNetworkSetupRunner()
        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: paths.userAgentSocketFile.path),
            credentials: credentials
        )
        let controller = SystemProxyController(
            paths: paths,
            commandRunner: runner.makeRunner(),
            targetPortProbe: { _, _ in true },
            pacHost: .delegating(remoteProvider: { client }, fallback: fallback)
        )

        let config = SystemProxyConfiguration(
            networkService: "Wi-Fi",
            host: "127.0.0.1",
            port: 17890,
            mode: .pac,
            pacScript: "function FindProxyForURL() { return \"PROXY 127.0.0.1:%mixed-port%\"; }"
        )
        let enableCommands = try await controller.setEnabled(true, configuration: config)
        let remotePort = await hostedServer.currentPort
        XCTAssertNotNil(remotePort)
        let expectedURL = "http://127.0.0.1:\(remotePort!)/proxy.pac"
        XCTAssertTrue(
            enableCommands.contains(
                ShellCommand(executable: "/usr/sbin/networksetup", arguments: ["-setautoproxyurl", "Wi-Fi", expectedURL])
            )
        )
        let fallbackRunning = await fallback.isRunning
        XCTAssertFalse(fallbackRunning, "delegating PACHost must not start fallback when kumod is reachable")

        _ = try await controller.setEnabled(false, configuration: config)
        let hostedStillRunning = await hostedServer.isRunning
        XCTAssertFalse(hostedStillRunning)
        XCTAssertEqual(socket.receivedPaths(), ["/pac/start", "/pac/stop"])
    }

    func testDelegatingPACHostFallsBackInProcessWhenKumodIsUnreachable() async throws {
        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        // Do not start a socket at userAgentSocketFile; client will fail with serviceUnavailable.
        let unreachableClient = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: paths.userAgentSocketFile.path),
            credentials: credentials
        )
        let fallback = PACServer()
        let runner = FakePACNetworkSetupRunner()
        let controller = SystemProxyController(
            paths: paths,
            commandRunner: runner.makeRunner(),
            targetPortProbe: { _, _ in true },
            pacHost: .delegating(remoteProvider: { unreachableClient }, fallback: fallback)
        )

        let config = SystemProxyConfiguration(
            networkService: "Wi-Fi",
            host: "127.0.0.1",
            port: 18890,
            mode: .pac,
            pacScript: "function FindProxyForURL() { return \"PROXY 127.0.0.1:%mixed-port%\"; }"
        )
        _ = try await controller.setEnabled(true, configuration: config)

        let fallbackPort = await fallback.currentPort
        let port = try XCTUnwrap(fallbackPort)
        let (data, response) = try await URLSession.shared.data(
            from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/proxy.pac"))
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "function FindProxyForURL() { return \"PROXY 127.0.0.1:18890\"; }"
        )

        _ = try await controller.setEnabled(false, configuration: config)
        let fallbackStillRunning = await fallback.isRunning
        XCTAssertFalse(fallbackStillRunning)
    }

    func testKeepCoreAlivePreservesRemotePACWhereasStopRuntimeStopsIt() async throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        let hostedServer = PACServer()
        defer { Task { await hostedServer.stop() } }

        let socket = try FakePACServiceSocket(socketPath: paths.userAgentSocketFile.path) { request in
            switch (request.method, request.path) {
            case ("GET", "/service/status"):
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(ServiceModeStatus(isInstalled: true, isRunning: true, isAvailable: true))
                )
            case ("GET", "/status"):
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(CoreStatus(state: .running, pid: 1234, ownerTier: .userAgent))
                )
            case ("POST", "/core/stop"):
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(CoreStatus(state: .stopped))
                )
            case ("POST", "/pac/start"):
                let payload = try JSONDecoder().decode(PACStartRequest.self, from: request.body)
                let port = try await hostedServer.start(script: payload.script)
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(
                            isRunning: true,
                            port: port,
                            url: "http://127.0.0.1:\(port)/proxy.pac"
                        )
                    )
                )
            case ("POST", "/pac/stop"):
                await hostedServer.stop()
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(PACServerStatus(isRunning: false, port: nil, url: nil))
                )
            default:
                return KumoServiceTransportResponse(status: 404, error: "Unexpected route")
            }
        }
        defer { socket.stop() }

        let runner = FakePACNetworkSetupRunner()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: runner.makeRunner(),
            systemProxyTargetPortProbe: { _, _ in true },
            reachability: BackendReachability(rootService: { false }, userAgent: { true }),
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil
        )
        try controller.updateSystemProxySettings(
            SystemProxySettings(
                networkService: "Wi-Fi",
                host: "127.0.0.1",
                port: 7890,
                mode: .pac,
                pacScript: "function FindProxyForURL() { return \"PROXY 127.0.0.1:%mixed-port%\"; }"
            )
        )
        _ = try await controller.setSystemProxy(true)
        let runningBeforeQuit = await hostedServer.isRunning
        XCTAssertTrue(runningBeforeQuit)

        let keepResult = await controller.prepareForAppTermination(policy: .keepCoreAlive)
        XCTAssertTrue(keepResult.diagnostics.isEmpty, "unexpected diagnostics: \(keepResult.diagnostics)")
        let runningAfterKeep = await hostedServer.isRunning
        XCTAssertTrue(runningAfterKeep, "keepCoreAlive must leave kumod PAC running")
        XCTAssertFalse(socket.receivedPaths().contains("/pac/stop"))

        let stopResult = await controller.prepareForAppTermination(policy: .stopRuntime)
        XCTAssertTrue(stopResult.diagnostics.isEmpty, "unexpected diagnostics: \(stopResult.diagnostics)")
        let runningAfterStop = await hostedServer.isRunning
        XCTAssertFalse(runningAfterStop, "stopRuntime must stop kumod PAC")
        XCTAssertTrue(socket.receivedPaths().contains("/pac/stop"))
    }

    func testKeepCoreAliveWarnsWhenInProcessPACRunsInDirectMode() async throws {
        let paths = hermeticPaths()
        let runner = FakePACNetworkSetupRunner()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: runner.makeRunner(),
            systemProxyTargetPortProbe: { _, _ in true }
        )
        try controller.updateSystemProxySettings(
            SystemProxySettings(
                networkService: "Wi-Fi",
                host: "127.0.0.1",
                port: 7890,
                mode: .pac,
                pacScript: "function FindProxyForURL() { return \"DIRECT\"; }"
            )
        )
        _ = try await controller.setSystemProxy(true)

        let result = await controller.prepareForAppTermination(policy: .keepCoreAlive)
        XCTAssertFalse(result.diagnostics.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("In-process PAC server will stop") })

        _ = try await controller.setSystemProxy(false)
    }

    func testPACEnableFailureStopsHostedAndFallbackPAC() async throws {
        // 1. Remote kumod-hosted PAC must receive /pac/stop when networksetup fails.
        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let hostedServer = PACServer()
        defer { Task { await hostedServer.stop() } }

        let socket = try FakePACServiceSocket(socketPath: paths.userAgentSocketFile.path) { request in
            switch (request.method, request.path) {
            case ("POST", "/pac/start"):
                let payload = try JSONDecoder().decode(PACStartRequest.self, from: request.body)
                let port = try await hostedServer.start(script: payload.script)
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(
                        PACServerStatus(isRunning: true, port: port, url: "http://127.0.0.1:\(port)/proxy.pac")
                    )
                )
            case ("POST", "/pac/stop"):
                await hostedServer.stop()
                return KumoServiceTransportResponse(
                    status: 200,
                    body: try JSONEncoder().encode(PACServerStatus(isRunning: false, port: nil, url: nil))
                )
            default:
                return KumoServiceTransportResponse(status: 404, error: "Unexpected route")
            }
        }
        defer { socket.stop() }

        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: paths.userAgentSocketFile.path),
            credentials: credentials
        )
        let failingRunner = SystemProxyCommandRunner(
            run: { command in
                if command.arguments.first == "-setautoproxyurl" {
                    throw KumoError.commandFailed("Simulated networksetup failure")
                }
            },
            captureOutput: { _ in
                "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0"
            }
        )
        let remoteController = SystemProxyController(
            paths: paths,
            commandRunner: failingRunner,
            targetPortProbe: { _, _ in true },
            pacHost: .delegating(remoteProvider: { client }, fallback: PACServer())
        )
        let config = SystemProxyConfiguration(
            networkService: "Wi-Fi",
            host: "127.0.0.1",
            port: 17890,
            mode: .pac,
            pacScript: "function FindProxyForURL() { return \"DIRECT\"; }"
        )

        do {
            _ = try await remoteController.setEnabled(true, configuration: config)
            XCTFail("Expected setEnabled to throw on networksetup failure")
        } catch {}

        let hostedStillRunning = await hostedServer.isRunning
        XCTAssertFalse(hostedStillRunning, "hosted PAC must stop when enable fails")
        XCTAssertEqual(socket.receivedPaths(), ["/pac/start", "/pac/stop"])

        // 2. In-process fallback PAC must also stop when post-apply ownership verification fails.
        let fallback = PACServer()
        let staleSnapshotRunner = SystemProxyCommandRunner(
            run: { _ in },
            captureOutput: { command in
                switch command.arguments.first {
                case "-getautoproxyurl":
                    return "URL: (null)\nEnabled: No"
                default:
                    return "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0"
                }
            }
        )
        let fallbackController = SystemProxyController(
            paths: paths,
            commandRunner: staleSnapshotRunner,
            targetPortProbe: { _, _ in true },
            pacHost: .inProcess(fallback)
        )

        do {
            _ = try await fallbackController.setEnabled(true, configuration: config)
            XCTFail("Expected setEnabled to throw on ownership verification failure")
        } catch {}

        let fallbackStillRunning = await fallback.isRunning
        XCTAssertFalse(fallbackStillRunning, "in-process PAC must stop when enable fails")
    }

    func testPACServerGenerationGuardPreventsStaleStopFromTearingDownNewerStart() async throws {
        let server = PACServer()
        defer { Task { await server.stop() } }

        let staleGeneration = server.currentGeneration()
        _ = try await server.start(script: "function FindProxyForURL() { return \"DIRECT\"; }")
        await server.stop(ifGenerationMatches: staleGeneration)

        let runningAfterStaleStop = await server.isRunning
        XCTAssertTrue(runningAfterStaleStop, "stale stop must not tear down a newer start")

        let currentGeneration = server.currentGeneration()
        await server.stop(ifGenerationMatches: currentGeneration)
        let runningAfterMatchingStop = await server.isRunning
        XCTAssertFalse(runningAfterMatchingStop)
    }

    func testRealKumoServiceHostsPACAcrossIdleTimeoutAndExitsAfterStop() async throws {
        guard let executableURL = Self.kumoServiceExecutableURL() else {
            throw XCTSkip("KumoService executable not built alongside test bundle.")
        }

        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "service", "run",
            "--mode", "user",
            "--app-support", paths.applicationSupportDirectory.path,
            "--idle-timeout", "2",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: paths.userAgentSocketFile.path),
            credentials: credentials
        )
        let deadline = Date().addingTimeInterval(5)
        while !client.ping() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for KumoService user agent socket")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let script = "function FindProxyForURL(url, host) { return \"PROXY 127.0.0.1:7890\"; }"
        let started = try client.startPAC(script: script)
        XCTAssertTrue(started.isRunning)
        let port = try XCTUnwrap(started.port)
        XCTAssertEqual(started.url, "http://127.0.0.1:\(port)/proxy.pac")

        let url = try XCTUnwrap(started.url.flatMap(URL.init(string:)))
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/x-ns-proxy-autoconfig")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), script)

        // Sleep past the 2s --idle-timeout; active PAC must keep kumod alive.
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertTrue(process.isRunning, "KumoService must stay alive past idle-timeout while PAC is active")
        XCTAssertTrue(try client.pacStatus().isRunning)

        let stopped = try client.stopPAC()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertFalse(try client.pacStatus().isRunning)

        let exitDeadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(process.isRunning, "KumoService should idle-exit after PAC stops")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Helpers

    private static func kumoServiceExecutableURL() -> URL? {
        let bundleSibling = Bundle(for: PACServiceHostingTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("KumoService")
        if FileManager.default.isExecutableFile(atPath: bundleSibling.path) {
            return bundleSibling
        }
        let debugFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/KumoService")
        if FileManager.default.isExecutableFile(atPath: debugFallback.path) {
            return debugFallback
        }
        return nil
    }

    private func hermeticPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: URL(
            fileURLWithPath: "/tmp/kumo-pac-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        ))
    }
}

private final class FakePACNetworkSetupRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var autoProxyEnabled = false
    private var pacURL = ""

    func makeRunner() -> SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in
                lock.lock(); defer { lock.unlock() }
                guard let verb = command.arguments.first else { return }
                switch verb {
                case "-setautoproxyurl":
                    if command.arguments.count >= 3 { pacURL = command.arguments[2] }
                case "-setautoproxystate":
                    if command.arguments.count >= 3 { autoProxyEnabled = command.arguments[2] == "on" }
                default:
                    break
                }
            },
            captureOutput: { [self] command in
                lock.lock(); defer { lock.unlock() }
                switch command.arguments.first {
                case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
                    return "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0"
                case "-getproxybypassdomains":
                    return "There aren't any bypass domains set on Wi-Fi."
                case "-getautoproxyurl":
                    return "URL: \(pacURL.isEmpty ? "(null)" : pacURL)\nEnabled: \(autoProxyEnabled ? "Yes" : "No")"
                default:
                    return ""
                }
            }
        )
    }
}

private final class FakePACServiceSocket: @unchecked Sendable {
    private let socketPath: String
    private let responder: @Sendable (KumoServiceSignedRequest) async throws -> KumoServiceTransportResponse
    private let lock = NSLock()
    private let acceptExit = DispatchSemaphore(value: 0)
    private var listener: Int32 = -1
    private var isStopped = false
    private var recordedPaths: [String] = []

    init(
        socketPath: String,
        responder: @escaping @Sendable (KumoServiceSignedRequest) async throws -> KumoServiceTransportResponse
    ) throws {
        self.socketPath = socketPath
        self.responder = responder

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.commandFailed("Unable to create a fake service socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            close(descriptor)
            throw KumoError.commandFailed("Fake service socket path is too long: \(socketPath)")
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                socketPath.withCString { strncpy(buffer, $0, maxPathLength - 1) }
            }
        }
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw KumoError.commandFailed("Unable to bind a fake service socket at \(socketPath).")
        }

        listener = descriptor
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let descriptor = listener
        lock.unlock()

        guard descriptor >= 0 else {
            unlink(socketPath)
            return
        }

        let waker = socket(AF_UNIX, SOCK_STREAM, 0)
        if waker >= 0 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            if socketPath.utf8.count < maxPathLength {
                _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                        socketPath.withCString { strncpy(buffer, $0, maxPathLength - 1) }
                    }
                }
            }
            _ = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(waker, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(waker)
        }
        _ = acceptExit.wait(timeout: .now() + 1)

        close(descriptor)
        unlink(socketPath)
    }

    func receivedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPaths
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            lock.lock()
            let stopped = isStopped
            lock.unlock()
            if stopped {
                if client >= 0 { close(client) }
                acceptExit.signal()
                return
            }
            guard client >= 0 else { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            payload.append(contentsOf: buffer.prefix(count))
        }

        let response: KumoServiceTransportResponse
        do {
            let transport = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: payload)
            let request = transport.signedRequest
            lock.lock()
            recordedPaths.append(request.path)
            lock.unlock()

            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            let responder = self.responder
            Task {
                do {
                    box.response = try await responder(request)
                } catch {
                    box.response = KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
                }
                semaphore.signal()
            }
            semaphore.wait()
            response = box.response ?? KumoServiceTransportResponse(status: 500, error: "No response")
        } catch {
            response = KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }

        guard let encoded = try? JSONEncoder().encode(response) else { return }
        encoded.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < encoded.count {
                let result = Darwin.write(client, baseAddress.advanced(by: written), encoded.count - written)
                guard result > 0 else { return }
                written += result
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var response: KumoServiceTransportResponse?
}
