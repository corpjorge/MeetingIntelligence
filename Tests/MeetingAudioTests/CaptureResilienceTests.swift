import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MeetingAudio
@testable import MeetingCore

private struct TransientTapFailure: LocalizedError {
    var errorDescription: String? { "Fallo transitorio del HAL." }
}

private final class FakeTap: RemoteAudioTap {
    var failuresRemaining = 0
    private(set) var rebuilds: [ProcessTapSource.Target] = []
    private(set) var stops = 0
    private(set) var isRunning = false

    func rebuild(target: ProcessTapSource.Target) throws {
        rebuilds.append(target)
        isRunning = false
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TransientTapFailure()
        }
        isRunning = true
    }

    func stop() {
        stops += 1
        isRunning = false
    }
}

private final class ManualClock {
    var now = 100.0
}

private func teams(_ ids: AudioObjectID...) -> [AudioProcessInfo] {
    ids.map { AudioProcessInfo(objectID: $0, pid: pid_t($0), bundleID: "com.microsoft.teams2", executablePath: nil, isRunningOutput: true) }
}

private let tapFailure = RecordingWarning.sourceFailed(.remoteSystemAudio, "Fallo transitorio del HAL. Se reintentará automáticamente.")
private let restored = RecordingWarning.remoteTapRebuilt("se restableció la captura remota")

@Suite("Captura remota: reintentos del tap")
struct RemoteTapRecoveryTests {
    private func make(_ tap: FakeTap, _ clock: ManualClock) -> (RemoteTapSupervisor, () -> [RemoteTapEvent]) {
        let supervisor = RemoteTapSupervisor(tap: tap, now: { clock.now })
        let log = EventLog()
        supervisor.onEvent = { log.events.append($0) }
        return (supervisor, { defer { log.events.removeAll() }; return log.events })
    }

    @Test func retryDelaysDoubleUpToThirtySeconds() {
        var policy = TapRetryPolicy()
        #expect((0..<8).map { _ in policy.recordFailure(at: 0) } == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(policy.isDue(at: 30) && !policy.isDue(at: 29.9))
        policy.reset()
        #expect(!policy.isDue(at: 1_000))
        #expect(policy.recordFailure(at: 0) == 1)
    }

    @Test func failedRebuildAfterOutputChangeRetriesWithBackoffUntilRecovered() throws {
        let tap = FakeTap(), clock = ManualClock()
        let (supervisor, events) = make(tap, clock)
        let target = ProcessTapSource.Target.systemWideExcluding([7])
        try supervisor.start(target)
        tap.failuresRemaining = 3
        supervisor.outputDeviceChanged("AirPods")
        #expect(supervisor.isFailing && !tap.isRunning && supervisor.desired == target)
        #expect(events() == [.warning(tapFailure), .retryScheduled(1)])
        clock.now = 100.5
        supervisor.retryIfDue()
        #expect(tap.rebuilds.count == 2)
        clock.now = 101
        supervisor.retryIfDue()
        clock.now = 103
        supervisor.retryIfDue()
        clock.now = 106.9
        supervisor.retryIfDue()
        #expect(tap.rebuilds.count == 4)
        #expect(events() == [.retryScheduled(2), .retryScheduled(4)])
        clock.now = 107
        supervisor.retryIfDue()
        #expect(tap.rebuilds == Array(repeating: target, count: 5))
        #expect(events() == [.recovered(tapFailure), .warning(restored)])
        #expect(tap.isRunning && !supervisor.isFailing && supervisor.lastStartedAt == 107)
        clock.now = 200
        supervisor.retryIfDue()
        #expect(tap.rebuilds.count == 5 && events().isEmpty)
    }

    @Test func outputChangeWhileFailingRetriesImmediatelyAndRestartsTheBackoff() throws {
        let tap = FakeTap(), clock = ManualClock()
        let (supervisor, events) = make(tap, clock)
        try supervisor.start(.systemWideExcluding([]))
        tap.failuresRemaining = 4
        supervisor.outputDeviceChanged("AirPods")
        clock.now = 101
        supervisor.retryIfDue()
        clock.now = 101.5
        supervisor.outputDeviceChanged("Altavoces")
        #expect(tap.rebuilds.count == 4)
        #expect(events() == [.warning(tapFailure), .retryScheduled(1), .retryScheduled(2), .retryScheduled(1)])
        clock.now = 102.5
        supervisor.retryIfDue()
        #expect(tap.rebuilds.count == 5 && supervisor.isFailing)
        supervisor.outputDeviceChanged("Altavoces")
        #expect(events() == [.retryScheduled(2), .recovered(tapFailure), .warning(.outputDeviceChanged("Altavoces"))])
        #expect(tap.isRunning)
    }

