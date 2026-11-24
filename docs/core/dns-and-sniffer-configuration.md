# DNS and Sniffer Configuration

## Overview

DNS and Sniffer are independent runtime domains in Kumo, decoupled from TUN as of the DNS/Sniffer parity pass. Each domain has its own settings model, YAML generation path, controller parsing path, and UI view. They are controlled separately: enabling DNS does not require TUN, and enabling Sniffer does not require either.

## Architecture

```
KumoApp (SwiftUI)
  ├── DNSView ──────→ KumoAppStore.setDnsSource() / applyDnsSettings()
  │                      └── KumoController.setDnsSource() / applyDnsSettings()
  │                           ├── stateStore.save()
  │                           └── restart() → RuntimeConfigBuilder
  │
  └── SnifferView ──→ KumoAppStore.applySnifferSettings()
                           └── KumoController.applySnifferSettings()
                                ├── stateStore.save()
                                └── restart() → RuntimeConfigBuilder
```

The key design decision is that **DNS/Sniffer changes restart the core** rather than being PATCHed at runtime. This matches Mihomo's expectation that structural configuration changes are loaded from the generated runtime YAML, not from piecemeal API patches.

## Models

### DnsSettings

Stored in `CoreRuntimeSettings.dns`, persisted as part of `CoreStatus.runtimeSettings`.
`source` selects the owner of Mihomo's top-level `dns` block; it is not emitted
as a field inside that block. Legacy state without `source` decodes as `kumo`.

| Field | Type | Default | YAML Key |
|-------|------|---------|----------|
| `source` | `DnsSource` | `.kumo` | Ownership selector only |
| `isEnabled` | `Bool` | `true` | `dns.enable` |
| `listen` | `String` | `""` | `dns.listen` |
| `ipv6` | `Bool` | `false` | `dns.ipv6` |
| `ipv6Timeout` | `Int` | `100` | `dns.ipv6-timeout` |
| `preferH3` | `Bool` | `false` | `dns.prefer-h3` |
| `enhancedMode` | `String` | `"fake-ip"` | `dns.enhanced-mode` |
| `fakeIPRange` | `String` | `"198.18.0.1/16"` | `dns.fake-ip-range` |
| `fakeIPRange6` | `String` | `""` | `dns.fake-ip-range6` |
| `fakeIPFilter` | `[String]` | `[]` | `dns.fake-ip-filter` |
| `fakeIPFilterMode` | `String` | `""` | `dns.fake-ip-filter-mode` |
| `useHosts` | `Bool` | `false` | `dns.use-hosts` |
| `useSystemHosts` | `Bool` | `false` | `dns.use-system-hosts` |
| `respectRules` | `Bool` | `false` | `dns.respect-rules` |
| `defaultNameserver` | `[String]` | `[]` | `dns.default-nameserver` |
| `nameserver` | `[String]` | `[]` | `dns.nameserver` |
| `fallback` | `[String]` | `[]` | `dns.fallback` |
| `fallbackFilter` | `[String: FallbackFilterValue]` | `[:]` | `dns.fallback-filter` |
| `proxyServerNameserver` | `[String]` | `[]` | `dns.proxy-server-nameserver` |
| `directNameserver` | `[String]` | `[]` | `dns.direct-nameserver` |
| `directNameserverFollowPolicy` | `Bool` | `false` | `dns.direct-nameserver-follow-policy` |
| `nameserverPolicy` | `[String: PolicyValue]` | `[:]` | `dns.nameserver-policy` |
| `proxyServerNameserverPolicy` | `[String: PolicyValue]` | `[:]` | `dns.proxy-server-nameserver-policy` |
| `cacheAlgorithm` | `String` | `""` | `dns.cache-algorithm` |
| `hosts` | `[String: PolicyValue]` | `[:]` | `hosts` (top-level) |

### SnifferSettings

Stored in `CoreRuntimeSettings.sniffer`, persisted as part of `CoreStatus.runtimeSettings`.

