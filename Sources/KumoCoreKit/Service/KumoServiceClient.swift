import CryptoKit
import Darwin
import Foundation

public struct KumoServiceEndpoint: Codable, Equatable, Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }
}

public struct KumoServiceCredentials: Codable, Equatable, Sendable {
    public var keyID: String
    public var sharedSecret: String

    public init(keyID: String, sharedSecret: String) {
        self.keyID = keyID
        self.sharedSecret = sharedSecret
    }
}

public struct KumoServiceSignedRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: Data
    public var headers: [String: String]

    public init(method: String, path: String, body: Data = Data(), headers: [String: String]) {
        self.method = method
        self.path = path
        self.body = body
        self.headers = headers
    }
}

public struct KumoServiceTransportRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var bodyBase64: String

    public init(request: KumoServiceSignedRequest) {
        self.method = request.method
        self.path = request.path
        self.headers = request.headers
        self.bodyBase64 = request.body.base64EncodedString()
    }

    public var signedRequest: KumoServiceSignedRequest {
        KumoServiceSignedRequest(
            method: method,
            path: path,
            body: Data(base64Encoded: bodyBase64) ?? Data(),
            headers: headers
        )
    }
}

public struct KumoServiceTransportResponse: Codable, Equatable, Sendable {
    public var status: Int
    public var bodyBase64: String
    public var error: String?

    public init(status: Int, body: Data = Data(), error: String? = nil) {
        self.status = status
        self.bodyBase64 = body.base64EncodedString()
        self.error = error
    }

    public var body: Data {
        Data(base64Encoded: bodyBase64) ?? Data()
    }
}

public struct KumoServiceRequestSigner: Sendable {
    public var credentials: KumoServiceCredentials

    public init(credentials: KumoServiceCredentials) {
        self.credentials = credentials
    }

    public func signedRequest(
        method: String,
        path: String,
        query: String = "",
        body: Data = Data(),
        timestamp: Date = Date(),
        nonce: String = UUID().uuidString
    ) -> KumoServiceSignedRequest {
        let canonicalMethod = method.uppercased()
        let bodyHash = SHA256.hash(data: body).hexString
        let timestampValue = Self.timestampString(from: timestamp)
        let canonical = Self.canonicalString(
            timestamp: timestampValue,
            nonce: nonce,
            keyID: credentials.keyID,
            method: canonicalMethod,
            path: path,
            query: query,
            bodyHash: bodyHash
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(credentials.sharedSecret.utf8))
        ).hexString

        return KumoServiceSignedRequest(
            method: canonicalMethod,
            path: path,
            body: body,
            headers: [
                "X-Kumo-Auth-Version": "1",
                "X-Kumo-Key-ID": credentials.keyID,
                "X-Kumo-Timestamp": timestampValue,
                "X-Kumo-Nonce": nonce,
                "X-Kumo-Content-SHA256": bodyHash,
                "X-Kumo-Signature": signature
            ]
        )
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func validate(
        _ request: KumoServiceSignedRequest,
        credentials: KumoServiceCredentials,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 300,
        seenNonces: inout Set<String>
    ) -> Bool {
        guard request.headers["X-Kumo-Auth-Version"] == "1",
              request.headers["X-Kumo-Key-ID"] == credentials.keyID,
              let timestamp = request.headers["X-Kumo-Timestamp"],
              let nonce = request.headers["X-Kumo-Nonce"],
              let contentHash = request.headers["X-Kumo-Content-SHA256"],
              let signature = request.headers["X-Kumo-Signature"],
              contentHash == SHA256.hash(data: request.body).hexString,
              !seenNonces.contains(nonce) else {
            return false
        }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: timestamp),
              abs(now.timeIntervalSince(date)) <= allowedClockSkew else {
            return false
        }