    @Test func processListUpdatesTappedProcessesOnlyAfterASuccessfulRebuild() throws {
        let tap = FakeTap(), clock = ManualClock()
        let (supervisor, events) = make(tap, clock)
        let first = teams(1), second = teams(1, 2)
        try supervisor.start(.processes([1]), processes: first)
        tap.failuresRemaining = 1
        supervisor.processesChanged(second, appName: "Teams")
        #expect(supervisor.tappedProcesses == first)
        #expect(supervisor.desired == .processes([1, 2]))
        #expect(events() == [.warning(tapFailure), .retryScheduled(1)])
        supervisor.processesChanged(second, appName: "Teams")
        #expect(tap.rebuilds.count == 2 && events().isEmpty)
        clock.now = 101
        supervisor.processesChanged(second, appName: "Teams")
        #expect(tap.rebuilds.last == .processes([1, 2]) && tap.rebuilds.count == 3)
        #expect(supervisor.tappedProcesses == second)
        #expect(events() == [.processes(second), .recovered(tapFailure), .warning(restored)])
    }

    @Test func appWithoutProcessesStopsRetryingAndRecoversWhenItsAudioReturns() throws {
        let tap = FakeTap(), clock = ManualClock()
        let (supervisor, events) = make(tap, clock)
        try supervisor.start(.processes([1]), processes: teams(1))
        tap.failuresRemaining = 1
        supervisor.processesChanged(teams(1, 2), appName: "Teams")
        _ = events()
        supervisor.processesChanged([], appName: "Teams")
        #expect(events() == [.processes([]), .warning(.waitingForAppAudio("Teams"))])
        #expect(supervisor.desired == nil && !supervisor.isFailing && tap.stops == 1)
        clock.now = 500
        supervisor.retryIfDue()
        supervisor.outputDeviceChanged("AirPods")
        supervisor.formatChanged(sampleRate: 24_000)
        #expect(tap.rebuilds.count == 2 && events().isEmpty)
        supervisor.processesChanged(teams(3), appName: "Teams")
        #expect(tap.rebuilds.last == .processes([3]) && tap.isRunning)
        #expect(events() == [.processes(teams(3)), .recovered(tapFailure),
                             .warning(.remoteTapRebuilt("procesos de Teams actualizados (1)"))])
    }

    @Test func tapFormatChangeRebuildsTheSameTargetOnlyWhileCapturing() throws {
        let tap = FakeTap(), clock = ManualClock()
        let (supervisor, events) = make(tap, clock)
        let target = ProcessTapSource.Target.processes([4, 5])
        try supervisor.start(target, processes: teams(4, 5))
        clock.now = 120
        supervisor.formatChanged(sampleRate: 24_000)
        #expect(tap.rebuilds == [target, target] && supervisor.lastStartedAt == 120)
        #expect(events() == [.warning(.remoteTapRebuilt("la salida de audio cambió a 24000 Hz"))])
        tap.failuresRemaining = 1
        supervisor.formatChanged(sampleRate: 16_000)
        #expect(events() == [.warning(tapFailure), .retryScheduled(1)])
        supervisor.formatChanged(sampleRate: 48_000)
        #expect(tap.rebuilds.count == 3 && events().isEmpty)
        supervisor.stop()
        #expect(!tap.isRunning && supervisor.desired == nil)
        clock.now = 1_000
        supervisor.retryIfDue()
        #expect(tap.rebuilds.count == 3)
    }

    @Test func onlyRateOrSampleFormatChangesRebuildTheTap() {
        let a2dp = TapStreamFormat(sampleRate: 48_000, isFloat: true, channels: 2, bitsPerChannel: 32)
        #expect(!a2dp.requiresRebuild(for: a2dp))
        #expect(a2dp.requiresRebuild(for: TapStreamFormat(sampleRate: 24_000, isFloat: true, channels: 2, bitsPerChannel: 32)))
        #expect(a2dp.requiresRebuild(for: TapStreamFormat(sampleRate: 48_000, isFloat: false, channels: 2, bitsPerChannel: 16)))
        #expect(a2dp.requiresRebuild(for: TapStreamFormat(sampleRate: 48_000, isFloat: true, channels: 1, bitsPerChannel: 32)))
        #expect(!a2dp.requiresRebuild(for: TapStreamFormat(sampleRate: 0, isFloat: true, channels: 2, bitsPerChannel: 32)))
        var description = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let hfp = TapStreamFormat(description)
        #expect(hfp == TapStreamFormat(sampleRate: 16_000, isFloat: true, channels: 1, bitsPerChannel: 32))
        #expect(a2dp.requiresRebuild(for: hfp))
        description.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        description.mBytesPerPacket = 8
        #expect(!hfp.requiresRebuild(for: TapStreamFormat(description)))
        #expect(TapStreamFormat(sampleRate: 0, isFloat: true, channels: 1, bitsPerChannel: 32).effectiveSampleRate == 48_000)
    }

    @Test func watchdogStateCanBeResetAfterARecoveredTap() {
        var watchdog = AudioDeliveryWatchdog()
        #expect(watchdog.check(source: .remoteSystemAudio, lastReceivedAt: nil, startedAt: 0, now: 6) == .missing)
        watchdog.reset(.remoteSystemAudio)
        #expect(watchdog.check(source: .remoteSystemAudio, lastReceivedAt: 10, startedAt: 10, now: 12) == nil)
        #expect(watchdog.check(source: .remoteSystemAudio, lastReceivedAt: 10, startedAt: 10, now: 15) == .missing)
    }
}

