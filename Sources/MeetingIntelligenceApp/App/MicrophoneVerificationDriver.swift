import Foundation
import MeetingAudio
import MeetingCore

/// Explicit, opt-in three-second physical mic test. Requires a temporary library,
/// never records system audio, and never initializes transcription or cloud AI.
enum MicrophoneVerificationDriver {
    static func isTemporaryLibrary(_ path: String) -> Bool {
        // Foundation preserves /private for nonexistent descendants, but strips
        // it for existing paths. Both spellings refer to the same macOS tmp root.
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/")
    }

    static func run(env: AppEnvironment, directory: URL) async {
        guard let override = ProcessInfo.processInfo.environment[AppPaths.environmentOverrideKey],
              isTemporaryLibrary(override) else { return }
        var report: [String: Any] = [:]
        do {
            guard let microphone = AudioDevices.inputDevices().first(where: { $0.transport == .builtIn }),
                  let uid = microphone.uid else { throw CaptureError.noInputDevice }
            var permitted = RecordingSession.microphonePermissionGranted()
            if !permitted { permitted = await RecordingSession.requestMicrophonePermission() }
            guard permitted else {
                throw CaptureError.microphonePermissionDenied
            }
            let folder = env.paths.root.appendingPathComponent("physical-microphone-test")
            let session = RecordingSession(configuration: RecordingConfiguration(directory: folder, remoteTarget: .none,
                                                                                microphoneEchoCancellation: false,
                                                                                microphoneDeviceUID: uid))
            let started = Date()
            try await session.startAsync()
            report["startupSeconds"] = Date().timeIntervalSince(started)
            try await Task.sleep(for: .seconds(3))
            let result = await session.stopAsync()
            let track = result.tracks.first(where: { $0.source == .localMicrophone })
            report["device"] = result.inputDeviceName
            report["durationSeconds"] = result.durationSeconds
            report["inputSampleRates"] = track?.inputSampleRates ?? []
            report["fileBytes"] = track.map { StorageMaintenance.size(of: $0.url) } ?? 0
            report["remoteTracks"] = result.tracks.filter { $0.source == .remoteSystemAudio }.count
            report["success"] = track?.inputSampleRates.isEmpty == false
                && (track.map { StorageMaintenance.size(of: $0.url) } ?? 0) > 44
        } catch {
            report["success"] = false
            report["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("microphone-verification.json"))
        }
    }
}
