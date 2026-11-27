import AppIntents
import Foundation
import KumoCoreKit

/// AppIntents metadata extractor cannot see enum cases declared in another
/// SPM module, so we redeclare `OutboundMode` locally as `KumoModeChoice`
/// and bridge to/from `KumoCoreKit.OutboundMode` when running an intent.
enum KumoModeChoice: String, AppEnum {
    case rule
    case global
    case direct

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Outbound Mode"
    static let caseDisplayRepresentations: [KumoModeChoice: DisplayRepresentation] = [
        .rule: DisplayRepresentation(title: "Rule"),
        .global: DisplayRepresentation(title: "Global"),
        .direct: DisplayRepresentation(title: "Direct")
    ]

    var coreMode: OutboundMode {
        switch self {
        case .rule: .rule
        case .global: .global
        case .direct: .direct
        }
    }
}

/// Resolves the live store while the GUI is running, or a tier-routed
/// controller for headless intent execution. The controller factory is an
/// internal test seam so intents can use hermetic application-support paths.
enum IntentResolver {
    @MainActor
    static var controllerFactory: @Sendable () -> KumoController = { KumoController() }

    @MainActor
    static func store() -> KumoAppStore? {
        KumoAppContext.shared.store
    }

    @MainActor
    static func controller() -> KumoController {
        controllerFactory()
    }
}

struct StartKumoIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Kumo"
    static let description = IntentDescription("Start the Mihomo core managed by Kumo.")

    func perform() async throws -> some IntentResult {
        if let store = await MainActor.run(body: IntentResolver.store) {
            await store.startCore()
        } else {
            let controller = await MainActor.run(body: IntentResolver.controller)
            _ = try controller.start()
        }
        return .result()
    }
}

struct StopKumoIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Kumo"
    static let description = IntentDescription("Stop the running Mihomo core.")

    func perform() async throws -> some IntentResult {
        if let store = await MainActor.run(body: IntentResolver.store) {
            await store.stopCore()
        } else {
            let controller = await MainActor.run(body: IntentResolver.controller)
            _ = try controller.stop()
        }
        return .result()
    }
}

struct SetKumoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Kumo Mode"
    static let description = IntentDescription("Switch outbound rule between Rule, Global, and Direct.")

    @Parameter(title: "Mode")
    var mode: KumoModeChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coreMode = mode.coreMode
        if let store = await MainActor.run(body: IntentResolver.store) {
            await store.setMode(coreMode)
        } else {
            let controller = await MainActor.run(body: IntentResolver.controller)
            try await controller.setMode(coreMode)
        }
        let displayName = coreMode.displayName
        return .result(dialog: IntentDialog("Switched Kumo mode to \(displayName)."))
    }
}

struct ToggleSystemProxyIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Kumo System Proxy"
    static let description = IntentDescription("Enable or disable macOS system proxy via Kumo.")

    @Parameter(title: "Enable")
    var enable: Bool

    func perform() async throws -> some IntentResult {
        if let store = await MainActor.run(body: IntentResolver.store) {
            await MainActor.run { store.setSystemProxyEnabled(enable) }
        } else {
            let controller = await MainActor.run(body: IntentResolver.controller)
            _ = try await controller.setSystemProxy(enable)
        }
        return .result()
    }
}

struct RefreshKumoIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Kumo"
    static let description = IntentDescription("Reload Kumo status, profiles, proxies, and inspect data.")

    func perform() async throws -> some IntentResult {
        if let store = await MainActor.run(body: IntentResolver.store) {
            await store.refreshAll()
        } else {
            let controller = await MainActor.run(body: IntentResolver.controller)
            _ = try controller.status()
        }
        return .result()
    }
}
