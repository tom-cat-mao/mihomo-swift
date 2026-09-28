import Foundation

/// One shared `ByteCountFormatter` for the whole process.
///
/// `ByteCountFormatter` is not `Sendable`, and `Formatter` subclasses are not
/// documented as safe for concurrent use, so the instance lives behind a lock.
/// Even with the lock this is much cheaper than the
/// `ByteCountFormatter.string(fromByteCount:countStyle:)` class method the UI
/// used to call, which creates a throwaway formatter on every invocation — and
/// the traffic, transfer and cache labels call this on every render pass.
private final class ByteCountFormatterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ByteCountFormatter()

    init() {
        formatter.countStyle = .binary
    }

    func string(fromByteCount byteCount: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: byteCount)
    }
}

private let sharedByteCountFormatter = ByteCountFormatterBox()

public extension Int {
    /// The binary-style byte count the UI shows for traffic, transfers and
    /// cache sizes, where "1 KB" means 1024 bytes.
    var kumoByteCount: String {
        sharedByteCountFormatter.string(fromByteCount: Int64(self))
    }
}
