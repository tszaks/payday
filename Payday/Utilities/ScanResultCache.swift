import CryptoKit
import Foundation

/// Small process-local cache for successful scan results. A user can select
/// the same image twice after dismissing or retrying a sheet; hashing the
/// already-compressed upload bytes avoids paying for the same remote analysis
/// again without persisting private image data to disk.
actor ScanResultCache<Value: Sendable> {
    private struct InFlightWork {
        let id: UUID
        let task: Task<Value, Error>
        var waiters: Int
    }

    private let capacity: Int
    private var values: [String: Value] = [:]
    private var recency: [String] = []
    private var inFlight: [String: InFlightWork] = [:]

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func value(for data: Data) -> Value? {
        let key = key(for: data)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func insert(_ value: Value, for data: Data) {
        insert(value, forKey: key(for: data))
    }

    /// Shares one expensive analysis among simultaneous callers for identical
    /// bytes. Successful work enters the LRU; failures remain retryable.
    func value(
        for data: Data,
        orLoad load: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let key = key(for: data)
        if let value = values[key] {
            touch(key)
            return value
        }
        let work: InFlightWork
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            work = existing
        } else {
            let created = InFlightWork(
                id: UUID(),
                task: Task { try await load() },
                waiters: 1
            )
            inFlight[key] = created
            work = created
        }

        return try await withTaskCancellationHandler {
            do {
                let value = try await work.task.value
                try Task.checkCancellation()
                if inFlight[key]?.id == work.id {
                    insert(value, forKey: key)
                    inFlight.removeValue(forKey: key)
                }
                return value
            } catch is CancellationError {
                if !Task.isCancelled, inFlight[key]?.id == work.id {
                    inFlight.removeValue(forKey: key)
                }
                throw CancellationError()
            } catch {
                if inFlight[key]?.id == work.id {
                    inFlight.removeValue(forKey: key)
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(forKey: key, workID: work.id) }
        }
    }

    private func insert(_ value: Value, forKey key: String) {
        values[key] = value
        touch(key)

        while recency.count > capacity, let evicted = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    private func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func cancelWaiter(forKey key: String, workID: UUID) {
        guard var work = inFlight[key], work.id == workID else { return }
        work.waiters -= 1
        if work.waiters <= 0 {
            work.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = work
        }
    }
}
