import XCTest
@testable import KumoCoreKit

/// Pins `Int.kumoByteCount` to the `ByteCountFormatter` reference the UI relied
/// on before the formatter was cached, so the cache can never silently change
/// what users see. The comparison is made against the class method rather than
/// literal strings because `ByteCountFormatter` output is locale-dependent.
final class ByteCountFormattingTests: XCTestCase {
    private let values: [Int] = [0, 999, 1023, 1024, 1_500_000, Int(Int32.max)]

    func testKumoByteCountMatchesBinaryReferenceValues() {
        for value in values {
            let expected = ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
            XCTAssertEqual(value.kumoByteCount, expected, "mismatch for \(value)")
        }
    }

    /// `.binary` means 1024-based units. A default `ByteCountFormatter` is
    /// `.file` (1000-based), so this guards the count style specifically:
    /// 1.5 MB decimal is ~1.4 MB binary, and 1024 bytes reads "1 KB" in both
    /// styles, so the discriminator has to be a value the two actually disagree
    /// on.
    func testKumoByteCountUsesBinaryUnits() {
        XCTAssertNotEqual(1_500_000.kumoByteCount, ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .decimal))
        XCTAssertNotEqual(Int(Int32.max).kumoByteCount, ByteCountFormatter.string(fromByteCount: Int64(Int32.max), countStyle: .decimal))
    }

    /// The formatter is shared process-wide, so repeated and concurrent reads
    /// must agree with the reference output. This is the check that would catch
    /// a cache that is not safe to share.
    func testKumoByteCountIsStableAcrossConcurrentReads() {
        let expected = values.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary) }

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let value = self.values[iteration % self.values.count]
            XCTAssertEqual(value.kumoByteCount, expected[iteration % expected.count])
        }
    }
}
