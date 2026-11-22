import SwiftUI
import UniformTypeIdentifiers
import KumoCoreKit

struct SystemProxyView: View {
    @Environment(KumoAppStore.self) private var store
    @State private var systemProxyDraft = SystemProxySettings()
    @State private var isReclaiming = false

    var body: some View {
        // Normalized once per pass: the Reset and Apply enablements each used to
        // rebuild the normalized draft.
        let draft = normalizedSystemProxyDraft
        return KumoPage(title: "System Proxy") {
            Form {
                Section {
                    LabeledContent(String(localized: "State"), value: ownershipText)
                    if store.status.systemProxyOwnership == .takenOver {
                        Label(String(localized: "Another application changed the system proxy."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button(String(localized: "Reclaim")) {
                            isReclaiming = true
                            Task {
                                await store.reclaimSystemProxy()
                                isReclaiming = false
                            }
                        }
                        .disabled(isReclaiming)
                    } else if store.status.systemProxyOwnership == .cleared {
                        Text(String(localized: "System proxy was cleared outside Kumo."))
                            .foregroundStyle(.secondary)
                    }
                    Toggle(String(localized: "Automatically Reclaim"), isOn: automaticReclaimBinding)
                }

                Section {
                    Toggle(String(localized: "Enable System Proxy"), isOn: Binding {
                        store.status.systemProxyEnabled
                    } set: { isEnabled in
                        store.setSystemProxyEnabled(isEnabled)
                    })
                    TextField("Network Service", text: networkServiceBinding)
                    TextField("Host", text: hostBinding)
                    TextField("Port", value: portBinding, format: .number)
                    Picker(String(localized: "Mode"), selection: modeBinding) {
                        ForEach(SystemProxyMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text(String(localized: "System Proxy updates macOS proxy settings through networksetup. It does not add a VPN configuration; helper installation uses the administrator authorization prompt."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(String(localized: "Reset")) {
                            resetSystemProxyDraft()
                        }
                        .disabled(!hasSystemProxyDraftChanges(in: draft))

                        Button(String(localized: "Apply")) {
                            applySystemProxyDraft(draft)
                        }
                        .disabled(!hasSystemProxyDraftChanges(in: draft))
                    }
                } footer: {
                    Text(String(localized: "Network service, host, port, mode, bypass, and PAC script changes are staged until you apply them."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if systemProxyDraft.mode == .manual {
                    Section(String(localized: "Bypass")) {
                        EditableStringList(
                            items: $systemProxyDraft.bypassList,
                            placeholder: "Domain, host, or CIDR",
                            monospaced: true,
                            accessibilityLabel: "Bypass entries"
                        )
                        Button(String(localized: "Add Defaults")) {
                            mergeBypassDefaults()
                        }
                    }
                }

                if systemProxyDraft.mode == .pac {
                    Section {
                        TextEditor(text: $systemProxyDraft.pacScript)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                    } header: {
                        Text(String(localized: "PAC Script"))
                    } footer: {
                        Text(String(localized: "Kumo serves the PAC script from a local HTTP listener and points macOS at it via networksetup -setautoproxyurl. Enable System Proxy to (re)apply changes."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task {
            resetSystemProxyDraft()
        }
        .onChange(of: systemProxySettings) { oldValue, newValue in
            if systemProxyDraft == oldValue {
                systemProxyDraft = newValue
            }
        }
    }

    private var ownershipText: String {
        switch store.status.systemProxyOwnership {
        case .owned: String(localized: "Owned")
        case .takenOver: String(localized: "Taken Over")
        case .cleared: String(localized: "Cleared")
        case nil: store.status.systemProxyEnabled ? String(localized: "Waiting") : String(localized: "Off")
        }
    }

    private var automaticReclaimBinding: Binding<Bool> {
        Binding {
            store.preferences.reclaimSystemProxy
        } set: { value in
            var preferences = store.preferences
            preferences.reclaimSystemProxy = value
            Task { await store.updatePreferences(preferences) }
        }
    }

    private var systemProxySettings: SystemProxySettings {
        store.status.systemProxySettings ?? SystemProxySettings(
            host: store.status.endpoint.host,
            port: store.status.proxyPorts.mixedPort
        )
    }

    /// Takes the normalized draft for the current body pass.
    private func hasSystemProxyDraftChanges(in draft: SystemProxySettings) -> Bool {
        draft != systemProxySettings
    }

    private var normalizedSystemProxyDraft: SystemProxySettings {
        var settings = systemProxyDraft
        settings.networkService = settings.networkService.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.port = max(1, min(65535, settings.port))
        settings.bypassList = settings.bypassList
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return settings
    }

    private var networkServiceBinding: Binding<String> {
        Binding {
            systemProxyDraft.networkService
        } set: { value in
            systemProxyDraft.networkService = value
        }
    }

    private var hostBinding: Binding<String> {
        Binding {
            systemProxyDraft.host
        } set: { value in
            systemProxyDraft.host = value
        }
    }

    private var portBinding: Binding<Int> {
        Binding {
            systemProxyDraft.port
        } set: { value in
            systemProxyDraft.port = max(1, min(65535, value))
        }
    }

    private var modeBinding: Binding<SystemProxyMode> {
        Binding {
            systemProxyDraft.mode
        } set: { value in
            systemProxyDraft.mode = value
        }
    }

    private func resetSystemProxyDraft() {
        systemProxyDraft = systemProxySettings
    }

    private func mergeBypassDefaults() {
        let merged = Array(Set(systemProxyDraft.bypassList + SystemProxySettings.defaultBypassList)).sorted()
        systemProxyDraft.bypassList = merged
    }

    /// Applies the normalized value the body pass already computed.
    private func applySystemProxyDraft(_ settings: SystemProxySettings) {
        systemProxyDraft = settings
        Task { await store.updateSystemProxySettings(settings) }
    }
}
