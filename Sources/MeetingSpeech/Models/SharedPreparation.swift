import Foundation
import os

final class PreparationProgress: Sendable {
    private let state = OSAllocatedUnfairLock<(observers: [UUID: @Sendable (ModelPreparationPhase) -> Void],
                                               last: ModelPreparationPhase?)>(initialState: ([:], nil))

    func send(_ phase: ModelPreparationPhase) {
        let observers = state.withLock { current in
            current.last = phase
            return Array(current.observers.values)
        }
        for observer in observers { observer(phase) }
    }

    func observe(_ observer: @escaping @Sendable (ModelPreparationPhase) -> Void) -> UUID {
        let id = UUID()
        let last = state.withLock { current in
            current.observers[id] = observer
            return current.last
        }
        if let last { observer(last) }
        return id
    }

    func remove(_ id: UUID) {
        state.withLock { current in _ = current.observers.removeValue(forKey: id) }
    }
}

enum CancellableWait {
    static func value<Value: Sendable>(of task: Task<Value, any Error>) async throws -> Value {
        let state = OSAllocatedUnfairLock<(waiter: CheckedContinuation<Value, any Error>?, cancelled: Bool)>(
            initialState: (nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { current in
                    if !current.cancelled { current.waiter = continuation }
                    return current.cancelled
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                Task {
                    let result = await task.result
                    state.withLock { current in
                        defer { current.waiter = nil }
                        return current.waiter
                    }?.resume(with: result)
                }
            }
        } onCancel: {
            state.withLock { current in
                current.cancelled = true
                defer { current.waiter = nil }
                return current.waiter
            }?.resume(throwing: CancellationError())
        }
    }
}
