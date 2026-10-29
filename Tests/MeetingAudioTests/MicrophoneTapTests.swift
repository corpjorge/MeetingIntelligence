import AVFoundation
import Foundation
import Testing
@testable import MeetingAudio

@Suite("Micrófono: formato nativo tras cambiar de dispositivo")
struct MicrophoneTapTests {
    // Manual input supplies only synthetic data; these tests never open a microphone.
    @Test(arguments: [(48_000.0, 1, 16_000.0, 1), (16_000.0, 1, 48_000.0, 2), (44_100.0, 2, 16_000.0, 1)])
    func tapReplacesStaleClientRateAndChannels(hardwareRate: Double, hardwareChannels: Int,
                                              previousRate: Double, previousChannels: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mi-mic-tap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try TrackRecorder(source: .localMicrophone, url: directory.appendingPathComponent("mic.wav"),
                                         outputSampleRate: 16_000, clock: CaptureClock(), onLevel: { _, _ in }, onWarning: { _ in })
        defer { _ = recorder.finish(atTimelineSeconds: 0) }
        let hardware = try #require(AVAudioFormat(standardFormatWithSampleRate: hardwareRate,
                                                channels: AVAudioChannelCount(hardwareChannels)))
        let stale = try #require(AVAudioFormat(standardFormatWithSampleRate: previousRate,
                                             channels: AVAudioChannelCount(previousChannels)))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 4096)
        let input = engine.inputNode
        #expect(input.setManualRenderingInputPCMFormat(hardware) { _ in nil })
        input.installTap(onBus: 0, bufferSize: 4096, format: stale) { _, _ in }
        #expect(input.outputFormat(forBus: 0).sampleRate == previousRate)
        input.removeTap(onBus: 0)
        #expect(input.outputFormat(forBus: 0).sampleRate == previousRate)

        try MicrophoneTap.install(on: input, recorder: recorder)
        defer { input.removeTap(onBus: 0) }
        let installed = input.outputFormat(forBus: 0)
        #expect(installed.sampleRate == hardwareRate)
        #expect(installed.channelCount == hardwareChannels)
        #expect(input.inputFormat(forBus: 0).sampleRate == hardwareRate)
        #expect(!engine.isRunning)
        #expect(recorder.lastReceivedHostTime == nil)
    }
}
