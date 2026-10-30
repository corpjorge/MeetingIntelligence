import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelPreparationPhase] = []

    func append(_ phase: ModelPreparationPhase) { lock.withLock { stored.append(phase) } }
    var values: [ModelPreparationPhase] { lock.withLock { stored } }
}

@Suite("Preparación compartida de modelos", .timeLimit(.minutes(1)))
struct SharedPreparationTests {
    @Test func cancelledWaiterLeavesWithoutCancellingTheSharedPreparation() async throws {
        let preparation = Task<Int, any Error> {
            try? await Task.sleep(for: .milliseconds(1_500))
            return Task.isCancelled ? -1 : 42
        }
        let waiter = Task { try await CancellableWait.value(of: preparation) }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(clock.now - cancelledAt < .milliseconds(700))
        #expect(!preparation.isCancelled)
        #expect(try await CancellableWait.value(of: preparation) == 42)
    }

    @Test func alreadyCancelledWaiterLeavesImmediately() async {
        let preparation = Task<Int, any Error> {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        defer { preparation.cancel() }
        let waiter = Task { try await CancellableWait.value(of: preparation) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!preparation.isCancelled)
    }

    @Test func waitersReceiveTheSharedResultOrError() async throws {
        struct Failure: Error {}
        let ready = Task<Int, any Error> { 7 }
        #expect(try await CancellableWait.value(of: ready) == 7)
        #expect(try await CancellableWait.value(of: ready) == 7)
        let failing = Task<Int, any Error> { throw Failure() }
        await #expect(throws: Failure.self) { try await CancellableWait.value(of: failing) }
    }

    @Test func progressReachesCurrentObserversOnly() {
        let progress = PreparationProgress()
        let first = PhaseRecorder(), second = PhaseRecorder()
        let a = progress.observe { first.append($0) }
        progress.send(.checking)
        let b = progress.observe { second.append($0) }
        progress.send(.downloading(fraction: 0.5))
        progress.remove(a)
        progress.send(.loading)
        progress.remove(b)
        progress.send(.ready)
        #expect(first.values == [.checking, .downloading(fraction: 0.5)])
        #expect(second.values == [.checking, .downloading(fraction: 0.5), .loading])
    }
}
