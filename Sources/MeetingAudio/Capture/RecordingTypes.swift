public import Foundation
public import MeetingCore

public enum HostClock {
    /// Current host time in seconds (same clock as Core Audio buffer timestamps).
    public static func nowSeconds() -> Double { HAL.nowSeconds() }
}

/// What the remote track should capture.
public enum RemoteCaptureTarget: String, Sendable, Codable, CaseIterable {
    /// Only Microsoft Teams processes (default).
    case teams
    /// Every process except this app — chosen explicitly by the user.
    case systemWide
    /// No remote track (microphone only).
    case none
}

public struct RecordingConfiguration: Sendable {
    public var directory: URL
    public var remoteTarget: RemoteCaptureTarget
    public var captureMicrophone: Bool
    /// Apple voice processing (echo cancellation) on the microphone.
    public var microphoneVoiceProcessing: Bool
    public var outputSampleRate: Double

    public init(directory: URL, remoteTarget: RemoteCaptureTarget = .teams, captureMicrophone: Bool = true,
                microphoneVoiceProcessing: Bool = false, outputSampleRate: Double = 16_000) {
        self.directory = directory
        self.remoteTarget = remoteTarget
        self.captureMicrophone = captureMicrophone
        self.microphoneVoiceProcessing = microphoneVoiceProcessing
        self.outputSampleRate = outputSampleRate
    }
}

public enum RecordingWarning: Sendable, Equatable, Hashable {
    /// Output goes to built-in speakers: the microphone may pick up remote voices.
    case speakerEchoRisk(String)
    /// Bluetooth microphone (narrowband HFP profile likely).
    case bluetoothMicrophone(String)
    /// Teams has no audio process yet; the remote track starts when it appears.
    case waitingForTeamsAudio
    /// Capture scope is the whole system (not limited to Teams).
    case systemWideCapture
    /// Long run of exact digital silence (often a missing permission).
    case prolongedDigitalSilence(AudioSource)
    case inputDeviceChanged(String)
    case outputDeviceChanged(String)
    case remoteTapRebuilt(String)
    case writeFailed(AudioSource, String)
    case sourceFailed(AudioSource, String)

    public var message: String {
        switch self {
        case .speakerEchoRisk(let device):
            "El audio sale por \(device). El micrófono puede captar las voces remotas (eco). Se recomiendan audífonos."
        case .bluetoothMicrophone(let device):
            "Micrófono Bluetooth (\(device)): la calidad puede ser de banda estrecha."
        case .waitingForTeamsAudio:
            "Esperando audio de Microsoft Teams. La pista remota comenzará cuando Teams reproduzca audio."
        case .systemWideCapture:
            "Se está capturando el audio de TODO el sistema (excepto esta app), no solo de Teams."
        case .prolongedDigitalSilence(let source):
            source == .remoteSystemAudio
                ? "La pista remota está en silencio digital. Verifica el permiso 'Grabación de audio del sistema' y que la llamada esté activa."
                : "El micrófono entrega silencio digital. Verifica el permiso de micrófono y el dispositivo de entrada."
        case .inputDeviceChanged(let name): "Micrófono cambiado a \(name). La grabación continúa sincronizada."
        case .outputDeviceChanged(let name): "Salida de audio cambiada a \(name). Se reconfiguró la captura remota."
        case .remoteTapRebuilt(let reason): "Captura remota reconfigurada: \(reason)."
        case .writeFailed(let source, let error): "Error escribiendo \(source.rawValue): \(error)"
        case .sourceFailed(let source, let error): "Falló la fuente \(source.rawValue): \(error)"
        }
    }

    public var isCritical: Bool {
        switch self {
        case .writeFailed, .sourceFailed, .prolongedDigitalSilence: true
        default: false
        }
    }
}

public enum RecordingEvent: Sendable {
    case level(AudioSource, AudioLevel)
    case warning(RecordingWarning)
    /// Processes currently included in the remote tap (empty for system-wide/none).
    case remoteProcesses([AudioProcessInfo])
    case remoteScope(CaptureScope)
}

public struct RecordingResult: Sendable {
    public var durationSeconds: Double
    public var tracks: [TrackStatistics]
    public var captureScope: CaptureScope
    public var remoteProcessDescription: String?
    public var inputDeviceName: String?
    public var warnings: [RecordingWarning]
}