private final class EventLog {
    var events: [RemoteTapEvent] = []
}

private final class FaultyDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: Int?
    private var failHeader = false

    func limit(to bytes: Int?) { lock.withLock { budget = bytes } }
    func failHeaderWrites(_ value: Bool) { lock.withLock { failHeader = value } }

    var io: WAVFileIO {
        let system = WAVFileIO.system
        return WAVFileIO(write: { [self] descriptor, bytes, offset in
            let allowed: Int = try lock.withLock {
                if offset == 0 {
                    if failHeader { throw WAVWriteError(code: EIO) }
                    return bytes.count
                }
                guard let budget else { return bytes.count }
                guard budget > 0 else { throw WAVWriteError(code: ENOSPC) }
                let count = min(budget, bytes.count)
                self.budget = budget - count
                return count
            }
            return try system.write(descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(allowed)), offset)
        }, synchronize: system.synchronize)
    }
}

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ values: [Value]) { lock.withLock { storage += values } }
    var values: [Value] { lock.withLock { storage } }
}

private func scratchURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mi-resilience-\(UUID().uuidString)-\(name)")
}

private func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length))))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

private func constant(_ values: ArraySlice<Float>, _ expected: Float) -> Bool {
    values.allSatisfy { abs($0 - expected) < 0.001 }
}

