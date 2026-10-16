import Foundation
import Accelerate

public struct AudioLevel: Sendable, Equatable {
    /// RMS level in dBFS (−160 for digital silence).
    public var rmsDB: Float
    /// Peak level in dBFS.
    public var peakDB: Float

    public static let silence = AudioLevel(rmsDB: -160, peakDB: -160)

    /// 0…1 value suitable for meters (−60 dBFS floor).
    public var normalized: Double {
        Double(max(0, min(1, (rmsDB + 60) / 60)))
    }
}

public enum LevelMeter {
    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard let base = samples.baseAddress, !samples.isEmpty else { return .silence }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        return AudioLevel(rmsDB: toDB(rms), peakDB: toDB(peak))
    }

    public static func measure(_ samples: [Float]) -> AudioLevel {
        samples.withUnsafeBufferPointer { measure($0) }
    }

    static func toDB(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(-160, 20 * log10(amplitude)) : -160
    }
}
