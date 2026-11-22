import Darwin
import Foundation

/// Kernel identity for a recorded process. A pid alone is not an identity:
/// start time distinguishes a reused pid, and `isZombie` prevents an exited
/// child that has not been reaped yet from being reported as running.
struct CoreProcessSnapshot: Equatable, Sendable {
    var startedAt: Date?
    var executablePath: String?
    var isZombie: Bool

    static let foreign = CoreProcessSnapshot(startedAt: nil, executablePath: nil, isZombie: false)
}

protocol CoreProcessInspecting: Sendable {
    func snapshot(pid: Int32) -> CoreProcessSnapshot?
}

struct LiveCoreProcessInspector: CoreProcessInspecting {
    func snapshot(pid: Int32) -> CoreProcessSnapshot? {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        if result > 0 {
            let seconds = TimeInterval(info.pbi_start_tvsec)
            let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
            return CoreProcessSnapshot(
                startedAt: Date(timeIntervalSince1970: seconds + microseconds),
                executablePath: executablePath(pid: pid),
                isZombie: Int32(info.pbi_status) == SZOMB
            )
        }

        // Some cross-user processes cannot be inspected by an unprivileged
        // caller. EPERM still proves existence, but not identity; callers keep
        // that process visible and refuse to signal it without a matching
        // persisted start time or executable path.
        if Darwin.kill(pid, 0) == 0 || errno == EPERM {
            return CoreProcessSnapshot(
                startedAt: nil,
                executablePath: executablePath(pid: pid),
                isZombie: false
            )
        }
        return nil
    }

    private func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        let path = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: path, as: UTF8.self)
    }
}
