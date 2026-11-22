import Darwin
import Foundation

public enum PortRole: String, Codable, Equatable, Sendable {
    case mixed
    case controller
}

/// A local TCP listener that prevents Mihomo from starting with the stored
/// settings. Process details are populated only when macOS identifies them.
public struct PortConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: PortRole { role }
    public let role: PortRole
    public let host: String
    public let port: Int
    public let pid: Int32?
    public let processName: String?
    public let suggestedPort: Int?

    public init(
        role: PortRole,
        host: String,
        port: Int,
        pid: Int32? = nil,
        processName: String? = nil,
        suggestedPort: Int? = nil
    ) {
        self.role = role
        self.host = host
        self.port = port
        self.pid = pid
        self.processName = processName
        self.suggestedPort = suggestedPort
    }

    public var displayMessage: String {
        let holder: String
        if let processName, !processName.isEmpty {
            holder = pid.map { "\(processName) (pid \($0))" } ?? processName
        } else if let pid {
            holder = "pid \(pid)"
        } else {
            holder = "an unknown process"
        }
        let suggestion = suggestedPort.map { " Suggested port: \($0)." } ?? ""
        return "The \(role.rawValue) port \(host):\(port) is in use by \(holder).\(suggestion)"
    }
}

struct PortListener: Equatable, Sendable {
    let pid: Int32?
    let processName: String?
}

/// Small seam around bind probes and the macOS process lookup. The controller
/// and supervisor share one instance so local and service launches use exactly
/// the same diagnostics and suggestions.
protocol PortInspecting: Sendable {
    func canListen(host: String, port: Int) -> Bool
    func listener(on port: Int) -> PortListener?
    func suggestedPort(host: String, after port: Int, excluding excluded: Set<Int>) -> Int?
}

struct LocalPortInspector: PortInspecting {
    func canListen(host: String, port: Int) -> Bool {
        guard !host.isEmpty, (1...65_535).contains(port) else { return false }
        return withAddresses(host: host, port: port) { addresses in
            for address in addresses {
                let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                // Mihomo's Go listener enables SO_REUSEADDR. Match that
                // contract so a recently stopped controller's TIME_WAIT tail
                // is not misreported as a live listener during restart. An
                // actively listening socket still rejects this bind.
                var reuse: Int32 = 1
                guard setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_REUSEADDR,
                    &reuse,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else { return false }
                guard bind(descriptor, address.ai_addr, address.ai_addrlen) == 0 else { return false }
            }
            return true
        } ?? false
    }

    func listener(on port: Int) -> PortListener? {
        guard (1...65_535).contains(port) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var pid: Int32?
        var processName: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("p"), pid == nil {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), processName == nil {
                let name = String(line.dropFirst())
                processName = name.isEmpty ? nil : name
            }
        }
        guard pid != nil || processName != nil else { return nil }
        return PortListener(pid: pid, processName: processName)
    }

    func suggestedPort(host: String, after port: Int, excluding excluded: Set<Int>) -> Int? {
        let first = max(1, port + 1)
        let sequentialEnd = min(65_535, max(first, port + 200))
        if first <= 65_535 {
            for candidate in first...sequentialEnd where !excluded.contains(candidate) {
                if canListen(host: host, port: candidate) {
                    return candidate
                }
            }
        }
        return ephemeralPort(host: host, excluding: excluded)
    }

    private func ephemeralPort(host: String, excluding excluded: Set<Int>) -> Int? {
        withAddresses(host: host, port: 0) { addresses in
            for address in addresses {
                let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                guard bind(descriptor, address.ai_addr, address.ai_addrlen) == 0 else { continue }

                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let named = withUnsafeMutablePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                guard named == 0 else { continue }
                let port: Int?
                if address.ai_family == AF_INET {
                    port = withUnsafePointer(to: &storage) { pointer in
                        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            Int(UInt16(bigEndian: $0.pointee.sin_port))
                        }
                    }
                } else if address.ai_family == AF_INET6 {
                    port = withUnsafePointer(to: &storage) { pointer in
                        pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                            Int(UInt16(bigEndian: $0.pointee.sin6_port))
                        }
                    }
                } else {
                    port = nil
                }
                if let port, port > 0, !excluded.contains(port) {
                    return port
                }
            }
            return nil
        } ?? nil
    }

    private func withAddresses<T>(
        host: String,
        port: Int,
        operation: ([addrinfo]) -> T
    ) -> T? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_PASSIVE
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0,
              let resolution = resolved else {
            return nil
        }
        defer { freeaddrinfo(resolution) }

        var addresses: [addrinfo] = []
        var candidate: UnsafeMutablePointer<addrinfo>? = resolution
        while let current = candidate {
            addresses.append(current.pointee)
            candidate = current.pointee.ai_next
        }
        guard !addresses.isEmpty else { return nil }
        return operation(addresses)
    }
}

extension PortInspecting {
    func conflicts(mixedHost: String, mixedPort: Int, controllerHost: String, controllerPort: Int) -> [PortConflict] {
        let sharesPort = mixedPort == controllerPort
        let mixedOccupied = sharesPort || !canListen(host: mixedHost, port: mixedPort)
        let controllerOccupied = sharesPort || !canListen(host: controllerHost, port: controllerPort)
        var reserved: Set<Int> = [mixedPort, controllerPort]
        var result: [PortConflict] = []

        func makeConflict(role: PortRole, host: String, port: Int) -> PortConflict {
            let suggested = suggestedPort(host: host, after: port, excluding: reserved)
            if let suggested {
                reserved.insert(suggested)
            }
            let holder = listener(on: port)
            return PortConflict(
                role: role,
                host: host,
                port: port,
                pid: holder?.pid,
                processName: holder?.processName,
                suggestedPort: suggested
            )
        }

        if mixedOccupied {
            result.append(makeConflict(role: .mixed, host: mixedHost, port: mixedPort))
        }
        if controllerOccupied {
            result.append(makeConflict(role: .controller, host: controllerHost, port: controllerPort))
        }
        return result
    }
}