| Field | Type | Default | YAML Key |
|-------|------|---------|----------|
| `isEnabled` | `Bool` | `true` | `sniffer.enable` |
| `parsePureIP` | `Bool` | `true` | `sniffer.parse-pure-ip` |
| `forceDNSMapping` | `Bool` | `true` | `sniffer.force-dns-mapping` |
| `overrideDestination` | `Bool` | `false` | `sniffer.override-destination` |
| `httpOverrideDestination` | `Bool` | `false` | `sniffer.sniff.HTTP.override-destination` |
| `httpPorts` | `[Int]` | `[80, 8080]` | `sniffer.sniff.HTTP.ports` |
| `tlsPorts` | `[Int]` | `[443, 8443]` | `sniffer.sniff.TLS.ports` |
| `quicPorts` | `[Int]` | `[]` | `sniffer.sniff.QUIC.ports` |
| `skipDomain` | `[String]` | `[]` | `sniffer.skip-domain` |
| `forceDomain` | `[String]` | `[]` | `sniffer.force-domain` |
| `skipDstAddress` | `[String]` | `["91.108.4.0/22", "91.108.8.0/22", ...]` | `sniffer.skip-dst-address` |
| `skipSrcAddress` | `[String]` | `[]` | `sniffer.skip-src-address` |

## Mixed-Type Policy Values

Mihomo allows several fields to be either a single string or an array of strings. Kumo represents this with `PolicyValue`:

```swift
public enum PolicyValue: Codable, Equatable, Sendable {
    case single(String)
    case multiple([String])
}
```

Fields using `PolicyValue`:
- `DnsSettings.nameserverPolicy`
- `DnsSettings.proxyServerNameserverPolicy`
- `DnsSettings.hosts`

### FallbackFilterValue

`dns.fallback-filter` has a more complex type: `{ [key: string]: boolean | string | string[] }`. Kumo uses a separate enum:

```swift
public enum FallbackFilterValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case single(String)
    case multiple([String])
}
```

This is intentionally separate from `PolicyValue` because the boolean case (`geoip: true`) cannot be represented by `PolicyValue`, and mixing the two would create an overly broad type.

## YAML Generation

### Controlled Keys and DNS Ownership

`RuntimeConfigBuilder` maintains a set of controlled top-level keys that are
stripped from the merged profile and replaced with Kumo-managed values. DNS
ownership depends on both the selected source and the existing enable flag:

- `kumo` source with DNS enabled: strip `dns` and emit the complete normalized
  Kumo mapping. With Kumo DNS disabled, retain the existing behavior of leaving
  the merged profile's `dns` block untouched and emitting no Kumo DNS block.
- Effective `profile` source: leave `dns` uncontrolled and preserve the merged
  profile mapping verbatim after active overrides. Do not decode and rebuild it
  through `DnsSettings`.
- Requested `profile` source with no merged `dns` declaration: retain the
  stored source selection but resolve ownership to Kumo as a runtime fallback.
  The GUI labels this fallback and leaves the Kumo fields editable.

`currentProfileDeclaresDNS()` examines the profile after active overrides, so
both the builder and GUI use the same ownership decision. Other dynamic keys
remain independent: `tun` and `sniffer` follow their own settings, and `hosts`
is controlled whenever Kumo hosts are non-empty in either DNS source mode.

### Hosts Top-Level Emission

`hosts` is special: it is stored inside `DnsSettings` for UI convenience, but emitted as a top-level YAML block because Mihomo expects `hosts` at the root level of the config:

```yaml
# Kumo controlled hosts
hosts:
  localhost: "127.0.0.1"
  example.com: "1.2.3.4"
```

The `hosts` key is added to the controlled keys only when the user has configured Kumo hosts, regardless of the DNS source. If Kumo hosts are empty, profile-provided `hosts` entries are preserved. This avoids silently dropping user data and keeps hosts orthogonal to profile-owned DNS.

### Empty Value Omission

Most fields are omitted from YAML when empty/default:
- Empty strings (`listen`, `fakeIPRange6`, `fakeIPFilterMode`, `cacheAlgorithm`)
- Empty arrays (`fakeIPFilter`, `defaultNameserver`, `nameserver`, etc.)
- Empty dictionaries (`fallbackFilter`, `nameserverPolicy`, `hosts`)

Exceptions (always emitted):
- `dns.enable`, `dns.ipv6`, `dns.use-hosts`, `dns.use-system-hosts`, `dns.respect-rules`
- `sniffer.enable`, `sniffer.parse-pure-ip`, `sniffer.force-dns-mapping`, `sniffer.override-destination`

## Controller Parsing

### From Mihomo /configs

`MihomoControllerClient.configuration()` fetches the full config and parses it into `CoreConfigurationSnapshot`.

**Hosts parsing**: Because `hosts` is a top-level key in Mihomo's config but stored in `DnsSettings` in Kumo, the parser reads `hosts` from the top-level object and merges it into the parsed `DnsSettings`:

