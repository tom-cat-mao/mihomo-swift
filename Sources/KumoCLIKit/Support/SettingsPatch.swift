import ArgumentParser
import Foundation

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

/// Applies a shallow JSON-object patch on top of `current` and decodes the
/// result back into the settings type.
///
/// Only the top-level keys present in the patch are replaced; arrays and
/// nested dictionaries are replaced wholesale. Unknown keys are ignored by
/// the settings decoder; a value whose type does not match the schema fails
/// the command with a `ValidationError`.
func applyingSettingsPatch<T: Codable>(_ patch: Data, to current: T, name: String) throws -> T {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    guard let currentObject = try encoder.encode(current).asJSONDictionary() else {
        throw ValidationError("Could not read current \(name) state.")
    }

    let patchObject: Any
    do {
        patchObject = try JSONSerialization.jsonObject(with: patch)
    } catch {
        throw ValidationError("The \(name) patch is not valid JSON: \(error.localizedDescription)")
    }
    guard let patchDictionary = patchObject as? [String: Any] else {
        throw ValidationError("The \(name) patch must be a JSON object.")
    }

    var merged = currentObject
    for (key, value) in patchDictionary {
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