        let canonical = canonicalString(
            timestamp: timestamp,
            nonce: nonce,
            keyID: credentials.keyID,
            method: request.method.uppercased(),
            path: request.path,
            query: "",
            bodyHash: contentHash
        )
        let expectedSignature = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(credentials.sharedSecret.utf8))
        ).hexString

        guard constantTimeEquals(signature, expectedSignature) else {
            return false
        }
        seenNonces.insert(nonce)
        return true
    }

    private static func canonicalString(
        timestamp: String,
        nonce: String,
        keyID: String,
        method: String,
        path: String,
        query: String,
        bodyHash: String
    ) -> String {
        [
            "KUMO-AUTH-V1",
            timestamp,
            nonce,
            keyID,
            method,
            path.isEmpty ? "/" : path,
            query,
            bodyHash
        ].joined(separator: "\n")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}

public struct KumoServiceClient: Sendable {
    public var endpoint: KumoServiceEndpoint
    public var signer: KumoServiceRequestSigner

    public init(endpoint: KumoServiceEndpoint, credentials: KumoServiceCredentials) {
        self.endpoint = endpoint
        self.signer = KumoServiceRequestSigner(credentials: credentials)
    }

    public func signedRequest(method: String, path: String, body: Data = Data()) -> KumoServiceSignedRequest {
        signer.signedRequest(method: method, path: path, body: body)
    }

