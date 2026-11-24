# ADR-006: DNS Configuration Ownership

## Status

Accepted

Amends [ADR-001: DNS and Sniffer Decoupled from TUN](ADR-001-dns-sniffer-decoupling.md).

## Context

ADR-001 made DNS independent of TUN, but the runtime builder always treated the
top-level `dns` block as Kumo-owned whenever Kumo DNS was enabled. Users who
already maintained DNS in a profile had to translate that configuration into
`DnsSettings`, and a rich profile mapping could be normalized or reconstructed
through a model that was never intended to represent arbitrary profile YAML.

The application needs two explicit ownership modes without changing the default
for existing users. It also needs to distinguish a profile that simply has no
DNS declaration from an explicit source change or restart that failed.

## Decision

Add `DnsSettings.source` with `kumo` and `profile` cases. The selector controls
only ownership of the top-level `dns` block.

1. **Kumo remains the default.** Legacy persisted state without `source`
   decodes as `kumo`. In this mode, and when Kumo DNS is enabled, the builder
   strips the merged profile's `dns` block and emits the complete normalized
   Kumo mapping. Disabled Kumo DNS preserves the profile block as before.
2. **Profile DNS passes through verbatim.** With effective `profile` ownership,
   the builder preserves the current profile's `dns` mapping after active
   overrides have been applied. It does not parse, normalize, or reconstruct
   the mapping through `DnsSettings`.
3. **Declaration checks use the merged profile.**
   `KumoController.currentProfileDeclaresDNS()` accounts for active overrides,
   and the GUI observes the same result when refreshing profiles.
4. **Missing DNS has a bounded runtime fallback.** If the stored source is
   `profile` but the merged profile has no `dns` declaration, ownership resolves
   to Kumo for the generated runtime while the stored selection remains
   `profile`. The GUI reports the fallback and keeps Kumo fields editable. This
   is not reported as a successful profile takeover.
5. **Explicit failures stay failures.** `setDnsSource(_:)` persists a requested
   source change and restarts a running core through the shared controller.
   Validation, persistence, or restart errors are returned to the GUI and CLI;
   they are not converted into the missing-declaration fallback.
   `applyDnsSettings(_:)` routes a source-only change through `setDnsSource`.
6. **DNS source changes do not use runtime PATCH.** Kumo DNS structure and
   source transitions are loaded from generated YAML. Scalar runtime PATCH
   generation retains the existing Kumo-owned DNS payload when Kumo DNS is
   enabled, but omits `dns` whenever the stored source is `profile`.
7. **Hosts remain orthogonal.** `DnsSettings.hosts` retains its existing storage
   location and top-level YAML emission in both source modes. Non-empty Kumo
   hosts replace profile hosts; empty Kumo hosts preserve them. Profile DNS mode
   keeps the hosts editor active and permits hosts-only applies.
8. **GUI and CLI share the facade.** The GUI source picker and the CLI source
   command call `KumoController` rather than maintaining separate ownership or
   fallback logic. The GUI does not display saved Kumo DNS values as if they
   were live profile values.

## Consequences

### Positive

- Existing installations keep their Kumo-managed DNS behavior by default.
- Arbitrary profile DNS mappings survive without model-driven loss or reordering.
- Active overrides participate in one consistent ownership decision.
- Users can identify and edit the Kumo fallback instead of being locked out by a
  missing profile declaration.
- Hosts workflows remain available regardless of DNS ownership.

### Negative

- Stored source and effective runtime ownership can differ during fallback, so
  status presentation must distinguish requested from effective behavior.
- Source changes restart a running core and briefly interrupt traffic.
- `DnsSettings` continues to contain hosts for persistence and UI convenience,
  even though hosts are not owned by the DNS source selector.

## Alternatives Considered

### Always Kumo-owned DNS

Rejected because it prevents users from keeping their existing profile DNS and
requires lossy translation into Kumo's settings model.

### Profile-only DNS

Rejected as the default because it changes existing behavior and leaves users
without profile DNS no managed fallback.

### PATCH source changes into the running core

Rejected for the same structural-determinism reasons as ADR-004. Generated YAML
plus restart keeps source, profile, and override handling in one build path.

## Related

- `docs/core/dns-and-sniffer-configuration.md`
- `docs/core/mihomo-runtime-controller.md`
- `docs/interfaces/cli-agent-control.md`
- `docs/decisions/ADR-003-hosts-top-level-vs-nested.md`
- `docs/decisions/ADR-004-restart-vs-patch-for-dns-sniffer.md`
