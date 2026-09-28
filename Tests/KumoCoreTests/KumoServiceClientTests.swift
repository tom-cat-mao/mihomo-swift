import XCTest
import Darwin
@testable import KumoCoreKit

final class KumoServiceClientTests: XCTestCase {
    func testSignedRequestIncludesCanonicalAuthHeaders() {
        let signer = KumoServiceRequestSigner(
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let request = signer.signedRequest(
            method: "post",
            path: "/core/start",
            body: Data("{}".utf8),
            timestamp: Date(timeIntervalSince1970: 0),
            nonce: "nonce"
        )

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/core/start")
        XCTAssertEqual(request.headers["X-Kumo-Auth-Version"], "1")
        XCTAssertEqual(request.headers["X-Kumo-Key-ID"], "test-key")
        XCTAssertEqual(request.headers["X-Kumo-Nonce"], "nonce")
        XCTAssertNotNil(request.headers["X-Kumo-Content-SHA256"])
        XCTAssertNotNil(request.headers["X-Kumo-Signature"])
    }

    func testServiceClientBuildsTunEndpointRequests() {
        let client = KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: "/tmp/kumo.sock"),
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )

        XCTAssertEqual(client.statusRequest().path, "/status")
        XCTAssertEqual(client.startCoreRequest().path, "/core/start")
        XCTAssertEqual(client.stopCoreRequest().path, "/core/stop")
        XCTAssertEqual(client.restartCoreRequest().path, "/core/restart")
        XCTAssertEqual(client.systemProxyStatusRequest().path, "/sysproxy/status")
        XCTAssertEqual(client.setSystemProxyEnabledRequest(true).path, "/sysproxy/enable")
        XCTAssertEqual(client.setSystemProxyEnabledRequest(false).path, "/sysproxy/disable")
        XCTAssertEqual(client.serviceStatusRequest().path, "/service/status")
        XCTAssertEqual(client.installServiceRequest().path, "/service/install")
        XCTAssertEqual(client.uninstallServiceRequest().path, "/service/uninstall")
        XCTAssertEqual(client.tunStatusRequest().path, "/tun/status")
        XCTAssertEqual(client.setTunEnabledRequest(true).path, "/tun/enable")
        XCTAssertEqual(client.setTunEnabledRequest(false).path, "/tun/disable")
    }

    func testSignedRequestValidationRejectsReplayAndTampering() {
        let credentials = KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        let signer = KumoServiceRequestSigner(credentials: credentials)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let request = signer.signedRequest(
            method: "GET",
            path: "/service/status",
            timestamp: timestamp,
            nonce: "nonce"
        )
        var seenNonces = Set<String>()

        XCTAssertTrue(KumoServiceRequestSigner.validate(
            request,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))
        XCTAssertFalse(KumoServiceRequestSigner.validate(
            request,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))

        var tampered = request
        tampered.path = "/tun/enable"
        seenNonces.removeAll()
        XCTAssertFalse(KumoServiceRequestSigner.validate(
            tampered,
            credentials: credentials,
            now: timestamp,
            seenNonces: &seenNonces
        ))
    }

    func testTransportRequestRoundTripsSignedBody() throws {
        let signer = KumoServiceRequestSigner(
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
        let request = signer.signedRequest(method: "POST", path: "/sysproxy/enable", body: Data("{}".utf8))

        let transport = KumoServiceTransportRequest(request: request)
        let decoded = try JSONDecoder().decode(
            KumoServiceTransportRequest.self,
            from: JSONEncoder().encode(transport)
        ).signedRequest

        XCTAssertEqual(decoded.method, request.method)
        XCTAssertEqual(decoded.path, request.path)
        XCTAssertEqual(decoded.body, request.body)
        XCTAssertEqual(decoded.headers, request.headers)
    }

    func testControllerStatusUsesRunningServiceBackend() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()
        let serviceStatus = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            socketPath: paths.serviceSocketFile.path
        )
        let coreStatus = CoreStatus(state: .running, pid: 42, message: "from fake service")
        let fakeService = FakeKumoService(
            socketPath: paths.serviceSocketFile.path,
            credentials: credentials,
            responses: [
                "/service/status": try JSONEncoder().encode(serviceStatus),
                "/status": try JSONEncoder().encode(coreStatus)
            ]
        )
        try fakeService.start(expectedRequestCount: 2)
        defer { fakeService.stop() }

        let status = try KumoController(paths: paths).status()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 42)
        XCTAssertEqual(status.message, "from fake service")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - IPC timeouts

    /// `ping()` must stay non-throwing and resolve to `false` without waiting on
    /// the helper when the socket is missing, which is the state during a fresh
    /// install and after an uninstall.
    func testPingFailsWithoutHangingWhenServiceSocketIsAbsent() {
        let client = serviceClient(socketPath: shortSocketPath("missing"))

        let started = Date()
        XCTAssertFalse(client.ping())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// A leftover socket file whose listener is gone is refused immediately by
    /// the kernel, so the bound never has to engage here either.
    func testPingFailsWithoutHangingWhenSocketFileHasNoListener() throws {
        let socketPath = shortSocketPath("orphan")
        let descriptor = try boundSocket(at: socketPath)
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let started = Date()
        XCTAssertFalse(serviceClient(socketPath: socketPath).ping())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The wedged-helper case: the daemon is listening but no longer accepting,
    /// so the kernel's backlog queue fills up. On Darwin an AF_UNIX `connect`
    /// against a saturated listener is refused outright rather than parked, and
    /// it must surface as a prompt `false` instead of a hang.
    ///
    /// Note for future readers: because Darwin refuses instead of returning
    /// `EINPROGRESS`, the client's `poll(1 s)` connect bound is not reachable on
    /// this platform — AF_UNIX `connect` either completes or fails immediately.
    /// The bound mirrors `CoreSupervisor.connectSucceeds` and stays as
    /// defence-in-depth; the receive timeout is what actually bounds a helper
    /// that accepts a connection and then stalls.
    func testPingFailsPromptlyWhenListenerBacklogIsSaturated() throws {
        let socketPath = shortSocketPath("saturated")
        let listener = try SaturatedUnixListener(socketPath: socketPath)
        defer { listener.stop() }

        guard listener.saturateBacklog() else {
            throw XCTSkip("Could not saturate the Unix socket backlog on this machine.")
        }

        let started = Date()
        XCTAssertFalse(serviceClient(socketPath: socketPath).ping())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// `sun_path` is only 104 bytes, so tests that must reach the kernel need a
    /// deliberately short path rather than one under the deep per-user TMPDIR.
    private func shortSocketPath(_ label: String) -> String {
        "/tmp/kumo-test-\(label)-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    private func serviceClient(socketPath: String) -> KumoServiceClient {
        KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: socketPath),
            credentials: KumoServiceCredentials(keyID: "test-key", sharedSecret: "secret")
        )
    }
}

