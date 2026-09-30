import Darwin
import Foundation

/// Hands the app-support tree back to the user the privileged helper acts for.
///
/// Whichever side touches a state or log file first owns it. On a fresh
/// service-mode install the helper (root) creates `state.json`,
/// `logs/runtime-events.jsonl` and `work/*` as `root:staff`, after which every
/// non-root bookkeeping write fails with `EACCES` — the false `kumo start`
/// failure reported in Issue #3. The helper is the only side that can fix this,
/// so after writing files as root it chowns them to the authorized uid and that
/// user's primary gid.
///
/// The walk is a single bounded pass over the app-support root, which is small
/// (`profiles/`, `logs/`, `work/`, `overrides/`, `substore/`, `cores/`,
/// `updates/` and the top-level state files). Symlinked entries are neither
/// chowned nor descended into, so the repair can never reach anything outside
/// the tree. `/Library/PrivilegedHelperTools/io.kumo.KumoService` and the
/// launchd plist are not under the app-support root and stay root-owned.
public struct AppSupportOwnershipRepair: Sendable {
    public let applicationSupportDirectory: URL
    public let ownerUID: uid_t
    public let ownerGID: gid_t

    public init(applicationSupportDirectory: URL, ownerUID: uid_t, ownerGID: gid_t) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
    }

    /// Resolves the authorized uid to its primary gid with `getpwuid`, the same
    /// pair the helper uses when it chowns the service socket. Returns nil when
    /// the uid has no passwd entry, in which case there is no owner to repair
    /// towards and callers skip the repair.
    public init?(applicationSupportDirectory: URL, authorizedUID: uid_t) {
        guard let entry = getpwuid(authorizedUID) else {
            return nil
        }
        self.init(
            applicationSupportDirectory: applicationSupportDirectory,
            ownerUID: authorizedUID,
            ownerGID: entry.pointee.pw_gid
        )
    }

    /// The app-support root followed by every non-symlinked descendant.
    /// Factored out of `repair()` so the selection is testable without root.
    public func repairTargets(fileManager: FileManager = .default) -> [URL] {
        var targets = [applicationSupportDirectory]
        guard let enumerator = fileManager.enumerator(
            at: applicationSupportDirectory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return targets
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            targets.append(url)
        }
        return targets
    }

    /// Chowns every target to `ownerUID:ownerGID` and returns how many entries
    /// were repaired. No-op unless the current process is root, so the routine
    /// can be called unconditionally. Individual failures (an entry removed
    /// mid-walk, a protected system mount) are ignored — the next call retries.
    @discardableResult
    public func repair(fileManager: FileManager = .default) -> Int {
        guard geteuid() == 0 else {
            return 0
        }

        var repaired = 0
        for url in repairTargets(fileManager: fileManager) where chown(url.path, ownerUID, ownerGID) == 0 {
            repaired += 1
        }
        return repaired
    }
}