@Suite("Escritura WAV ante fallos de disco")
struct WAVWriteFailureTests {
    @Test func partialWriteNeverShiftsLaterSamples() throws {
        let url = scratchURL("partial.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = FaultyDisk()
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
        writer.io = disk.io
        disk.limit(to: 2 * 100 + 1)
        #expect(throws: WAVWriteError(code: ENOSPC)) { try writer.append([Float](repeating: 0.25, count: 300)) }
        #expect(writer.framesWritten == 100)
        disk.limit(to: nil)
        try writer.append([Float](repeating: -0.5, count: 200))
        try writer.close()
        let audio = try samples(url)
        #expect(audio.count == 300)
        #expect(constant(audio[..<100], 0.25) && constant(audio[100...], -0.5))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue == 44 + 600)
    }

    @Test func failedHeaderRewriteNeverMovesOrOverwritesAudio() throws {
        let url = scratchURL("header.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = FaultyDisk()
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000, flushIntervalSeconds: 0.01)
        writer.io = disk.io
        disk.failHeaderWrites(true)
        #expect(throws: WAVWriteError(code: EIO)) { try writer.append([Float](repeating: 0.5, count: 400)) }
        #expect(writer.framesWritten == 400)
        #expect(throws: WAVWriteError(code: EIO)) { try writer.append([Float](repeating: -0.25, count: 400)) }
        #expect(writer.framesWritten == 800)
        disk.failHeaderWrites(false)
        try writer.close()
        let audio = try samples(url)
        #expect(audio.count == 800)
        #expect(constant(audio[..<400], 0.5) && constant(audio[400...], -0.25))
    }

    @Test func silenceThatFailsHalfwayCountsOnlyTheFramesWritten() throws {
        let url = scratchURL("silence.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = FaultyDisk()
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
        writer.io = disk.io
        disk.limit(to: 2 * 20_000)
        #expect(throws: WAVWriteError(code: ENOSPC)) { try writer.appendSilence(frames: 48_000) }
        #expect(writer.framesWritten == 20_000)
        disk.limit(to: nil)
        try writer.append([Float](repeating: 0.5, count: 100))
        try writer.close()
        let audio = try samples(url)
        #expect(audio.count == 20_100)
        #expect(audio[..<20_000].allSatisfy { $0 == 0 } && constant(audio[20_000...], 0.5))
    }

    @Test func diskFullGapIsRefilledWithSilenceSoLaterAudioKeepsItsTimelinePosition() throws {
        let url = scratchURL("remote.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DispatchQueue(label: "mi.test.disk-full")
        let warnings = Collected<RecordingWarning>()
        let live = Collected<Float>()
        let recorder = try TrackRecorder(source: .remoteSystemAudio, url: url, outputSampleRate: 16_000, clock: CaptureClock(),
                                         queue: queue, onLevel: { _, _ in }, onWarning: { warnings.append([$0]) })
        recorder.onSamples = { _, block in live.append(block) }
        let disk = FaultyDisk()
        recorder.writer.io = disk.io
        let block = 8_000
        recorder.ingest([Float](repeating: 0.25, count: block), sampleRate: 16_000, hostTime: nil)
        queue.sync {}
        disk.limit(to: 2 * 1_500 + 1)
        recorder.ingest([Float](repeating: 0.5, count: block), sampleRate: 16_000, hostTime: nil)
        recorder.ingest([Float](repeating: 0.75, count: block), sampleRate: 16_000, hostTime: nil)
        queue.sync {}
        disk.limit(to: nil)
        recorder.ingest([Float](repeating: -0.5, count: block), sampleRate: 16_000, hostTime: nil)
        let stats = recorder.finish(atTimelineSeconds: 2)
        let audio = try samples(url)
        #expect(audio.count == 4 * block)
        #expect(abs(stats.durationSeconds - 2) < 0.0001)
        #expect(constant(audio[..<block], 0.25))
        #expect(constant(audio[block..<(block + 1_500)], 0.5))
        #expect(audio[(block + 1_500)..<(3 * block)].allSatisfy { $0 == 0 })
        #expect(constant(audio[(3 * block)...], -0.5))
        #expect(abs(stats.paddedSeconds - Double(2 * block - 1_500) / 16_000) < 0.0001)
        #expect(warnings.values == [.writeFailed(.remoteSystemAudio, "No queda espacio en el disco.")])
        #expect(live.values.count == 2 * block + 1_500)
    }
}

@Suite("Pausa del micrófono por posición en la línea de tiempo")
struct MicrophonePauseTimelineTests {
    @Test func pauseSilencesQueuedAudioFromTheClickedInstant() throws {
        let url = scratchURL("microphone.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DispatchQueue(label: "mi.test.pause")
        let recorder = try TrackRecorder(source: .localMicrophone, url: url, outputSampleRate: 16_000, clock: CaptureClock(),
                                         queue: queue, onLevel: { _, _ in }, onWarning: { _ in })
        let live = Collected<Float>()
        recorder.onSamples = { _, block in live.append(block) }
        queue.suspend()
        for _ in 0..<20 { recorder.ingest([Float](repeating: 0.5, count: 1_600), sampleRate: 16_000, hostTime: nil) }
        recorder.setMuted(true, atTimelineSeconds: 0.5)
        recorder.setMuted(true, atTimelineSeconds: 0.7)
        recorder.setMuted(false, atTimelineSeconds: 1.2)
        recorder.setMuted(true, atTimelineSeconds: 1.8)
        queue.resume()
        let stats = recorder.finish(atTimelineSeconds: 2)
        recorder.setMuted(false, atTimelineSeconds: 3)
        let audio = try samples(url)
        #expect(audio.count == 32_000)
        #expect(constant(audio[..<8_000], 0.5))
        #expect(audio[8_000..<19_200].allSatisfy { $0 == 0 })
        #expect(constant(audio[19_200..<28_800], 0.5))
        #expect(audio[28_800...].allSatisfy { $0 == 0 })
        #expect(live.values.count == 32_000)
        #expect(zip(live.values, audio).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(stats.pauses == [PauseInterval(start: 0.5, end: 1.2), PauseInterval(start: 1.8, end: 2)])
        #expect(recorder.finish(atTimelineSeconds: 2).pauses == stats.pauses)
    }
}
