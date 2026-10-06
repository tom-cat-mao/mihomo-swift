import Foundation
import Network
import KumoCoreKit

/// Minimal loopback HTTP/1.1 server for profile-refresh tests.
///
/// `ProfileRepository.fetchRemoteProfileDocument` builds its own `URLSession`
/// internally (no injection seam), so tests that need a real subscription
/// response — including `profile-update-interval` headers — serve one from a
/// local listener instead of reaching the network.
final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "kumo.test.local-http")
    private let lock = NSLock()
    private var body: String
    private let extraHeaders: [(name: String, value: String)]
    private let ready = DispatchSemaphore(value: 0)
    private(set) var port = 0

    init(body: String, headers: [String: String] = [:]) throws {
        self.body = body
        self.extraHeaders = headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    /// The subscription URL every request path on this server maps to.
    var url: URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/sub.yaml") else {
            preconditionFailure("Local HTTP test server has no port")
        }
        return url
    }

    func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = Int(self.listener.port?.rawValue ?? 0)
                self.ready.signal()
            case .failed:
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(on: connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard port > 0 else {
            throw KumoError.commandFailed("Local HTTP test server did not start")
        }
    }

    func updateBody(_ next: String) {
        lock.lock()
        body = next
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    private func respond(on connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, _ in
            guard let self else { return }
            self.lock.lock()
            let payload = self.body
            self.lock.unlock()

            let headerLines = self.extraHeaders
                .map { "\($0.name): \($0.value)\r\n" }
                .joined()
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/yaml\r\n"
                + "Connection: close\r\n"
                + "Content-Length: \(payload.utf8.count)\r\n"
                + headerLines
                + "\r\n"
                + payload
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
