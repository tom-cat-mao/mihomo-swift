import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class PortConflictTests: XCTestCase {
    func testOccupiedMixedPortReportsListenerAndFreeSuggestionAvoidsController() throws {
        let listener = try allocateLocalListener()
        defer { close(listener.socket) }
        let controllerPort = try allocateFreeLocalPort()
        let inspector = LocalPortInspector()

        let conflicts = inspector.conflicts(
            mixedHost: "127.0.0.1",
            mixedPort: listener.port,
            controllerHost: "127.0.0.1",
            controllerPort: controllerPort
        )

        XCTAssertEqual(conflicts.count, 1)
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.role, .mixed)
        XCTAssertEqual(conflict.host, "127.0.0.1")
        XCTAssertEqual(conflict.port, listener.port)
        let suggestion = try XCTUnwrap(conflict.suggestedPort)
        XCTAssertNotEqual(suggestion, listener.port)
        XCTAssertNotEqual(suggestion, controllerPort)
        XCTAssertTrue(inspector.canListen(host: "127.0.0.1", port: suggestion))
        XCTAssertEqual(conflict.pid, getpid())
        XCTAssertEqual(conflict.processName?.isEmpty, false)
    }

    func testRecentlyClosedControllerConnectionDoesNotBlockRestartProbe() throws {
        let listener = try allocateLocalListener()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(listener.port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let accepted = accept(listener.socket, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        close(listener.socket)

        // The accepted server side closes first, leaving a normal TIME_WAIT
        // tail just like a recently stopped Mihomo controller. Go listeners
        // use SO_REUSEADDR, so Kumo's availability probe must do the same.
        close(accepted)

        XCTAssertTrue(
            LocalPortInspector().canListen(host: "127.0.0.1", port: listener.port),
            "a closed controller with TIME_WAIT sockets must not look like a live port conflict"
        )
    }

    func testSameMixedAndControllerPortProducesTwoDistinctSuggestions() throws {
        let port = try allocateFreeLocalPort()
        let conflicts = LocalPortInspector().conflicts(
            mixedHost: "127.0.0.1",
            mixedPort: port,
            controllerHost: "127.0.0.1",
            controllerPort: port
        )

        XCTAssertEqual(conflicts.map(\.role), [.mixed, .controller])
        XCTAssertEqual(conflicts.count, 2)
        let suggestions = try conflicts.map { try XCTUnwrap($0.suggestedPort) }
        XCTAssertEqual(Set(suggestions).count, 2)
        XCTAssertFalse(suggestions.contains(port))
    }

    func testDefaultStartReportsConflictWithoutChangingStoredPorts() throws {
        let listener = try allocateLocalListener()
        defer { close(listener.socket) }
        let paths = temporaryPaths()
        let controllerPort = try allocateFreeLocalPort()
        let settings = CoreRuntimeSettings(mixedPort: listener.port)
        let stored = CoreStatus(
            endpoint: ControllerEndpoint(port: controllerPort),
            proxyPorts: ProxyPortConfiguration(mixedPort: listener.port),
            runtimeSettings: settings
        )
        try CoreStateStore(paths: paths).save(stored)
        let controller = KumoController(paths: paths, useServiceBackend: false)

        XCTAssertThrowsError(try controller.start(corePath: "/missing/mihomo")) { error in
            guard case KumoError.portConflicts(let conflicts) = error else {
                return XCTFail("Expected structured port conflicts, got \(error)")
            }
            XCTAssertEqual(conflicts.map(\.role), [.mixed])
        }

        XCTAssertEqual(try CoreStateStore(paths: paths).load().proxyPorts.mixedPort, listener.port)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().endpoint.port, controllerPort)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().runtimeSettings, settings)
    }

    func testExplicitResolveUpdatesRuntimeControllerAndSystemProxySettings() throws {
        let mixedListener = try allocateLocalListener()
        defer { close(mixedListener.socket) }
        let controllerListener = try allocateLocalListener()
        defer { close(controllerListener.socket) }
        let paths = temporaryPaths()
        let settings = CoreRuntimeSettings(mixedPort: mixedListener.port)
        let stored = CoreStatus(
            endpoint: ControllerEndpoint(port: controllerListener.port),
            proxyPorts: ProxyPortConfiguration(mixedPort: mixedListener.port),
            runtimeSettings: settings,
            systemProxySettings: SystemProxySettings(port: mixedListener.port)
        )
        try CoreStateStore(paths: paths).save(stored)
        let controller = KumoController(paths: paths, useServiceBackend: false)

        let resolved = try controller.resolvePortConflicts()

        XCTAssertEqual(resolved.map(\.role), [.mixed, .controller])
        let updated = try CoreStateStore(paths: paths).load()
        let mixedSuggestion = try XCTUnwrap(resolved.first { $0.role == .mixed }?.suggestedPort)
        let controllerSuggestion = try XCTUnwrap(resolved.first { $0.role == .controller }?.suggestedPort)
        XCTAssertEqual(updated.proxyPorts.mixedPort, mixedSuggestion)
        XCTAssertEqual(updated.runtimeSettings?.mixedPort, mixedSuggestion)
        XCTAssertEqual(updated.systemProxySettings?.port, mixedSuggestion)
        XCTAssertEqual(updated.endpoint.port, controllerSuggestion)
        XCTAssertNotEqual(mixedSuggestion, controllerSuggestion)
        XCTAssertTrue(LocalPortInspector().canListen(host: "127.0.0.1", port: mixedSuggestion))
        XCTAssertTrue(LocalPortInspector().canListen(host: "127.0.0.1", port: controllerSuggestion))
    }

    func testStartWithExplicitResolutionLaunchesUsingSuggestedPort() throws {
        let listener = try allocateLocalListener()
        defer { close(listener.socket) }
        let paths = temporaryPaths()
        let controllerPort = try allocateFreeLocalPort()
        let settings = CoreRuntimeSettings(mixedPort: listener.port)
        try CoreStateStore(paths: paths).save(CoreStatus(
            endpoint: ControllerEndpoint(port: controllerPort),
            proxyPorts: ProxyPortConfiguration(mixedPort: listener.port),
            runtimeSettings: settings
        ))
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let controller = KumoController(paths: paths, useServiceBackend: false)

        let started = try controller.start(corePath: corePath, resolvePortConflicts: true)
        defer { _ = try? controller.stop() }

        XCTAssertNotEqual(started.proxyPorts.mixedPort, listener.port)
        XCTAssertNotEqual(started.proxyPorts.mixedPort, controllerPort)
        XCTAssertEqual(started.runtimeSettings?.mixedPort, started.proxyPorts.mixedPort)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().proxyPorts.mixedPort, started.proxyPorts.mixedPort)
    }

    private func temporaryPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func makeLongRunningCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        try """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then exit 0; fi
        exec /bin/sleep 600
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
