import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import MeetingAudio

@Suite("Micrófono: captura directa y cancelación")
struct DeviceMicrophoneCaptureTests {
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0], [true, false])
    func sampleDecoderPreservesRateStereoAndHostClock(rate: Double, interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                              channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        for i in 0..<100 {
            if interleaved { buffer.floatChannelData![0][i * 2] = 0.2; buffer.floatChannelData![0][i * 2 + 1] = 0.6 }
            else { buffer.floatChannelData![0][i] = 0.2; buffer.floatChannelData![1][i] = 0.6 }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: CMTime(seconds: 100, preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                          formatDescription: format.formatDescription, sampleCount: 100,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let ready = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(ready, blockBufferAllocator: kCFAllocatorDefault,
                                                              blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                              flags: 0, bufferList: buffer.audioBufferList) == noErr)
        let decoded = try MicrophoneSampleDecoder.decode(ready, clock: CMClockGetHostTimeClock())
        #expect(decoded.sampleRate == rate && decoded.samples.count == 100)
        #expect(decoded.samples.allSatisfy { abs($0 - 0.4) < 0.0001 })
        #expect(abs(HAL.hostTimeToSeconds(try #require(decoded.hostTime)) - 100) < 0.0001)
    }

    @Test func cancelledStartupDoesNotOpenDevicesOrCreateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-cancelled-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(configuration: RecordingConfiguration(directory: root, captureMicrophone: true))
        session.requestStartCancellation()
        do { try await session.startAsync(); Issue.record("Cancelled start unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        _ = await session.stopAsync()
    }
}
