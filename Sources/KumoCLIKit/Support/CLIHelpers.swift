import ArgumentParser
import Darwin
import Foundation
import KumoCoreKit

func installManagedCoreIfNeeded() async throws {
    let controller = CLIRuntime.current.controller
    let status = try controller.status()
    let candidates = try controller.coreCandidates()
    let managedCorePath = controller.paths.managedCoreExecutable.path
    let managedCoreInstalled = FileManager.default.isExecutableFile(atPath: managedCorePath)
    let shouldInstall = if status.corePath == nil {
        !managedCoreInstalled
    } else {
        candidates.isEmpty
    }

    guard shouldInstall else { return }
    _ = try await controller.installManagedCore()
}

func currentDirectoryURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

/// Writes a `ServiceModeStatus` in the shared text shape used by both
/// `kumo service` and `kumo agent`.
func writeServiceModeStatus(_ status: ServiceModeStatus) {
    CLIRuntime.current.write(status) { status in
        [
            "installed=\(status.isInstalled)",
            "running=\(status.isRunning)",
            "available=\(status.isAvailable)",
            "privileged=\(status.isCurrentProcessPrivileged)"
        ].joined(separator: " ")
    }
}

/// Validates the mutually exclusive `--file` / `--stdin` settings inputs.
func validateSettingsInput(file: String?, stdin: Bool) throws {
    if file != nil && stdin {
        throw ValidationError("Use either --file <path> or --stdin, not both.")
    }
    if file == nil && !stdin {
        throw ValidationError("Provide --file <path> or --stdin with a JSON settings patch.")
    }
}

/// Runs a streaming body until it finishes or the caller presses Ctrl-C.
///
/// SIGINT cancels the body's task, which terminates `AsyncThrowingStream`
/// iteration and websocket consumption. The cancellation is swallowed so
/// Ctrl-C exits the CLI cleanly with code 0.
func runUntilInterrupted(_ body: @escaping @Sendable () async throws -> Void) async throws {
    signal(SIGINT, SIG_IGN)
    let task = Task { try await body() }
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    signalSource.setEventHandler {
        task.cancel()
    }
    signalSource.resume()
    defer {
        signalSource.cancel()
        signal(SIGINT, SIG_DFL)
    }

    do {
        try await task.value
    } catch is CancellationError {
        // Ctrl-C: normal streaming exit.
    }
}