    public func serviceStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/service/status")
    }

    public func installServiceRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/service/install")
    }

    public func uninstallServiceRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/service/uninstall")
    }

    public func tunStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/tun/status")
    }

    public func setTunEnabledRequest(_ isEnabled: Bool) -> KumoServiceSignedRequest {
        let path = isEnabled ? "/tun/enable" : "/tun/disable"
        return signedRequest(method: "POST", path: path)
    }

    public func applyTunSettingsRequest(_ settings: TunSettings) throws -> KumoServiceSignedRequest {
        let body = try JSONEncoder().encode(settings)
        return signedRequest(method: "POST", path: "/tun/settings", body: body)
    }

    public func statusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/status")
    }

    public func startCoreRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/core/start")
    }

    public func stopCoreRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/core/stop")
    }

    public func restartCoreRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "POST", path: "/core/restart")
    }

    public func systemProxyStatusRequest() -> KumoServiceSignedRequest {
        signedRequest(method: "GET", path: "/sysproxy/status")
    }

    public func setSystemProxyEnabledRequest(_ isEnabled: Bool) -> KumoServiceSignedRequest {
        let path = isEnabled ? "/sysproxy/enable" : "/sysproxy/disable"
        return signedRequest(method: "POST", path: path)
    }

    public func send(_ request: KumoServiceSignedRequest) throws -> KumoServiceTransportResponse {
        let transportRequest = KumoServiceTransportRequest(request: request)
        let payload = try JSONEncoder().encode(transportRequest)
        let responseData = try send(
            payload: payload,
            toSocketAt: endpoint.socketPath,
            receiveTimeout: Self.receiveTimeoutSeconds(for: request)
        )
        let response = try JSONDecoder().decode(KumoServiceTransportResponse.self, from: responseData)
        guard (200..<300).contains(response.status) else {
            throw KumoError.serviceUnavailable(response.error ?? "Kumo service returned status \(response.status).")
        }
        return response
    }

    /// The polling GET status paths are read on a 1 Hz cadence by
    /// `KumoServiceManager.status()`, so a wedged helper must not park the
    /// caller forever. Mutating requests (install, core start/stop, TUN apply)
    /// legitimately take longer than the receive bound and keep their previous
    /// unbounded receive behavior.
    private static func receiveTimeoutSeconds(for request: KumoServiceSignedRequest) -> Int32? {
        guard request.method.uppercased() == "GET" else { return nil }
        switch request.path {
        case "/service/status", "/status":
            return KumoServiceTimeout.receiveSeconds
        default:
            return nil
        }
    }

    public func sendDecodable<T: Decodable & Sendable>(
        _ request: KumoServiceSignedRequest,
        as type: T.Type
    ) throws -> T {
        let response = try send(request)
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    public func ping() -> Bool {
        (try? send(serviceStatusRequest())) != nil
    }

    private func send(payload: Data, toSocketAt path: String, receiveTimeout: Int32?) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KumoError.serviceUnavailable("Unable to create Kumo service socket.")
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            throw KumoError.serviceUnavailable("Kumo service socket path is too long: \(path)")
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                path.withCString { source in
                    strncpy(buffer, source, maxPathLength - 1)
                }
            }
        }

        try connect(descriptor, to: address, path: path)
        try configureTimeouts(descriptor, receiveTimeout: receiveTimeout)

        try writeAll(payload, to: descriptor)
        shutdown(descriptor, SHUT_WR)
        return try readAll(from: descriptor)
    }

    /// Non-blocking connect bounded by `KumoServiceTimeout.connect`, mirroring
    /// `CoreSupervisor.connectSucceeds(_:timeout:)`. On Darwin an AF_UNIX
    /// `connect` normally fails immediately (`ENOENT` for a missing socket,
    /// `ECONNREFUSED` when the listener is gone or its backlog is full), so the
    /// poll bound is defensive rather than routinely taken — it covers the
    /// `EINPROGRESS` case a full backlog produces on other kernels. The
    /// descriptor is left in blocking mode so the socket timeouts below apply to
    /// the subsequent write and read.
    private func connect(_ descriptor: Int32, to address: sockaddr_un, path: String) throws {
        let currentFlags = fcntl(descriptor, F_GETFL, 0)
        guard currentFlags >= 0, fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            throw KumoError.serviceUnavailable("Unable to configure Kumo service socket.")
        }

        let connectResult = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                throw KumoError.serviceUnavailable("Kumo service is not reachable at \(path).")
            }

            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32((KumoServiceTimeout.connect * 1000).rounded())
            guard Darwin.poll(&descriptorState, 1, milliseconds) > 0 else {
                throw KumoError.serviceUnavailable("Timed out connecting to Kumo service at \(path).")
            }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                throw KumoError.serviceUnavailable("Kumo service is not reachable at \(path).")
            }
        }

        guard fcntl(descriptor, F_SETFL, currentFlags) >= 0 else {
            throw KumoError.serviceUnavailable("Unable to configure Kumo service socket.")
        }
    }

    /// Bounds the request write on every path, and the response read only on the
    /// polling status paths (`receiveTimeout != nil`). A socket timeout surfaces
    /// from `write`/`read` as `EAGAIN`, which `writeAll`/`readAll` map to
    /// `KumoError.serviceUnavailable`.
    private func configureTimeouts(_ descriptor: Int32, receiveTimeout: Int32?) throws {
        var sendTimeout = timeval(tv_sec: Int(KumoServiceTimeout.sendSeconds), tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw KumoError.serviceUnavailable("Unable to configure Kumo service socket timeouts.")
        }

        guard let receiveTimeout else { return }
        var receiveTimeoutValue = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeoutValue,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw KumoError.serviceUnavailable("Unable to configure Kumo service socket timeouts.")
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )
                guard result > 0 else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw KumoError.serviceUnavailable("Timed out writing request to Kumo service.")
                    }
                    throw KumoError.serviceUnavailable("Failed to write request to Kumo service.")
                }
                bytesWritten += result
            }
        }
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
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw KumoError.serviceUnavailable("Timed out reading response from Kumo service.")
                }
                throw KumoError.serviceUnavailable("Failed to read response from Kumo service.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

/// Helper IPC timeouts. The helper is a launchd daemon that can be missing,
/// restarting, or wedged mid-install; without these bounds every call that
/// touches it blocks forever.
private enum KumoServiceTimeout {
    /// Seconds to allow the non-blocking connect handshake.
    static let connect: TimeInterval = 1
    /// Seconds to allow the request write, on every path.
    static let sendSeconds: Int32 = 10
    /// Seconds to allow the response read, on the polling status paths only.
    static let receiveSeconds: Int32 = 10
}

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension HMAC<SHA256>.MAC {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
