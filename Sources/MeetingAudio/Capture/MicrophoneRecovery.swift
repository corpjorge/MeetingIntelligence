import Foundation

/// Bounds HAL recovery so a device negotiating its Bluetooth profile cannot
/// trigger an endless stop/start cycle. Pure policy, exercised without hardware.
struct MicrophoneRecovery {
    private var attempts: [Double] = []
    var maximumAttempts = 3
    var windowSeconds = 30.0

    mutating func permit(at now: Double, lastBufferAt: Double?) -> Bool {
        if let lastBufferAt, now - lastBufferAt < 1 { return false }
        attempts.removeAll { now - $0 >= windowSeconds }
        guard attempts.count < maximumAttempts else { return false }
        attempts.append(now)
        return true
    }
}
