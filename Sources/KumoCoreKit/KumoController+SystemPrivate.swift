import Foundation
import os

extension KumoController {
    func formatDiagnostic(stage: String, error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let line = "\(stage): \(message)"
        return line
    }

    func fallbackSystemProxyConfiguration(for status: CoreStatus) -> SystemProxyConfiguration {
        let stored = status.systemProxySettings?.networkService
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedService: String
        if let stored, !stored.isEmpty, stored != "Automatic" {
            resolvedService = stored
        } else if let active = try? systemProxyController.activeNetworkService(),
                  !active.isEmpty {
            resolvedService = active
        } else {
            resolvedService = "Wi-Fi"
        }
        return SystemProxyConfiguration(networkService: resolvedService)
    }

    func logLevel(in message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("error") { return "error" }
        if lowercased.contains("warn") { return "warning" }
        if lowercased.contains("debug") { return "debug" }
        return "info"
    }

    func recentTunPermissionError() -> String? {
        guard let logs = try? recentLogs(limit: 80) else {
            return nil
        }
        let permissionError = "Start TUN listening error: configure tun interface: operation not permitted"
        return logs.last(where: { $0.message.contains(permissionError) }).map { _ in
            "TUN could not create the macOS network interface. Install or repair the privileged helper, then enable TUN again."
        }
    }

    func runtimeSettings(for status: CoreStatus) -> CoreRuntimeSettings {
        var settings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
        settings.mixedPort = status.proxyPorts.mixedPort
        return settings
    }

    func normalizedStatusForLaunch() throws -> CoreStatus {
        var status = try stateStore.load()
        let service = currentServiceStatus()
        status.serviceModeStatus = service
        if var runtimeSettings = status.runtimeSettings,
           var tun = runtimeSettings.tun,
           tun.isEnabled,
           !service.canManageTun {
            tun.isEnabled = false
            runtimeSettings.tun = tun
            status.runtimeSettings = runtimeSettings
            status.tunStatus = TunStatus(
                isEnabled: false,
                isRunning: false,
                requiresService: true,
                lastError: service.message
            )
            try stateStore.save(status)
        }
        return status
    }

    func effectiveSystemProxySettings(for status: CoreStatus) throws -> SystemProxySettings {
        let runtimePort = runtimeSettings(for: status).mixedPort
        var settings = status.systemProxySettings ?? SystemProxySettings(
            networkService: (try? systemProxyController.activeNetworkService()) ?? "Wi-Fi",
            host: status.endpoint.host,
            port: runtimePort
        )
        if settings.networkService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.networkService == "Automatic" {
            settings.networkService = try systemProxyController.activeNetworkService()
        }
        settings.port = runtimePort
        return settings
    }

    func persistServiceStatus(_ serviceStatus: ServiceModeStatus) {
        do {
            var status = try stateStore.load()
            status.serviceModeStatus = serviceStatus
            try stateStore.save(status)
        } catch {
            // Status refresh should not fail user-facing operations.
        }
    }

    /// The signed root-daemon client, when the service backend is enabled.
    /// Reachability is decided by `BackendRouter`, not by this factory.
    func rootServiceClient() -> KumoServiceClient? {
        guard useServiceBackend else {
            return nil
        }
        return serviceManager.serviceClient()
    }

    /// The signed user-agent client, when the service backend is enabled.
    func userAgentClient() -> KumoServiceClient? {
        guard useServiceBackend else {
            return nil
        }
        return userAgentManager.client()
    }

    /// The root-daemon client for privileged operations (system proxy, TUN):
    /// only when the router selects the root tier for them.
    func privilegedServiceClient() -> KumoServiceClient? {
        guard router.privilegedBackend() == .rootService else {
            return nil
        }
        return rootServiceClient()
    }

    /// TUN state consulted by the router for every operation.
    func currentTunEnabled() -> Bool {
        (try? stateStore.load().runtimeSettings?.tun?.isEnabled) ?? false
    }

    /// Service-mode status with the test seam applied, so routing tests can
    /// simulate a reachable privileged tier without installing the helper.
    func currentServiceStatus() -> ServiceModeStatus {
        serviceModeStatusProvider?() ?? serviceManager.status()
    }
}
