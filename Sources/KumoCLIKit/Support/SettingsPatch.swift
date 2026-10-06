import ArgumentParser
import Foundation
import KumoCoreKit

/// Declares the top-level keys a settings type accepts in a shallow JSON patch.
///
/// Types that conform reject unknown keys in `applyingSettingsPatch` with an
/// error that lists the accepted keys. Types without a conformance keep the
/// historical behavior of ignoring unknown keys (for example
/// `SystemProxySettings`).
protocol SettingsPatchKeyProviding {
    static var patchKeys: Set<String> { get }
}

extension DnsSettings: SettingsPatchKeyProviding {
    /// Mirrors the Codable keys of `DnsSettings`; kept honest by
    /// `testPatchKeyAllowlistsMatchCodableKeys`.
    static let patchKeys: Set<String> = [
        "isEnabled", "listen", "ipv6", "ipv6Timeout", "preferH3", "enhancedMode",
        "fakeIPRange", "fakeIPRange6", "fakeIPFilter", "fakeIPFilterMode", "useHosts",
        "useSystemHosts", "respectRules", "defaultNameserver", "nameserver", "fallback",
        "fallbackFilter", "proxyServerNameserver", "directNameserver",
        "directNameserverFollowPolicy", "nameserverPolicy", "proxyServerNameserverPolicy",
        "cacheAlgorithm", "hosts"
    ]
}

extension SnifferSettings: SettingsPatchKeyProviding {
    /// Mirrors the Codable keys of `SnifferSettings`; kept honest by
    /// `testPatchKeyAllowlistsMatchCodableKeys`.
    static let patchKeys: Set<String> = [
        "isEnabled", "parsePureIP", "forceDNSMapping", "overrideDestination",
        "httpOverrideDestination", "httpPorts", "tlsPorts", "quicPorts", "skipDomain",
        "forceDomain", "skipDstAddress", "skipSrcAddress"
    ]
}

extension TunSettings: SettingsPatchKeyProviding {
    /// Mirrors the Codable keys of `TunSettings`; kept honest by
    /// `testPatchKeyAllowlistsMatchCodableKeys`.
    static let patchKeys: Set<String> = [
        "isEnabled", "stack", "autoRoute", "autoRedirect", "autoDetectInterface",
        "strictRoute", "disableICMPForwarding", "dnsHijack", "routeExcludeAddress",
        "mtu", "device"
    ]
}

/// Reads a JSON settings patch from `--file <path>` or stdin.
///
/// Callers validate that exactly one source was provided before calling this.
func readSettingsPatchJSON(file: String?, stdin: Bool) throws -> Data {
    let data: Data
    if let file {
        let path = (file as NSString).expandingTildeInPath
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ValidationError("Could not read settings file \(path): \(error.localizedDescription)")
        }
    } else if stdin {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        throw ValidationError("Provide --file <path> or --stdin with a JSON settings patch.")
    }

    let text = String(data: data, encoding: .utf8) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("The settings patch is empty.")
    }
    return data
}

/// Decodes a JSON settings patch into its top-level dictionary.
func decodeSettingsPatch(_ patch: Data, name: String) throws -> [String: Any] {
    let patchObject: Any
    do {
        patchObject = try JSONSerialization.jsonObject(with: patch)
    } catch {
        throw ValidationError("The \(name) patch is not valid JSON: \(error.localizedDescription)")
    }
    guard let dictionary = patchObject as? [String: Any] else {
        throw ValidationError("The \(name) patch must be a JSON object.")
    }
    return dictionary
}

/// Rejects patch keys outside `validKeys`, listing the accepted keys.
func validateSettingsPatchKeys<S: Sequence>(
    _ keys: S,
    validKeys: Set<String>,
    name: String
) throws where S.Element == String {
    let unknown = Set(keys).subtracting(validKeys).sorted()
    guard unknown.isEmpty else {
        let noun = unknown.count == 1 ? "key" : "keys"
        throw ValidationError(
            "Unknown \(noun) in the \(name) patch: \(unknown.joined(separator: ", ")). "
                + "Valid keys: \(validKeys.sorted().joined(separator: ", "))."
        )
    }
}

/// Applies a shallow JSON-object patch on top of `current` and decodes the
/// result back into the settings type.
///
/// Only the top-level keys present in the patch are replaced; arrays and
/// nested dictionaries are replaced wholesale. Types conforming to
/// `SettingsPatchKeyProviding` reject unknown top-level keys with the list of
/// valid keys; the settings decoder fails the command with a `ValidationError`
/// when a value's type does not match the schema.
func applyingSettingsPatch<T: Codable>(_ patch: Data, to current: T, name: String) throws -> T {
    let dictionary = try decodeSettingsPatch(patch, name: name)
    if let provider = T.self as? any SettingsPatchKeyProviding.Type {
        try validateSettingsPatchKeys(dictionary.keys, validKeys: provider.patchKeys, name: name)
    }
    return try applyingSettingsPatch(dictionary, to: current, name: name)
}

/// Applies an already-decoded shallow patch dictionary; see
/// `applyingSettingsPatch(_:to:name:)` for the merge semantics.
func applyingSettingsPatch<T: Codable>(_ patch: [String: Any], to current: T, name: String) throws -> T {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    guard let currentObject = try encoder.encode(current).asJSONDictionary() else {
        throw ValidationError("Could not read current \(name) state.")
    }

    var merged = currentObject
    for (key, value) in patch {
        merged[key] = value
    }

    do {
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try decoder.decode(T.self, from: mergedData)
    } catch {
        throw ValidationError("The \(name) patch does not match the \(name) schema: \(error.localizedDescription)")
    }
}

private extension Data {
    func asJSONDictionary() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}
