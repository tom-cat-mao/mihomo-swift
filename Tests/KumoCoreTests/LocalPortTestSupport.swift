import Darwin
import Foundation
@testable import KumoCoreKit

/// Test-only helpers for controller-port probing.
///
/// `CoreSupervisor.start()` refuses to spawn when something already listens on
/// the configured controller address, so tests that spawn fake cores must pick
/// a port nothing owns — never the default 9097, which a real Mihomo core may
/// hold on a developer machine.

/// Binds an ephemeral listener on 127.0.0.1 and reports the port it got.
func allocateLocalListener() throws -> (socket: Int32, port: Int) {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw KumoError.commandFailed("Unable to create a listener socket")
    }

    var reuse: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(socketFD, 1) == 0 else {
        close(socketFD)
        throw KumoError.commandFailed("Unable to bind a listener socket on 127.0.0.1")
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var resolved = sockaddr_in()
    let named = withUnsafeMutablePointer(to: &resolved) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    guard named == 0 else {
        close(socketFD)
        throw KumoError.commandFailed("Unable to read the bound listener port")
    }

    return (socketFD, Int(UInt16(bigEndian: resolved.sin_port)))
}

/// Returns a loopback port that is free at call time.
func allocateFreeLocalPort() throws -> Int {
    let listener = try allocateLocalListener()
    close(listener.socket)
    return listener.port
}
