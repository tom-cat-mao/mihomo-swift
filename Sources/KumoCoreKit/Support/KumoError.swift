import Foundation

public enum KumoError: LocalizedError, Equatable {
    case coreNotFound(String)
    case coreAlreadyRunning(Int32)
    case coreNotRunning
    case controllerPortInUse(String, Int)
    case mixedPortInUse(String, Int)
    case configurationValidationFailed(String)
    case portConflicts([PortConflict])
    case invalidArguments(String)
    case unsupportedProfileSource
    case controllerResponse(Int, String)
    case commandFailed(String)
    case coreInstallFailed(String)
    case serviceUnavailable(String)
    case agentSkillsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .coreNotFound(let path):
            "Mihomo core was not found. Choose a core in Core settings or install mihomo with Homebrew. Last checked: \(path)."
        case .coreAlreadyRunning(let pid):
            "Mihomo core is already running with pid \(pid)."
        case .coreNotRunning:
            "Mihomo core is not running."
        case .controllerPortInUse(let host, let port):
            "The controller port \(host):\(port) is already in use by another process. Stop the other Mihomo core or change the controller endpoint before starting Kumo."
        case .mixedPortInUse(let host, let port):
            "The mixed proxy port \(host):\(port) is already in use by another process. Stop the process using it or change Mixed Port before starting Kumo."
        case .configurationValidationFailed(let message):
            "Mihomo configuration preflight failed: \(message)"
        case .portConflicts(let conflicts):
            conflicts.map(\.displayMessage).joined(separator: " ")
        case .invalidArguments(let message):
            message
        case .unsupportedProfileSource:
            "This profile source is not supported yet."
        case .controllerResponse(let status, let body):
            "Controller returned HTTP \(status): \(body)"
        case .commandFailed(let message):
            message
        case .coreInstallFailed(let message):
            "Core installation failed: \(message)"
        case .serviceUnavailable(let message):
            message
        case .agentSkillsFailed(let message):
            "Agent skills failed: \(message)"
        }
    }
}
