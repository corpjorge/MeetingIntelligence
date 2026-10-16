/// FIFO mutual exclusion for use *inside* an actor.
///
/// Actors are reentrant: while one call awaits, another call to the same actor
/// may start. Engines that drive a single non-reentrant model instance use this
/// gate so at most one inference runs at a time, in arrival order:
///
/// ```swift
/// if !gate.tryEnter() { await withCheckedContinuation { gate.enqueue($0) } }
/// defer { gate.leave() }
/// ```
struct SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    mutating func tryEnter() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    mutating func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        waiters.append(continuation)
    }

    /// Hands ownership to the next waiter (still busy) or frees the gate.
    mutating func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Holds a non-Sendable engine object owned by an actor. Safety argument: the
/// owning actor only touches `value` while holding its `SerialGate`, so no two
/// tasks use it concurrently.
final class ExclusiveBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