```swift
let topLevelHosts = policyValueDict(from: object["hosts"])
var parsedDNS = dnsSettings(from: dns)  // parses from object["dns"]
if parsedDNS == nil, !topLevelHosts.isEmpty {
    parsedDNS = DnsSettings(isEnabled: false)
}
parsedDNS?.hosts = topLevelHosts
```

This handles the edge case where Mihomo has `hosts` configured but no `dns` block.

### PolicyValue Parsing

`policyValueDict(from:)` handles the mixed-type values:
- If the value is a `String`, wraps it in `.single`
- If the value is an array of strings, wraps it in `.multiple`
- Otherwise, ignores the entry

### FallbackFilterValue Parsing

`fallbackFilterDict(from:)` uses heuristic parsing:
- `Bool` → `.bool`
- `String` → `.single`
- `[String]` → `.multiple`
- Other types are ignored

## Runtime Patch (Live Core)

`updateRuntimeSettings()` can PATCH scalar runtime settings to `/configs`. Its
existing payload includes Kumo-owned DNS when Kumo DNS is enabled, but omits
`dns` whenever the stored source is `profile`, preventing unrelated scalar
changes from replacing profile DNS. Applying DNS structure or source changes
uses generated YAML and a core restart instead. Hosts remain a separate
top-level concern, not a nested `dns` field; applying hosts-only changes while
profile DNS is effective preserves the profile's DNS mapping.

## UI Patterns

### DNS Source and Fallback

`DNSView` binds its native source picker to the stored `DnsSettings.source` and
calls `KumoAppStore.setDnsSource()` only for an actual change. The store refreshes
status, profile declaration state, and the running core configuration after a
successful switch; picker selection is not an independent optimistic state that
could trigger binding loops or duplicate restarts.

When Kumo DNS is selected but the current profile declares DNS, the view offers
**Use DNS from profile**. When profile DNS is effective, Kumo DNS fields and the
enable toggle are replaced by `Provided by the current profile.` so stored Kumo
values are not mistaken for live profile values. Hosts remain editable and their
Reset/Apply controls compare and submit only hosts changes. When the requested
profile has no DNS declaration, the view reports `Profile DNS is unavailable.
Kumo DNS is in effect.` and keeps the Kumo fields editable.

### Staged Draft with Reset/Apply

Kumo-owned `DNSView` fields and `SnifferView` follow the pattern established by
`TunView`:

1. On appear: copy current settings into local `@State` draft
2. User edits draft (not committed to store)
3. "Reset" button restores draft from store
4. "Apply" button validates, normalizes, and commits to store
5. Store calls `controller.applyDnsSettings()` which saves state and restarts core

A DNS source change replaces the draft with the newly stored settings, avoiding
stale values from the previous ownership mode. Profile-mode hosts apply starts
from the stored Kumo settings and changes only `hosts`. This prevents
partial/inconsistent states from reaching the running core.

### Validation

`DNSValidator` provides validation helpers:
- `isValidListenAddress(_:)` — checks `host:port` format
- `isValidFakeIPFilterMode(_:)` — checks `whitelist` or `blacklist`
- `isValidCacheAlgorithm(_:)` — checks `lru` or `arc`

Validation runs on Apply, not on every keystroke.

## Files by Responsibility

| File | Responsibility |
|------|---------------|
| `Models/Models.swift` | `DnsSource`, `DnsSettings`, `SnifferSettings`, `PolicyValue`, `FallbackFilterValue` definitions and legacy source decoding |
| `Configuration/RuntimeConfigBuilder.swift` | YAML generation for `dns`, `sniffer`, and `hosts` blocks |
| `Networking/MihomoControllerClient.swift` | Parsing `dns` and `hosts` from controller responses |
| `KumoCoreKit.swift` | `dnsPatch(for:)`, `snifferPatch(for:)`, `normalizedDnsSettings()`, `normalizedSnifferSettings()` |
| `Support/DNSValidator.swift` | Validation helpers for DNS fields |
| `Views/ConfigureViews/` | `DNSView.swift`, `SnifferView.swift`, and shared UI components |
| `Stores/KumoAppStore.swift` | `setDnsSource()`, `currentProfileDeclaresDNS`, `applyDnsSettings()`, `applySnifferSettings()`, `setDnsEnabled()`, `setSnifferEnabled()` |

## Future Work

- Extract DNS/Sniffer logic from `KumoCoreKit.swift` into dedicated domain coordinators.
- Add structured tests for `PolicyValue` and `FallbackFilterValue` Codable round-trips.
- Consider moving `hosts` out of `DnsSettings` into a standalone model if the semantic coupling becomes confusing.
