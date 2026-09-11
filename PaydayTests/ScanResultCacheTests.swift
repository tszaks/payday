import Foundation
import XCTest
@testable import Payday

final class ScanResultCacheTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor CancellationProbe {
        private(set) var wasCancelled = false
        func markCancelled() { wasCancelled = true }
    }

    func testReturnsCachedValueForIdenticalBytes() async {
        let cache = ScanResultCache<String>()
        let data = Data([1, 2, 3])

        await cache.insert("parsed", for: data)

        let cached = await cache.value(for: data)
        XCTAssertEqual(cached, "parsed")
    }

    func testEvictsLeastRecentlyUsedValueAtCapacity() async {
        let cache = ScanResultCache<String>(capacity: 2)
        let first = Data([1])
        let second = Data([2])
        let third = Data([3])

        await cache.insert("first", for: first)
        await cache.insert("second", for: second)
        _ = await cache.value(for: first)
        await cache.insert("third", for: third)

        let retained = await cache.value(for: first)
        let evicted = await cache.value(for: second)
        XCTAssertEqual(retained, "first")
        XCTAssertNil(evicted)
    }

    func testCoalescesConcurrentLoadsForIdenticalBytes() async throws {
        let cache = ScanResultCache<String>()
        let counter = Counter()
        let data = Data([9, 8, 7])

        async let first = cache.value(for: data) {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(25))
            return "parsed"
        }
        async let second = cache.value(for: data) {
            await counter.increment()
            return "duplicate"
        }

        let values = try await [first, second]
        let loadCount = await counter.value
        XCTAssertEqual(Set(values).count, 1)
        XCTAssertEqual(loadCount, 1)
    }

    func testCancellingOnlyWaiterCancelsUnderlyingLoad() async {
        let cache = ScanResultCache<String>()
        let probe = CancellationProbe()
        let data = Data([4, 5, 6])
        let request = Task {
            try await cache.value(for: data) {
                do {
                    try await Task.sleep(for: .seconds(5))
                    return "late result"
                } catch is CancellationError {
                    await probe.markCancelled()
                    throw CancellationError()
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(25))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A canceled scan should not return a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let loaderWasCancelled = await probe.wasCancelled
        let cached = await cache.value(for: data)
        XCTAssertTrue(loaderWasCancelled)
        XCTAssertNil(cached)
    }
}
