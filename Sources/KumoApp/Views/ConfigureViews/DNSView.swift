import SwiftUI
import UniformTypeIdentifiers
import KumoCoreKit

struct DNSView: View {
    @Environment(KumoAppStore.self) private var store
    let onNavigate: (SidebarDestination) -> Void
    @State private var dnsDraft = DnsSettings()

    var body: some View {
        // Normalized once per pass: the validation text and both button
        // enablements each used to rebuild the whole normalized draft.
        let draft = normalizedDnsDraft
        return KumoPage(title: "DNS") {
            Form {
                Section(String(localized: "Status")) {
                    Toggle(String(localized: "Enable DNS"), isOn: Binding {
                        currentDnsSettings.isEnabled
                    } set: { isEnabled in
                        Task { await store.setDnsEnabled(isEnabled) }
                    })
                    .disabled(store.isLoading)
                }

                Section(String(localized: "Mode")) {
                    Picker(String(localized: "Enhanced Mode"), selection: $dnsDraft.enhancedMode) {
                        Text(String(localized: "Fake IP")).tag("fake-ip")
                        Text(String(localized: "Redir Host")).tag("redir-host")
                        Text(String(localized: "Normal")).tag("normal")
                    }
                    .pickerStyle(.segmented)
                    Toggle(String(localized: "IPv6"), isOn: $dnsDraft.ipv6)
                    Toggle(String(localized: "Use Hosts"), isOn: $dnsDraft.useHosts)
                    Toggle(String(localized: "Use System Hosts"), isOn: $dnsDraft.useSystemHosts)
                    Toggle(String(localized: "Respect Rules"), isOn: $dnsDraft.respectRules)
                }

                Section(String(localized: "Advanced")) {
                    TextField("Listen", text: $dnsDraft.listen)
                    TextField("IPv6 Timeout", value: $dnsDraft.ipv6Timeout, format: .number)
                    Toggle(String(localized: "Prefer HTTP/3"), isOn: $dnsDraft.preferH3)
                    Picker(String(localized: "Fake IP Filter Mode"), selection: $dnsDraft.fakeIPFilterMode) {
                        Text(String(localized: "None")).tag("")
                        Text(String(localized: "Blacklist")).tag("blacklist")
                        Text(String(localized: "Whitelist")).tag("whitelist")
                    }
                    .pickerStyle(.segmented)
                    Toggle(String(localized: "Direct Nameserver Follow Policy"), isOn: $dnsDraft.directNameserverFollowPolicy)
                    Picker(String(localized: "Cache Algorithm"), selection: $dnsDraft.cacheAlgorithm) {
                        Text(String(localized: "None")).tag("")
                        Text(String(localized: "LRU")).tag("lru")
                        Text(String(localized: "ARC")).tag("arc")
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "Fake IP Range")) {
                    TextField("Fake IP Range", text: $dnsDraft.fakeIPRange)
                    TextField("Fake IP Range IPv6", text: $dnsDraft.fakeIPRange6)
                }

                Section(String(localized: "Fake IP Filter")) {
                    EditableStringList(
                        items: $dnsDraft.fakeIPFilter,
                        placeholder: "+.example.com",
                        monospaced: true,
                        accessibilityLabel: "Fake IP filter"
                    )
                }

                Section(String(localized: "Default Nameserver")) {
                    EditableStringList(
                        items: $dnsDraft.defaultNameserver,
                        placeholder: "tls://223.5.5.5",
                        monospaced: true,
                        accessibilityLabel: "Default nameserver"
                    )
                }

                Section(String(localized: "Nameserver")) {
                    EditableStringList(
                        items: $dnsDraft.nameserver,
                        placeholder: "https://doh.pub/dns-query",
                        monospaced: true,
                        accessibilityLabel: "Nameserver"
                    )
                }

                Section(String(localized: "Proxy Server Nameserver")) {
                    EditableStringList(
                        items: $dnsDraft.proxyServerNameserver,
                        placeholder: "https://1.1.1.1/dns-query",
                        monospaced: true,
                        accessibilityLabel: "Proxy server nameserver"
                    )
                }

                Section(String(localized: "Direct Nameserver")) {
                    EditableStringList(
                        items: $dnsDraft.directNameserver,
                        placeholder: "tls://223.5.5.5",
                        monospaced: true,
                        accessibilityLabel: "Direct nameserver"
                    )
                }

                Section(String(localized: "Fallback")) {
                    EditableStringList(
                        items: $dnsDraft.fallback,
                        placeholder: "https://1.1.1.1/dns-query",
                        monospaced: true,
                        accessibilityLabel: "Fallback nameserver"
                    )
                }

                Section(String(localized: "Fallback Filter")) {
                    FallbackFilterDictEditor(
                        entries: $dnsDraft.fallbackFilter,
                        accessibilityLabel: "Fallback filter"
                    )
                }

                Section(String(localized: "Nameserver Policy")) {
                    PolicyDictEditor(
                        entries: $dnsDraft.nameserverPolicy,
                        accessibilityLabel: "Nameserver policy"
                    )
                }

                Section(String(localized: "Proxy Server Nameserver Policy")) {
                    PolicyDictEditor(
                        entries: $dnsDraft.proxyServerNameserverPolicy,
                        accessibilityLabel: "Proxy server nameserver policy"
                    )
                }

                Section(String(localized: "Hosts")) {
                    PolicyDictEditor(
                        entries: $dnsDraft.hosts,
                        accessibilityLabel: "Hosts"
                    )
                }

                Section {
                    if let validationMessage = dnsDraftValidationMessage(for: draft) {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(String(localized: "Reset")) {
                            updateDnsDraft(currentDnsSettings)
                        }
                        .disabled(!hasDnsDraftChanges(in: draft) || store.isLoading)

                        Button(String(localized: "Apply")) {
                            applyDnsDraft(draft)
                        }
                        .disabled(!canApplyDnsDraft(for: draft))
                    }
                } footer: {
                    Text(String(localized: "DNS changes are staged locally. Apply restarts the core when it is running."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task {
            updateDnsDraft(currentDnsSettings)
        }
        .onChange(of: currentDnsSettings) { _, newValue in
            if !hasDnsDraftChanges(in: normalizedDnsDraft) {
                updateDnsDraft(newValue)
            } else {
                dnsDraft.isEnabled = newValue.isEnabled
            }
        }
    }

    private var currentDnsSettings: DnsSettings {
        store.status.runtimeSettings?.dns ?? DnsSettings()
    }

    /// Takes the normalized draft for the current body pass; normalizing here
    /// again is what the body pass already paid for.
    private func hasDnsDraftChanges(in draft: DnsSettings) -> Bool {
        draft != currentDnsSettings
    }

    private func canApplyDnsDraft(for draft: DnsSettings) -> Bool {
        hasDnsDraftChanges(in: draft) && dnsDraftValidationMessage(for: draft) == nil && !store.isLoading
    }

    private var normalizedDnsDraft: DnsSettings {
        var settings = dnsDraft
        settings.enhancedMode = ["fake-ip", "redir-host", "normal"].contains(settings.enhancedMode)
            ? settings.enhancedMode
            : "fake-ip"
        settings.listen = settings.listen.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.fakeIPRange = settings.fakeIPRange.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.fakeIPRange6 = settings.fakeIPRange6.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.fakeIPFilter = Self.normalizedList(settings.fakeIPFilter)
        settings.fakeIPFilterMode = settings.fakeIPFilterMode.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.defaultNameserver = Self.normalizedList(settings.defaultNameserver)
        settings.nameserver = Self.normalizedList(settings.nameserver)
        settings.fallback = Self.normalizedList(settings.fallback)
        settings.proxyServerNameserver = Self.normalizedList(settings.proxyServerNameserver)
        settings.directNameserver = Self.normalizedList(settings.directNameserver)
        settings.fallbackFilter = settings.fallbackFilter.mapValues { value in
            switch value {
            case .bool(let b):
                return .bool(b)
            case .single(let s):
                return .single(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .multiple(let arr):
                return .multiple(Self.normalizedList(arr))
            }
        }
        settings.nameserverPolicy = settings.nameserverPolicy.mapValues { value in
            switch value {
            case .single(let s):
                return .single(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .multiple(let arr):
                return .multiple(Self.normalizedList(arr))
            }
        }
        settings.proxyServerNameserverPolicy = settings.proxyServerNameserverPolicy.mapValues { value in
            switch value {
            case .single(let s):
                return .single(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .multiple(let arr):
                return .multiple(Self.normalizedList(arr))
            }
        }
        settings.hosts = settings.hosts.mapValues { value in
            switch value {
            case .single(let s):
                return .single(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .multiple(let arr):
                return .multiple(Self.normalizedList(arr))
            }
        }
        settings.cacheAlgorithm = settings.cacheAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings
    }

    private func dnsDraftValidationMessage(for settings: DnsSettings) -> String? {
        if settings.isEnabled {
            if settings.nameserver.isEmpty {
                return "Nameserver needs at least one value when DNS is enabled."
            }
            if settings.enhancedMode == "fake-ip", !Self.isCIDR(settings.fakeIPRange) {
                return "Fake IP Range must use CIDR notation."
            }
        }
        if !settings.listen.isEmpty, !DNSValidator.isValidListenAddress(settings.listen) {
            return "Listen address format is invalid. Use :port or host:port."
        }
        if !DNSValidator.isValidFakeIPFilterMode(settings.fakeIPFilterMode) {
            return "Fake IP Filter Mode must be blacklist or whitelist."
        }
        if !DNSValidator.isValidCacheAlgorithm(settings.cacheAlgorithm) {
            return "Cache Algorithm must be lru or arc."
        }
        return nil
    }

    /// Applies the normalized value the body pass already computed, so the
    /// staged draft and the runtime keep receiving the same normalized settings.
    private func applyDnsDraft(_ settings: DnsSettings) {
        updateDnsDraft(settings)
        Task { await store.applyDnsSettings(settings) }
    }

    private func updateDnsDraft(_ settings: DnsSettings) {
        dnsDraft = settings
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let prefix = Int(parts[1]) else {
            return false
        }

        if parts[0].contains(":") {
            return (0...128).contains(prefix)
        }

        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, (0...32).contains(prefix) else {
            return false
        }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }
}
