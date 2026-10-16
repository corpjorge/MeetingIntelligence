import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures the audio output of selected processes with a Core Audio process
/// tap (macOS 14.2+), read through a private aggregate device.
///
/// Teams mode taps only Microsoft Teams processes (by object ID). The tap is
/// rebuilt when the set of Teams audio processes or the default output device
/// changes; the `TrackRecorder` pads the short gap so the track stays aligned.
final class ProcessTapSource: @unchecked Sendable {
    enum Target: Equatable {
        case processes([AudioObjectID])
        case systemWideExcluding([AudioObjectID])
    }

    private let recorder: TrackRecorder
    private let queue = DispatchQueue(label: "mi.tap.control")
    private let ioQueue = DispatchQueue(label: "mi.tap.io", qos: .userInteractive)
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "process-tap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var currentTarget: Target?
    private var tapIsFloat = true
    private var tapSampleRate: Double = 48_000

    init(recorder: TrackRecorder) {
        self.recorder = recorder
    }

    var isRunning: Bool { queue.sync { ioProcID != nil } }

    func start(target: Target) throws {
        try queue.sync { try startLocked(target: target) }
    }

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

    var target: Target? { queue.sync { currentTarget } }

    private func startLocked(target: Target) throws {
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
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.aggregateDeviceFailed(status)
        }
        aggregateID = newAggregate

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = HAL.address(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard status == noErr else {
            teardownDevices()
            throw CaptureError.coreAudio("formato del tap", status)
        }
        tapIsFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        tapSampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let sampleRate = tapSampleRate
        let isFloat = tapIsFloat
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
        currentTarget = target
        logger.info("Tap started: \(String(describing: target), privacy: .public) @ \(sampleRate) Hz float=\(isFloat)")
    }

    private func stopLocked() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        teardownDevices()
        currentTarget = nil
    }

    private func teardownDevices() {
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
