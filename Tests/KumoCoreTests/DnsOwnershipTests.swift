import Foundation
import XCTest
@testable import KumoCoreKit

final class DnsOwnershipTests: XCTestCase {
    func testKumoDNSGoldenYAML() throws {
        let profile = Profile(
            name: "Golden",
            source: .inline,
            rawYAML: """
            proxies: []
            rules:
              - MATCH,DIRECT
            dns:
              enable: false
              profile-only: discarded
            """
        )
        let settings = CoreRuntimeSettings(
            mixedPort: 17890,
            dns: DnsSettings(
                isEnabled: true,
                listen: "127.0.0.1:5353",
                fakeIPRange6: "",
                fakeIPFilter: [],
                defaultNameserver: ["223.5.5.5"],
                nameserver: ["https://dns.example/dns-query"]
            )
        )
        let builder = RuntimeConfigBuilder(
            endpoint: ControllerEndpoint(port: 19097, secret: "secret"),
            proxyPorts: ProxyPortConfiguration(mixedPort: 17890),
            mode: .global,
            runtimeSettings: settings
        )

        let runtime = try builder.build(profile: profile)

        XCTAssertEqual(runtime.yaml, """
        proxies: []
        rules:
        - MATCH,DIRECT

        # Kumo controlled runtime settings
        external-controller: 127.0.0.1:19097
        secret: "secret"
        mixed-port: 17890
        mode: global
        allow-lan: false
        log-level: info
        ipv6: false
        find-process-mode: always
        geodata-mode: false
        geo-auto-update: false
        geo-update-interval: 24
        geox-url:
          geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
          geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
          mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
          asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

        # Kumo controlled DNS settings
        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          listen: "127.0.0.1:5353"
          ipv6-timeout: 100
          prefer-h3: false
          fake-ip-filter-mode: blacklist
          use-hosts: false
          use-system-hosts: false
          respect-rules: false
          default-nameserver:
            - 223.5.5.5
          nameserver:
            - "https://dns.example/dns-query"
          direct-nameserver-follow-policy: false
        """)
        XCTAssertEqual(runtime.warnings, [])
    }

