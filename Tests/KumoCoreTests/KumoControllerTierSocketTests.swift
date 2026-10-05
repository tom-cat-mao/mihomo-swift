import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

/// Socket-level routing tests: a fake signed-service socket stands in for each
/// tier, so the tests prove which tier `KumoController` actually called without
/// launchd, real daemons, or network access.
final class KumoControllerTierSocketTests: XCTestCase {
    func testStatusReportsAgentOwnedCoreAfterGuiRelaunch() throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        // The GUI's on-disk view is stale/stopped; the agent owns a live core.
        try CoreStateStore(paths: paths).save(CoreStatus(state: .stopped))

        let agentCore = CoreStatus(state: .running, pid: 777, message: "Mihomo core is running.")
        let agent = try FakeServiceSocket(socketPath: paths.userAgentSocketFile.path) { _ in
            KumoServiceTransportResponse(status: 200, body: try JSONEncoder().encode(agentCore))
        }
        defer { agent.stop() }
        let root = try FakeServiceSocket(socketPath: paths.serviceSocketFile.path) { _ in
            KumoServiceTransportResponse(status: 200, body: try JSONEncoder().encode(CoreStatus()))
        }
        defer { root.stop() }
        let controller = makeController(paths: paths, rootReachable: true, agentReachable: true)

        let status = try controller.status()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 777)
        XCTAssertEqual(agent.receivedPaths(), ["/status"])
        XCTAssertTrue(root.receivedPaths().isEmpty, "TUN-off status must not consult the root daemon")
    }

    func testStartRoutesToUserAgentWhenTunIsOff() throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()

        let agent = try FakeServiceSocket(socketPath: paths.userAgentSocketFile.path) { _ in
            KumoServiceTransportResponse(
                status: 200,
                body: try JSONEncoder().encode(CoreStatus(state: .running, pid: 888))
            )
        }
        defer { agent.stop() }
        let controller = makeController(paths: paths, rootReachable: true, agentReachable: true)

        let status = try controller.start()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 888)
        XCTAssertEqual(agent.receivedPaths(), ["/core/start"])
    }

    func testStopRoutesToUserAgentWhenTunIsOff() throws {
        // The app-update path (KumoAppStore.stopCore -> CoreRuntimeRunner.stop)
        // must stop a TUN-off core through the owning socket tier; this pins
        // that `KumoController.stop()` never falls back to a local supervisor
        // call that would miss an agent-owned core.
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: 999,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))

        let agent = try FakeServiceSocket(socketPath: paths.userAgentSocketFile.path) { _ in
            KumoServiceTransportResponse(
                status: 200,
                body: try JSONEncoder().encode(CoreStatus(state: .stopped))
            )
        }
        defer { agent.stop() }
        let root = try FakeServiceSocket(socketPath: paths.serviceSocketFile.path) { _ in
            KumoServiceTransportResponse(
                status: 200,
                body: try JSONEncoder().encode(CoreStatus(state: .running, pid: 999))
            )
        }
        defer { root.stop() }
        let controller = makeController(paths: paths, rootReachable: true, agentReachable: true)

        let status = try controller.stop()

        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(agent.receivedPaths(), ["/core/stop"])
        XCTAssertTrue(root.receivedPaths().isEmpty, "a TUN-off stop must not consult the root daemon")
    }

    func testTunOnRoutesStopToRootDaemonAndNotTheAgent() throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: 999,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))

        let root = try FakeServiceSocket(socketPath: paths.serviceSocketFile.path) { _ in
            KumoServiceTransportResponse(
                status: 200,
                body: try JSONEncoder().encode(CoreStatus(state: .stopped))
            )
        }
        defer { root.stop() }
        let agent = try FakeServiceSocket(socketPath: paths.userAgentSocketFile.path) { _ in
            KumoServiceTransportResponse(
                status: 200,
                body: try JSONEncoder().encode(CoreStatus(state: .running, pid: 999))
            )
        }
        defer { agent.stop() }
        let controller = makeController(paths: paths, rootReachable: true, agentReachable: true)

        let status = try controller.stop()

        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(root.receivedPaths(), ["/core/stop"])
        XCTAssertTrue(agent.receivedPaths().isEmpty, "TUN-on operations must go to the root daemon")
    }

    // MARK: - Helpers

    private func makeController(
        paths: KumoPaths,
        rootReachable: Bool,
        agentReachable: Bool
    ) -> KumoController {
        KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: .live,
            reachability: BackendReachability(
                rootService: { rootReachable },
                userAgent: { agentReachable }
            ),
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil
        )
    }

    private func hermeticPaths() -> KumoPaths {
        // Short path so the AF_UNIX socket path stays inside `sun_path`.
        KumoPaths(applicationSupportDirectory: URL(
            fileURLWithPath: "/tmp/kumo-tier-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        ))
    }
}

/// Minimal AF_UNIX server that answers `KumoServiceClient` requests with a
/// configured `KumoServiceTransportResponse`. One client at a time; the tests
/// call it sequentially.
private final class FakeServiceSocket: @unchecked Sendable {
    private let socketPath: String
    private let responder: @Sendable (KumoServiceSignedRequest) throws -> KumoServiceTransportResponse
    private let lock = NSLock()
    private let acceptExit = DispatchSemaphore(value: 0)
    private var listener: Int32 = -1
    private var isStopped = false
    private var recordedPaths: [String] = []

    init(
        socketPath: String,
        responder: @escaping @Sendable (KumoServiceSignedRequest) throws -> KumoServiceTransportResponse
    ) throws {
        self.socketPath = socketPath
        self.responder = responder

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

        // Wake the blocked accept with a self-connect before closing the
        // listener, so the worker observes `isStopped` and exits without the
        // listener descriptor being closed underneath a live `accept`.
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
                if client >= 0 {
                    close(client)
                }
                acceptExit.signal()
                return
            }
            guard client >= 0 else {
                return
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else {
                break
            }
            payload.append(contentsOf: buffer.prefix(count))
        }

        let response: KumoServiceTransportResponse
        do {
            let transport = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: payload)
            let request = transport.signedRequest
            lock.lock()
            recordedPaths.append(request.path)
            lock.unlock()
            response = try responder(request)
        } catch {
            response = KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }

        guard let encoded = try? JSONEncoder().encode(response) else {
            return
        }
        encoded.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < encoded.count {
                let result = Darwin.write(client, baseAddress.advanced(by: written), encoded.count - written)
                guard result > 0 else {
                    return
                }
                written += result
            }
        }
    }
}
