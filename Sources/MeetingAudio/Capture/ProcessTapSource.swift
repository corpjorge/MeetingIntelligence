import AVFoundation
import CoreAudio
import Foundation
import OSLog

struct TapStreamFormat: Equatable {
    var sampleRate: Double
    var isFloat: Bool
    var channels: UInt32
    var bitsPerChannel: UInt32

    init(sampleRate: Double, isFloat: Bool, channels: UInt32, bitsPerChannel: UInt32) {
        self.sampleRate = sampleRate
        self.isFloat = isFloat
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
    }

    init(_ description: AudioStreamBasicDescription) {
        self.init(sampleRate: description.mSampleRate,
                  isFloat: (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                  channels: description.mChannelsPerFrame,
                  bitsPerChannel: description.mBitsPerChannel)
    }

    var effectiveSampleRate: Double { sampleRate > 0 ? sampleRate : 48_000 }

    func requiresRebuild(for reported: TapStreamFormat) -> Bool {
        reported.sampleRate.isFinite && reported.sampleRate > 0 && reported != self
    }
}

/// Captures the audio output of selected processes with a Core Audio process
/// tap (macOS 14.2+), read through a private aggregate device.
///
/// Teams mode taps only Microsoft Teams processes (by object ID). The tap is
/// rebuilt when the set of Teams audio processes or the default output device
/// changes; the `TrackRecorder` pads the short gap so the track stays aligned.
final class ProcessTapSource: RemoteAudioTap, @unchecked Sendable {
    enum Target: Equatable {
        case processes([AudioObjectID])
        case systemWideExcluding([AudioObjectID])
    }

    private let recorder: TrackRecorder
    private let onFormatChange: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "mi.tap.control")
    private let ioQueue = DispatchQueue(label: "mi.tap.io", qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "process-tap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatListener: HALPropertyListener?
    private var runningFormat: TapStreamFormat?
    private var generation = 0
    private var formatChangeReported = false

    init(recorder: TrackRecorder, onFormatChange: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.recorder = recorder
        self.onFormatChange = onFormatChange
    }

    var isRunning: Bool { queue.sync { ioProcID != nil } }

    /// Rebuilds the tap for a new target (e.g. a new Teams helper process).
    func rebuild(target: Target) throws {
        try queue.sync {
            stopLocked()
            try startLocked(target: target)
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func startLocked(target: Target) throws {
        generation += 1
        formatChangeReported = false
        let generation = self.generation
        let description: CATapDescription
        switch target {
        case .processes(let ids):
            description = CATapDescription(monoMixdownOfProcesses: ids)
        case .systemWideExcluding(let ids):
            description = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        }
        description.name = "Meeting Intelligence Remote Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(status)
        }
        tapID = newTap
        formatListener = HALPropertyListener(object: newTap, selector: kAudioTapPropertyFormat, queue: queue) { [weak self] in
            self?.tapFormatChanged(generation: generation)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Intelligence Capture",
            kAudioAggregateDeviceUIDKey: "dev.meetingintelligence.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate != kAudioObjectUnknown else {
            teardownDevices()
            throw CaptureError.aggregateDeviceFailed(status)
        }
        aggregateID = newAggregate

        let format: TapStreamFormat
        do { format = try Self.readFormat(of: tapID) } catch {
            teardownDevices()
            throw error
        }
        runningFormat = format
        let sampleRate = format.effectiveSampleRate
        let isFloat = format.isFloat
        let recorder = self.recorder

        let block: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let mono = Downmix.mono(bufferList: list, isFloat: isFloat)
            guard !mono.isEmpty else { return }
            let ts = inputTime.pointee
            let hostTime: UInt64? = ts.mFlags.contains(.hostTimeValid) && ts.mHostTime != 0 ? ts.mHostTime : nil
            recorder.ingest(mono, sampleRate: sampleRate, hostTime: hostTime)
        }
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block)
        guard status == noErr, let procID else {
            teardownDevices()
            throw CaptureError.coreAudio("IOProc", status)
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            teardownDevices()
            throw CaptureError.deviceStartFailed(status)
        }
        logger.info("Tap started: \(String(describing: target), privacy: .public) @ \(sampleRate) Hz float=\(isFloat)")
    }

    private static func readFormat(of tap: AudioObjectID) throws -> TapStreamFormat {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = HAL.address(kAudioTapPropertyFormat)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureError.coreAudio("formato del tap", status) }
        return TapStreamFormat(format)
    }

    private func tapFormatChanged(generation: Int) {
        guard generation == self.generation, ioProcID != nil, !formatChangeReported,
              let running = runningFormat, let reported = try? Self.readFormat(of: tapID),
              running.requiresRebuild(for: reported) else { return }
        formatChangeReported = true
        logger.notice("Tap format changed: \(running.sampleRate) Hz → \(reported.sampleRate) Hz float=\(reported.isFloat)")
        onFormatChange(reported.sampleRate)
    }

    private func stopLocked() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        teardownDevices()
    }

    private func teardownDevices() {
        formatListener?.invalidate()
        formatListener = nil
        runningFormat = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stopLocked()
    }
}
