import Foundation

extension KumoController {
    /// Builds the graph from the same generated configuration used at launch.
    /// A running core contributes its actual mode and group selections; a
    /// stopped core deliberately has no synthetic active selections.
    public func topology() async throws -> TopologyGraph {
        let status = try status()
        let profile = try profileRepository.loadDefaultProfile()
        let overrides = try overrideRepository.activeOverrides()
        let configuration = try RuntimeConfigBuilder(
            endpoint: status.endpoint,
            proxyPorts: status.proxyPorts,
            mode: status.mode,
            runtimeSettings: runtimeSettings(for: status)
        ).build(profile: profile, overrides: overrides)

        guard status.state == .running else {
            return try TopologyBuilder.build(yaml: configuration.yaml, mode: status.mode)
        }

        let client = MihomoControllerClient(endpoint: status.endpoint)
        async let actualMode = client.currentMode()
        async let selections = client.proxySelections()
        let (mode, activeSelections) = try await (actualMode, selections)
        return try TopologyBuilder.build(
            yaml: configuration.yaml,
            mode: mode,
            selections: activeSelections
        )
    }
}
