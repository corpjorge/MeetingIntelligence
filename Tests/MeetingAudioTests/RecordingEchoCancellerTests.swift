import AVFoundation
import Foundation
import Testing
@testable import MeetingAudio
@testable import MeetingCore

@Suite("Cancelación de eco en la grabación")
struct RecordingEchoCancellerTests {
    private let rate = 16_000

    /// Broadband, repeatable, speech-band excitation. A single sine would not
    /// exercise identification of a room impulse response or double talk.
    private func speech(seed: UInt64, count: Int) -> [Float] {
        var state = seed
        var low: Float = 0
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1
            let white = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            low = 0.65 * low + 0.35 * white
            let envelope = Float(0.55 + 0.45 * sin(Double(i) * 2 * .pi * 3 / Double(rate)))
            return low * envelope * 0.5
        }
    }

    private func roomEcho(_ reference: [Float], delay: Int = 480) -> [Float] {
        reference.indices.map { i in
            var value: Float = 0
            for (offset, gain): (Int, Float) in [(delay, 0.5), (delay + 377, 0.2), (delay + 1_017, -0.12)] {
                if i >= offset { value += reference[i - offset] * gain }
            }
            return value
        }
    }

    private func run(microphone: [Float], reference: [Float], micFirst: Bool = true) throws -> [Float] {
        let canceller = try RecordingEchoCanceller(sampleRate: rate)
        var output: [Float] = []
        canceller.onOutput = { output += $0 }
        // Unequal callback sizes and either delivery order must retain alignment.
        var micPosition = 0, referencePosition = 0
        while micPosition < microphone.count || referencePosition < reference.count {
            func mic() {
                let end = min(microphone.count, micPosition + 1_365)
                canceller.appendMicrophone(Array(microphone[micPosition..<end]))
                micPosition = end
            }
            func remote() {
                let end = min(reference.count, referencePosition + 1_365)
                // Split the remote block into smaller device callbacks.
                for start in stride(from: referencePosition, to: end, by: 173) {
                    canceller.appendReference(Array(reference[start..<min(end, start + 173)]))
                }
                referencePosition = end
            }
            if micFirst { mic(); remote() } else { remote(); mic() }
        }
        canceller.finish()
        #expect(output.count == microphone.count)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        return output
    }

    private func power(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    }

    @Test(arguments: [true, false])
    func removesDelayedReverberantRemoteSpeech(micFirst: Bool) throws {
        let reference = speech(seed: 17, count: rate * 14 + 113)
        let microphone = roomEcho(reference)
        let output = try run(microphone: microphone, reference: reference, micFirst: micFirst)
        let steady = rate * 8..<rate * 13
        let reductionDB = 10 * log10(power(microphone[steady]) / max(1e-12, power(output[steady])))
        #expect(reductionDB > 20, "Echo reduction after convergence: \(reductionDB) dB")
    }

    @Test(arguments: [0, 5])
    func retainsLocalVoiceDuringDoubleTalk(localStartsAt seconds: Int) throws {
        let reference = speech(seed: 21, count: rate * 14)
        var local = speech(seed: 98, count: reference.count)
        for i in 0..<rate * seconds { local[i] = 0 }
        let echo = roomEcho(reference)
        let microphone = zip(local, echo).map(+)
        let output = try run(microphone: microphone, reference: reference)
        // Compare against the same DC-removal path without echo. The adaptive
        // filter should retain this voice, including when both speak at start.
        let baseline = try run(microphone: local, reference: [Float](repeating: 0, count: local.count))
        let region = rate * 7..<rate * 13
        let error = region.map { output[$0] - baseline[$0] }
        let signalToErrorDB = 10 * log10(power(baseline[region]) / max(1e-12, power(error[...])))
        let voiceEnergy = baseline[region].reduce(0.0) { $0 + Double($1) * Double($1) }
        let voiceGain = region.reduce(0.0) { $0 + Double(output[$1]) * Double(baseline[$1]) } / voiceEnergy
        #expect((0.9...1.1).contains(voiceGain), "Local voice gain: \(voiceGain)")
        if seconds > 0 {
            #expect(signalToErrorDB > 10, "Trained AEC during double talk: \(signalToErrorDB) dB")
        } else {
            // With uninterrupted double talk from the very first frame, Speex
            // prioritizes retaining local speech over rapid filter adaptation.
            #expect(power(error[...]) < power(echo[region]) * 0.6)
        }
    }

    @Test func preservesDigitalSilenceForMicrophonePausesAndGaps() throws {
        let reference = speech(seed: 3, count: rate * 8 + 119)
        var mic = roomEcho(reference)
        let pause = rate * 3 + 17..<rate * 6 + 73
        for i in pause { mic[i] = 0 }
        let output = try run(microphone: mic, reference: reference)
        #expect(output[pause].allSatisfy { $0 == 0 })
    }

    @Test func missingReferenceRetainsSpeechAndBoundsPendingAudio() throws {
        let canceller = try RecordingEchoCanceller(sampleRate: rate)
        let input = speech(seed: 3, count: rate * 4 + 57)
        var output: [Float] = [], warnings = 0
        canceller.onOutput = { output += $0 }
        canceller.onMissingReference = { warnings += 1 }
        for start in stride(from: 0, to: input.count, by: 713) {
            canceller.appendMicrophone(Array(input[start..<min(input.count, start + 713)]))
            #expect(canceller.pendingMicrophoneFrames < canceller.maximumPendingFrames)
        }
        canceller.finish()
        #expect(output == input)
        #expect(warnings == 1)
    }

    @Test(arguments: [0, 113])
    func finishPreservesSpeechWhenFutureReferenceEnds(partialFrames: Int) throws {
        let canceller = try RecordingEchoCanceller(sampleRate: rate)
        let reference = speech(seed: 17, count: rate * 2 + partialFrames)
        let local = speech(seed: 98, count: reference.count)
        let microphone = zip(roomEcho(reference), local).map(+)
        var output: [Float] = [], warnings = 0
        canceller.onOutput = { output += $0 }
        canceller.onMissingReference = { warnings += 1 }
        for start in stride(from: 0, to: microphone.count, by: 320) {
            let end = min(start + 320, microphone.count)
            canceller.appendReference(Array(reference[start..<end]))
            canceller.appendMicrophone(Array(microphone[start..<end]))
        }
        canceller.finish()
        #expect(output.count == microphone.count)
        #expect(Array(output.suffix(canceller.referenceLookahead)) == Array(microphone.suffix(canceller.referenceLookahead)))
        #expect(warnings == 0, "The normal end of both tracks is not a missing-source warning")
    }

    @Test func disconnectedMicrophoneDoesNotAccumulateRemoteAudio() throws {
        let canceller = try RecordingEchoCanceller(sampleRate: rate)
        for _ in 0..<1_000 { canceller.appendReference([Float](repeating: 0.1, count: 320)) }
        #expect(canceller.bufferedReferenceFrames <= rate * 2)
        #expect(canceller.pendingMicrophoneFrames == 0)
    }

    @Test func nearEndOnlyKeepsLevelAndTimeline() throws {
        let input = speech(seed: 91, count: rate * 3 + 71)
        let output = try run(microphone: input, reference: [Float](repeating: 0, count: input.count))
        let ratioDB = 10 * log10(power(output[rate...]) / power(input[rate...]))
        #expect(abs(ratioDB) < 1)
    }

    @Test func headphonesWithoutAcousticEchoDoNotSuppressLocalSpeech() throws {
        let input = speech(seed: 91, count: rate * 8 + 71)
        let output = try run(microphone: input, reference: speech(seed: 4, count: input.count))
        let baseline = try run(microphone: input, reference: [Float](repeating: 0, count: input.count))
        let region = rate * 2..<rate * 7
        let error = region.map { output[$0] - baseline[$0] }
        #expect(10 * log10(power(baseline[region]) / max(1e-12, power(error[...]))) > 15)
    }

    @Test func onlyProcessesRecordingsWithBothSources() {
        let url = FileManager.default.temporaryDirectory
        #expect(RecordingConfiguration(directory: url).usesRecordingEchoCancellation)
        #expect(!RecordingConfiguration(directory: url, remoteTarget: .none).usesRecordingEchoCancellation)
        #expect(!RecordingConfiguration(directory: url, captureMicrophone: false).usesRecordingEchoCancellation)
        #expect(!RecordingConfiguration(directory: url, microphoneEchoCancellation: false).usesRecordingEchoCancellation)
    }

    @Test func appleVoiceProcessingIsOptInAndNeverRunsAlongsideRecordingAEC() {
        let url = FileManager.default.temporaryDirectory
        #expect(!RecordingConfiguration(directory: url).usesAppleVoiceProcessing)
        let apple = RecordingConfiguration(directory: url, microphoneEchoCancellation: false, microphoneVoiceProcessing: true)
        #expect(apple.usesAppleVoiceProcessing && !apple.usesRecordingEchoCancellation)
        let conflicting = RecordingConfiguration(directory: url, microphoneEchoCancellation: true, microphoneVoiceProcessing: true)
        #expect(conflicting.usesRecordingEchoCancellation && !conflicting.usesAppleVoiceProcessing)
        let micOnly = RecordingConfiguration(directory: url, remoteTarget: .none,
                                             microphoneEchoCancellation: false, microphoneVoiceProcessing: true)
        #expect(micOnly.usesAppleVoiceProcessing && !micOnly.usesRecordingEchoCancellation)
        let remoteOnly = RecordingConfiguration(directory: url, captureMicrophone: false,
                                                microphoneEchoCancellation: false, microphoneVoiceProcessing: true)
        #expect(!remoteOnly.usesAppleVoiceProcessing && !remoteOnly.usesRecordingEchoCancellation)
    }

    @Test func writesCleanMicrophoneWAVAndFeedsTheSameAudioToLiveTranscription() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mi-aec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canceller = try RecordingEchoCanceller(sampleRate: rate)
        let queue = DispatchQueue(label: "mi.test.aec.tracks")
        let clock = CaptureClock()
        let live = EchoTestSamples()
        let micURL = directory.appendingPathComponent("microphone.wav")
        let remoteURL = directory.appendingPathComponent("remote.wav")
        let mic = try TrackRecorder(source: .localMicrophone, url: micURL, outputSampleRate: Double(rate), clock: clock,
                                    queue: queue, echoCanceller: canceller, onLevel: { _, _ in }, onWarning: { _ in })
        let remote = try TrackRecorder(source: .remoteSystemAudio, url: remoteURL, outputSampleRate: Double(rate), clock: clock,
                                       queue: queue, echoCanceller: canceller, onLevel: { _, _ in }, onWarning: { _ in })
        mic.onSamples = { _, samples in live.append(samples) }
        let reference = speech(seed: 44, count: rate * 12 + 107)
        let microphone = roomEcho(reference)
        for start in stride(from: 0, to: reference.count, by: 997) {
            let end = min(reference.count, start + 997)
            mic.ingest(Array(microphone[start..<end]), sampleRate: Double(rate), hostTime: nil)
            remote.ingest(Array(reference[start..<end]), sampleRate: Double(rate), hostTime: nil)
        }
        let duration = Double(reference.count) / Double(rate)
        _ = remote.finish(atTimelineSeconds: duration)
        let stats = mic.finish(atTimelineSeconds: duration)
        let saved = try read(micURL), savedRemote = try read(remoteURL)
        #expect(saved.count == reference.count && savedRemote.count == reference.count)
        #expect(abs(stats.durationSeconds - duration) < 1 / Double(rate))
        #expect(zip(saved, live.samples).allSatisfy { abs($0 - $1) < 0.00004 })
        #expect(live.samples.count == saved.count)
        #expect(zip(reference, savedRemote).allSatisfy { abs($0 - $1) < 0.00004 })
        let steady = rate * 7..<rate * 11
        #expect(10 * log10(power(microphone[steady]) / max(1e-12, power(saved[steady]))) > 20)
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

private final class EchoTestSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    func append(_ samples: [Float]) { lock.withLock { storage += samples } }
    var samples: [Float] { lock.withLock { storage } }
}