    func testProfileDNSPreservesCompleteMappingWithoutControlledDNS() throws {
        let profile = Profile(
            name: "Profile DNS",
            source: .inline,
            rawYAML: """
            dns:
              enable: true
              nameserver:
                - https://profile.example/dns-query
              unmodeled-scalar: preserved
              unmodeled-mapping:
                nested: also-preserved
            rules:
              - MATCH,DIRECT
            """
        )
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(
                nameserver: ["https://kumo.example/dns-query"],
                source: .profile
            )
        )

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("dns:"))
        XCTAssertTrue(runtime.yaml.contains("enable: true"))
        XCTAssertTrue(runtime.yaml.contains("https://profile.example/dns-query"))
        XCTAssertTrue(runtime.yaml.contains("unmodeled-scalar: preserved"))
        XCTAssertTrue(runtime.yaml.contains("unmodeled-mapping:"))
        XCTAssertTrue(runtime.yaml.contains("nested: also-preserved"))
        XCTAssertFalse(runtime.yaml.contains("https://kumo.example/dns-query"))
        XCTAssertFalse(runtime.yaml.contains("# Kumo controlled DNS settings"))
        XCTAssertEqual(runtime.yaml.components(separatedBy: "dns:").count - 1, 1)
        XCTAssertEqual(runtime.warnings, [])
    }

    func testProfileDNSMissingFallsBackToKumoWithWarning() throws {
        let profile = Profile(name: "No DNS", source: .inline, rawYAML: "rules:\n  - MATCH,DIRECT\n")
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(
                nameserver: ["https://kumo.example/dns-query"],
                source: .profile
            )
        )

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("# Kumo controlled DNS settings"))
        XCTAssertTrue(runtime.yaml.contains("https://kumo.example/dns-query"))
        XCTAssertEqual(runtime.warnings.count, 1)
        XCTAssertTrue(runtime.warnings[0].contains("no dns mapping"))
        XCTAssertTrue(runtime.warnings[0].contains("Kumo DNS settings"))
    }

    func testProfileDNSDisabledWithTUNPassesThroughAndWarns() throws {
        let profile = Profile(
            name: "Disabled DNS",
            source: .inline,
            rawYAML: """
            dns:
              enable: false
              unmodeled: preserved
            """
        )
        let settings = CoreRuntimeSettings(
            tun: TunSettings(isEnabled: true),
            dns: DnsSettings(source: .profile)
        )

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("dns:\n  enable: false"))
        XCTAssertTrue(runtime.yaml.contains("unmodeled: preserved"))
        XCTAssertTrue(runtime.yaml.contains("# Kumo controlled TUN settings"))
        XCTAssertFalse(runtime.yaml.contains("# Kumo controlled DNS settings"))
        XCTAssertEqual(runtime.warnings.count, 1)
        XCTAssertTrue(runtime.warnings[0].contains("Profile DNS is disabled"))
        XCTAssertTrue(runtime.warnings[0].contains("TUN"))
    }

    func testLegacyDnsSettingsDecodeDefaultsOnlySource() throws {
        let original = DnsSettings(nameserver: ["https://dns.example/dns-query"])
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "source")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DnsSettings.self, from: legacyData)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.source, .kumo)

        object.removeValue(forKey: "nameserver")
        let missingExistingField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DnsSettings.self, from: missingExistingField))
    }

    func testKumoDNSDisabledPreservesProfileDNS() throws {
        let profile = Profile(
            name: "Disabled Kumo DNS",
            source: .inline,
            rawYAML: "dns:\n  enable: true\n  unmodeled: preserved\n"
        )
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(isEnabled: false, source: .kumo)
        )

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("dns:\n  enable: true"))
        XCTAssertTrue(runtime.yaml.contains("unmodeled: preserved"))
        XCTAssertFalse(runtime.yaml.contains("# Kumo controlled DNS settings"))
    }

    func testRuntimePatchProfileOmitsDNSButKeepsHosts() {
        let controller = makeController(paths: makePaths())
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(
                isEnabled: true,
                hosts: ["example.com": .single("192.0.2.1")],
                source: .profile
            )
        )

        let patch = controller.runtimePatch(for: settings)

        XCTAssertNil(patch["dns"])
        XCTAssertNotNil(patch["hosts"])
    }

    func testRuntimePatchKumoEnabledRetainsDNS() {
        let controller = makeController(paths: makePaths())
        let settings = CoreRuntimeSettings(
            dns: DnsSettings(isEnabled: true, source: .kumo)
        )

        let patch = controller.runtimePatch(for: settings)

        XCTAssertNotNil(patch["dns"])
    }

    func testCurrentProfileDeclaresDNSUsesActiveOverrides() throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "Base", source: .inline, rawYAML: "rules:\n  - MATCH,DIRECT\n"),
            preferredID: "base"
        )
        _ = try OverrideRepository(paths: paths).addLocalOverride(
            name: "DNS",
            format: .yaml,
            content: "dns:\n  enable: true\n  unmodeled: preserved\n"
        )
        let controller = makeController(paths: paths)

        XCTAssertTrue(try controller.currentProfileDeclaresDNS())
    }

    func testSetDnsSourceSameSourceIsIdempotentWithoutPreflight() async throws {
        let paths = makePaths()
        let original = CoreStatus(
            corePath: "/nonexistent/mihomo",
            runtimeSettings: CoreRuntimeSettings(dns: DnsSettings())
        )
        try CoreStateStore(paths: paths).save(original)
        let controller = makeController(paths: paths)

        let result = try await controller.setDnsSource(.kumo)

        XCTAssertEqual(result, original.runtimeSettings?.dns)
        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
    }

    func testSetDnsSourceProfileWithoutDNSFailsWithoutWritingState() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "No DNS", source: .inline, rawYAML: "rules:\n  - MATCH,DIRECT\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        let original = CoreStatus(
            corePath: core,
            runtimeSettings: CoreRuntimeSettings(dns: DnsSettings(nameserver: ["https://kumo.example/dns-query"]))
        )
        try CoreStateStore(paths: paths).save(original)
        let controller = makeController(paths: paths)

        do {
            _ = try await controller.setDnsSource(.profile)
            XCTFail("Expected profile DNS ownership to be rejected")
        } catch {
            guard case .invalidArguments = error as? KumoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
        XCTAssertEqual(try controller.runtimeEvents(), [])
    }

    func testSetDnsSourcePreflightFailureDoesNotWriteState() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "DNS", source: .inline, rawYAML: "dns:\n  enable: true\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths, validationSucceeds: false)
        let original = CoreStatus(
            corePath: core,
            runtimeSettings: CoreRuntimeSettings(dns: DnsSettings())
        )
        try CoreStateStore(paths: paths).save(original)
        let controller = makeController(paths: paths)

        do {
            _ = try await controller.setDnsSource(.profile)
            XCTFail("Expected preflight to fail")
        } catch {
            guard case .configurationValidationFailed = error as? KumoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
        XCTAssertEqual(try controller.runtimeEvents(), [])
    }

    func testSetDnsSourceSuccessUsesCandidatePreflightWithoutInstalling() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "DNS", source: .inline, rawYAML: "dns:\n  enable: true\n  unmodeled: preserved\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        let original = CoreStatus(
            corePath: core,
            runtimeSettings: CoreRuntimeSettings(dns: DnsSettings())
        )
        try CoreStateStore(paths: paths).save(original)
        let controller = makeController(paths: paths)

        let result = try await controller.setDnsSource(.profile)

        XCTAssertEqual(result.source, .profile)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().runtimeSettings?.dns?.source, .profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
        XCTAssertEqual(try controller.runtimeEvents(), [])
    }

    func testEffectiveProfileDNSAllowsOnlyHostsEdits() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "DNS", source: .inline, rawYAML: "dns:\n  enable: true\n"),
            preferredID: "current"
        )
        let stored = DnsSettings(nameserver: ["https://kumo.example/dns-query"], source: .profile)
        let original = CoreStatus(runtimeSettings: CoreRuntimeSettings(dns: stored))
        try CoreStateStore(paths: paths).save(original)
        let controller = makeController(paths: paths)

        var dnsEdit = stored
        dnsEdit.nameserver = ["https://other.example/dns-query"]
        do {
            _ = try await controller.applyDnsSettings(dnsEdit)
            XCTFail("Expected a profile-owned DNS edit to be rejected")
        } catch {
            guard case .invalidArguments = error as? KumoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)

        do {
            _ = try await controller.setDnsEnabled(false)
            XCTFail("Expected a profile-owned enable edit to be rejected")
        } catch {
            guard case .invalidArguments = error as? KumoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)

        var hostsEdit = stored
        hostsEdit.hosts = ["example.com": .single("192.0.2.1")]
        let result = try await controller.applyDnsSettings(hostsEdit)
        XCTAssertEqual(result.hosts, hostsEdit.hosts)
        XCTAssertEqual(result.source, .profile)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().runtimeSettings?.dns, hostsEdit)
    }

    func testFallbackProfileRequestAllowsKumoDNSEditsWithoutChangingSource() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "No DNS", source: .inline, rawYAML: "rules:\n  - MATCH,DIRECT\n"),
            preferredID: "current"
        )
        let stored = DnsSettings(source: .profile)
        try CoreStateStore(paths: paths).save(CoreStatus(runtimeSettings: CoreRuntimeSettings(dns: stored)))
        let controller = makeController(paths: paths)

        var edited = stored
        edited.nameserver = ["https://fallback.example/dns-query"]
        let applied = try await controller.applyDnsSettings(edited)
        XCTAssertEqual(applied.nameserver, edited.nameserver)
        XCTAssertEqual(applied.source, .profile)

        let disabled = try await controller.setDnsEnabled(false)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.source, .profile)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().runtimeSettings?.dns?.isEnabled, false)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().runtimeSettings?.dns?.source, .profile)
    }

    func testSourceChangeCannotIncludeOtherDNSEdits() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "DNS", source: .inline, rawYAML: "dns:\n  enable: true\n"),
            preferredID: "current"
        )
        let stored = DnsSettings(nameserver: ["https://kumo.example/dns-query"])
        let original = CoreStatus(runtimeSettings: CoreRuntimeSettings(dns: stored))
        try CoreStateStore(paths: paths).save(original)
        var requested = stored
        requested.source = .profile
        requested.nameserver = ["https://other.example/dns-query"]
        let controller = makeController(paths: paths)

        do {
            _ = try await controller.applyDnsSettings(requested)
            XCTFail("Expected a combined source and DNS edit to be rejected")
        } catch {
            guard case .invalidArguments = error as? KumoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try CoreStateStore(paths: paths).load(), original)
    }

    func testSupervisorLogsDNSWarningsOnlyForInstalledValidation() throws {
        let paths = makePaths()
        let core = try makeCore(paths: paths)
        let supervisor = CoreSupervisor(paths: paths)
        let configuration = CoreLaunchConfiguration(
            corePath: core,
            profile: Profile(name: "No DNS", source: .inline, rawYAML: "rules:\n  - MATCH,DIRECT\n"),
            runtimeSettings: CoreRuntimeSettings(dns: DnsSettings(source: .profile))
        )

        let preview = try supervisor.validateConfiguration(configuration, install: false)
        XCTAssertEqual(preview.warnings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
        XCTAssertEqual(try supervisor.recentRuntimeEvents(), [])

        _ = try supervisor.validateConfiguration(configuration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path))
        let warnings = try supervisor.recentRuntimeEvents().filter { $0.kind == "config.dns_warning" }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0].message, preview.warnings[0])
    }

    private func makePaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func makeController(paths: KumoPaths) -> KumoController {
        KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: .live,
            reachability: nil,
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil
        )
    }

    private func makeCore(paths: KumoPaths, validationSucceeds: Bool = true) throws -> String {
        try paths.prepare()
        let url = paths.applicationSupportDirectory.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then
          \(validationSucceeds ? "exit 0" : "echo 'fatal: invalid candidate' >&2; exit 1")
        fi
        exit 99
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
