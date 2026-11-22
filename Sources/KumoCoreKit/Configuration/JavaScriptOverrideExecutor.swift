import Darwin
import Foundation

public enum JavaScriptOverrideError: LocalizedError, Sendable {
    case invalidConfiguration
    case executionUnavailable(String)
    case evaluationFailed(String)
    case nonObjectResult
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The configuration cannot be represented as JSON."
        case .executionUnavailable(let message):
            return message
        case .evaluationFailed(let message):
            return message
        case .nonObjectResult:
            return "main(config) must return an object."
        case .timedOut:
            return "JavaScript execution exceeded the 5-second timeout."
        }
    }
}

/// Executes one override in a fresh system JavaScriptCore shell process.
///
/// The public JavaScriptCore API cannot interrupt an infinite loop from another
/// thread. Process isolation provides a real timeout: the parent terminates the
/// shell after five seconds. The wrapper removes the shell's host capabilities
/// before evaluating user code and exposes only standard JavaScript, the
/// configuration argument, and a small console object.
public struct JavaScriptOverrideExecutor: Sendable {
    public static let defaultTimeout: TimeInterval = 5

    private let timeout: TimeInterval
    private let executableURL: URL

    public init() {
        self.init(
            timeout: Self.defaultTimeout,
            executableURL: URL(fileURLWithPath: "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc")
        )
    }

    init(timeout: TimeInterval, executableURL: URL? = nil) {
        self.timeout = timeout
        self.executableURL = executableURL ?? URL(
            fileURLWithPath: "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
        )
    }

    public func apply(script: String, configuration: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(configuration) else {
            throw JavaScriptOverrideError.invalidConfiguration
        }

        let configurationData = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        guard let configurationJSON = String(data: configurationData, encoding: .utf8) else {
            throw JavaScriptOverrideError.invalidConfiguration
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-js-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runnerURL = temporaryDirectory.appendingPathComponent("override.js")
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        let runner = try makeRunner(script: script, configurationJSON: configurationJSON)
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [runnerURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw JavaScriptOverrideError.executionUnavailable(
                "Could not start the macOS JavaScriptCore executor: \(error.localizedDescription)"
            )
        }

        let didTimeOut = waitForExit(process, timeout: timeout)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        if didTimeOut {
            throw JavaScriptOverrideError.timedOut
        }

        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let diagnostic = !stderr.isEmpty ? stderr : stdout
            throw JavaScriptOverrideError.evaluationFailed(
                diagnostic.isEmpty ? "JavaScriptCore exited with status \(process.terminationStatus)." : diagnostic
            )
        }

        guard let resultData = stdout.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData),
              let object = result as? [String: Any] else {
            throw JavaScriptOverrideError.nonObjectResult
        }
        guard let compatible = yamlCompatibleValue(object) as? [String: Any] else {
            throw JavaScriptOverrideError.nonObjectResult
        }
        return compatible
    }

    private func yamlCompatibleValue(_ value: Any) -> Any {
        if let mapping = value as? [String: Any] {
            return mapping.mapValues(yamlCompatibleValue)
        }
        if let array = value as? [Any] {
            return array.map(yamlCompatibleValue)
        }
        if let string = value as? NSString {
            return string as String
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" {
                return number.boolValue
            }
            if type == "f" || type == "d" {
                return number.doubleValue
            }
            return Int(number.int64Value)
        }
        return value
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }

        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < terminationDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }

    private func makeRunner(script: String, configurationJSON: String) throws -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sourceName = "__kumoSource\(token)"
        let configName = "__kumoConfig\(token)"
        let printName = "__kumoPrint\(token)"
        let printErrorName = "__kumoPrintError\(token)"
        let resultName = "__kumoResult\(token)"
        let outputName = "__kumoOutput\(token)"
        let hostCapabilities = [
            "print", "printErr", "read", "readFile", "writeFile", "load", "run", "quit", "exit",
            "open", "system", "exec", "spawn", "popen", "require", "process", "fetch",
            "XMLHttpRequest", "WebSocket", "Worker", "Realm", "$vm", "dollar", "testRunner"
        ]
        let hostCapabilitiesJSON = try jsonLiteral(hostCapabilities)

        return """
        const \(printName) = print;
        const \(printErrorName) = printErr;
        for (const name of \(hostCapabilitiesJSON)) {
            try { delete globalThis[name]; } catch (_) {}
        }
        globalThis.console = Object.freeze({
            log: (...args) => \(printErrorName)(args.map(String).join(" ")),
            info: (...args) => \(printErrorName)(args.map(String).join(" ")),
            warn: (...args) => \(printErrorName)(args.map(String).join(" ")),
            error: (...args) => \(printErrorName)(args.map(String).join(" ")),
            debug: (...args) => \(printErrorName)(args.map(String).join(" "))
        });
        const \(sourceName) = \(try jsonLiteral(script));
        const \(configName) = JSON.parse(\(try jsonLiteral(configurationJSON)));
        eval(\(sourceName));
        if (typeof main !== "function") {
            throw new Error("main(config) function is required.");
        }
        const \(resultName) = main(\(configName));
        if (\(resultName) === null || typeof \(resultName) !== "object" || Array.isArray(\(resultName))) {
            throw new Error("main(config) must return an object.");
        }
        const \(outputName) = JSON.stringify(\(resultName));
        if (typeof \(outputName) !== "string") {
            throw new Error("main(config) must return a JSON-serializable object.");
        }
        \(printName)(\(outputName));
        """
    }

    private func jsonLiteral<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JavaScriptOverrideError.invalidConfiguration
        }
        return string
    }
}
