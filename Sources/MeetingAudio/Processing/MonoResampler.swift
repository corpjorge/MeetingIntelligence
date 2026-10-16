@preconcurrency public import AVFoundation

/// Streaming sample-rate converter for mono Float32 audio (e.g. 48 kHz → 16 kHz).
///
/// Keeps AVAudioConverter state across calls (the input block answers
/// `.noDataNow`, never `.endOfStream`) so consecutive buffers are filtered
/// continuously without edge artifacts. Confine to one serial queue.
public final class MonoResampler {
    public let inputRate: Double
    public let outputRate: Double
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    public init(inputRate: Double, outputRate: Double) throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)
        else { throw CaptureError.unsupportedFormat("mono \(inputRate) → \(outputRate)") }
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.inputFormat = input
        self.outputFormat = output
        if inputRate == outputRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: input, to: output) else {
                throw CaptureError.unsupportedFormat("conversor \(inputRate) → \(outputRate)")
            }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = c
        }
    }

    public func process(_ samples: [Float]) throws -> [Float] {
        guard let converter else { return samples }
        guard !samples.isEmpty else { return [] }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CaptureError.unsupportedFormat("buffer")
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * outputRate / inputRate) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.unsupportedFormat("buffer")
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw error ?? CaptureError.unsupportedFormat("resample")
        }
        let n = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: n))
    }
}

public enum Downmix {
    /// Averages the channels of an AVAudioPCMBuffer (float or int16) into mono Float32.
    public static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        if let data = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let p = data[0]
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[f * channels + c] }
                    out[f] = sum / Float(channels)
                }
            } else {
                for c in 0..<channels {
                    let p = data[c]
                    for f in 0..<frames { out[f] += p[f] }
                }
                if channels > 1 { for f in 0..<frames { out[f] /= Float(channels) } }
            }
        } else if let data = buffer.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            if buffer.format.isInterleaved {
                let p = data[0]
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(p[f * channels + c]) }
                    out[f] = sum * scale / Float(channels)
                }
            } else {
                for c in 0..<channels {
                    let p = data[c]
                    for f in 0..<frames { out[f] += Float(p[f]) * scale }
                }
                if channels > 1 { for f in 0..<frames { out[f] /= Float(channels) } }
            }
        }
        return out
    }

    /// Mixes raw Core Audio buffers (as delivered by a HAL IOProc) to mono Float32.
    /// Handles both one interleaved buffer and N non-interleaved mono buffers.
    public static func mono(bufferList: UnsafeMutableAudioBufferListPointer, isFloat: Bool) -> [Float] {
        guard isFloat else { return [] }
        let buffers = bufferList.filter { $0.mData != nil && $0.mDataByteSize > 0 }
        guard let first = buffers.first else { return [] }
        let firstChannels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        var totalChannels = 0
        for buffer in buffers {
            let ch = Int(max(1, buffer.mNumberChannels))
            let n = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch))
            let p = buffer.mData!.assumingMemoryBound(to: Float.self)
            for f in 0..<n {
                var sum: Float = 0
                for c in 0..<ch { sum += p[f * ch + c] }
                out[f] += sum
            }
            totalChannels += ch
        }
        if totalChannels > 1 {
            let scale = 1 / Float(totalChannels)
            for f in 0..<frames { out[f] *= scale }
        }
        return out
    }
}