/// A listening Unix socket whose backlog is never drained, used to reproduce the
/// connect failure a wedged helper produces.
private final class SaturatedUnixListener {
    private let socketPath: String
    private let listenerDescriptor: Int32
    private var queuedDescriptors: [Int32] = []

    init(socketPath: String) throws {
        self.socketPath = socketPath
        try? FileManager.default.removeItem(atPath: socketPath)
        guard let address = unixSocketAddress(for: socketPath) else {
            throw KumoError.serviceUnavailable("Socket path is too long.")
        }

        listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerDescriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create listener socket.")
        }

        let bindResult = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(listenerDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenerDescriptor, 1) == 0 else {
            throw KumoError.serviceUnavailable("Unable to listen on \(socketPath).")
        }
    }

    /// Queues pending connections without ever calling `accept`. Returns `true`
    /// once a non-blocking connect observed `EINPROGRESS` (parked) or was
    /// refused, either of which means the backlog is full and further connects
    /// can no longer be completed.
    func saturateBacklog() -> Bool {
        for _ in 0..<16 {
            guard let address = unixSocketAddress(for: socketPath) else { return false }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            let currentFlags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)

            let result = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let connectError = errno
            queuedDescriptors.append(descriptor)
            if result != 0 {
                return connectError == EINPROGRESS || connectError == ECONNREFUSED
            }
        }
        return false
    }

    func stop() {
        for descriptor in queuedDescriptors {
            close(descriptor)
        }
        queuedDescriptors.removeAll()
        close(listenerDescriptor)
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

private func unixSocketAddress(for path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPathLength else { return nil }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
            path.withCString { source in
                strncpy(buffer, source, maxPathLength - 1)
            }
        }
    }
    return address
}

private func boundSocket(at path: String) throws -> Int32 {
    guard let address = unixSocketAddress(for: path) else {
        throw KumoError.serviceUnavailable("Socket path is too long.")
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw KumoError.serviceUnavailable("Unable to create socket.")
    }
    let bindResult = withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        close(descriptor)
        throw KumoError.serviceUnavailable("Unable to bind \(path).")
    }
    return descriptor
}

private final class FakeKumoService: @unchecked Sendable {
    private let socketPath: String
    private let credentials: KumoServiceCredentials
    private let responses: [String: Data]
    private let ready = DispatchSemaphore(value: 0)
    private var descriptor: Int32 = -1

    init(socketPath: String, credentials: KumoServiceCredentials, responses: [String: Data]) {
        self.socketPath = socketPath
        self.credentials = credentials
        self.responses = responses
    }

    func start(expectedRequestCount: Int) throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create fake service socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
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
        guard bindResult == 0, listen(descriptor, 4) == 0 else {
            throw KumoError.serviceUnavailable("Unable to bind fake service socket.")
        }

        DispatchQueue.global().async {
            self.ready.signal()
            var seenNonces = Set<String>()
            for _ in 0..<expectedRequestCount {
                let client = accept(self.descriptor, nil, nil)
                guard client >= 0 else { continue }
                defer { close(client) }
                let response = self.handle(client: client, seenNonces: &seenNonces)
                try? self.write(response: response, to: client)
            }
        }
        ready.wait()
    }

    func stop() {
        if descriptor >= 0 {
            close(descriptor)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handle(client: Int32, seenNonces: inout Set<String>) -> KumoServiceTransportResponse {
        do {
            let data = try readAll(from: client)
            let request = try JSONDecoder().decode(KumoServiceTransportRequest.self, from: data).signedRequest
            guard KumoServiceRequestSigner.validate(request, credentials: credentials, seenNonces: &seenNonces) else {
                return KumoServiceTransportResponse(status: 401, error: "invalid signature")
            }
            guard let body = responses[request.path] else {
                return KumoServiceTransportResponse(status: 404, error: request.path)
            }
            return KumoServiceTransportResponse(status: 200, body: body)
        } catch {
            return KumoServiceTransportResponse(status: 500, error: error.localizedDescription)
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                throw KumoError.serviceUnavailable("fake read failed")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func write(response: KumoServiceTransportResponse, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                guard result > 0 else { throw KumoError.serviceUnavailable("fake write failed") }
                bytesWritten += result
            }
        }
    }
}
