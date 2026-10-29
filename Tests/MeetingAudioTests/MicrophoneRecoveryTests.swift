import Foundation
import MeetingCore
import Testing
@testable import MeetingAudio

@Suite("Micrófono: Bluetooth y recuperación")
struct MicrophoneRecoveryTests {
    func device(_ id: UInt32, transport: DeviceTransport) -> AudioDeviceInfo {
        AudioDeviceInfo(deviceID: id, uid: "device-\(id)", name: "Fixture \(id)", transport: transport,
                        nominalSampleRate: 48_000, dataSourceName: nil)
    }

    @Test func automaticSelectionAvoidsBluetoothWithoutChangingWiredDefault() {
        let bluetooth = device(1, transport: .bluetooth)
        let builtIn = device(2, transport: .builtIn)
        let usb = device(3, transport: .usb)
        #expect(AudioDevices.preferredRecordingInput(defaultInput: bluetooth, devices: [bluetooth, usb, builtIn]) == builtIn)
        #expect(AudioDevices.preferredRecordingInput(defaultInput: usb, devices: [bluetooth, usb, builtIn]) == usb)
        #expect(AudioDevices.preferredRecordingInput(defaultInput: bluetooth, devices: [bluetooth, usb]) == usb)
        #expect(AudioDevices.preferredRecordingInput(defaultInput: bluetooth, devices: [bluetooth]) == nil)
        #expect(AudioDevices.preferredRecordingInput(defaultInput: nil, devices: [builtIn]) == builtIn)
    }

    @Test func configurationStormCannotRestartMicrophoneIndefinitely() {
        var recovery = MicrophoneRecovery()
        let first = [recovery.permit(at: 10, lastBufferAt: 9.9),
                     recovery.permit(at: 10, lastBufferAt: nil),
                     recovery.permit(at: 11, lastBufferAt: nil),
                     recovery.permit(at: 12, lastBufferAt: nil)]
        #expect(first == [false, true, true, true])
        for t in 13..<40 {
            let allowed = recovery.permit(at: Double(t), lastBufferAt: nil)
            #expect(!allowed)
        }
        let afterWindow = recovery.permit(at: 40, lastBufferAt: nil)
        #expect(afterWindow)
    }

    @Test func noBufferWarningAndRecoveryArePerSourceAndNotConfusedWithSilence() {
        var monitor = AudioDeliveryWatchdog()
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: nil, startedAt: 100, now: 104) == nil)
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: nil, startedAt: 100, now: 105) == .missing)
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: nil, startedAt: 100, now: 110) == nil)
        #expect(monitor.check(source: .remoteSystemAudio, lastReceivedAt: 109, startedAt: 100, now: 110) == nil)
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: 110, startedAt: 100, now: 110) == .recovered)
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: 111, startedAt: 100, now: 111) == nil)
        #expect(monitor.check(source: .localMicrophone, lastReceivedAt: 111, startedAt: 100, now: 116) == .missing)
    }

    @Test func negotiatedInputRatesCanChangeWithoutDroppingAllMicrophoneAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-mic-format-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try TrackRecorder(source: .localMicrophone, url: root.appendingPathComponent("microphone.wav"),
                                         outputSampleRate: 16_000, clock: CaptureClock(), onLevel: { _, _ in }, onWarning: { _ in })
        #expect(recorder.lastReceivedHostTime == nil)
        recorder.ingest([Float](repeating: 0.2, count: 44_100), sampleRate: 44_100, hostTime: nil)
        recorder.ingest([Float](repeating: 0.2, count: 16_000), sampleRate: 16_000, hostTime: nil)
        let result = recorder.finish(atTimelineSeconds: 2)
        #expect(recorder.lastReceivedHostTime != nil)
        #expect(result.inputSampleRates == [44_100, 16_000])
        #expect(abs(result.durationSeconds - 2) < 0.05)
        #expect(StorageMaintenance.size(of: result.url) > 60_000)
    }
}
