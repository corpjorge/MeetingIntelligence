public import Foundation
public import MeetingCore

public enum HostClock {
    /// Current host time in seconds (same clock as Core Audio buffer timestamps).
    public static func nowSeconds() -> Double { HAL.nowSeconds() }
}

/// What the remote track should capture.
public enum RemoteCaptureTarget: Sendable, Hashable {
    /// Only the processes of one app (any conversation app: Teams, Zoom, a browser…).
    case application(AudioAppSelector)
    /// Every process except this app — chosen explicitly by the user.
    case systemWide
    /// No remote track (microphone only).
    case none
}

/// One span of a track that was paused on purpose (timeline seconds).
public struct PauseInterval: Sendable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct RecordingConfiguration: Sendable {
    public var directory: URL
    public var remoteTarget: RemoteCaptureTarget
    public var captureMicrophone: Bool
    /// Recording-only software AEC; requires both microphone and remote audio.
    public var microphoneEchoCancellation: Bool
    /// Optional Apple VPIO. Off by default; recording AEC takes precedence if
    /// conflicting options are supplied by a caller.
    public var microphoneVoiceProcessing: Bool
    public var outputSampleRate: Double

    var usesRecordingEchoCancellation: Bool {
        microphoneEchoCancellation && captureMicrophone && remoteTarget != .none
    }

    var usesAppleVoiceProcessing: Bool {
        captureMicrophone && microphoneVoiceProcessing && !microphoneEchoCancellation
    }

    public init(directory: URL, remoteTarget: RemoteCaptureTarget = .systemWide, captureMicrophone: Bool = true,
                microphoneEchoCancellation: Bool = true, microphoneVoiceProcessing: Bool = false,
                outputSampleRate: Double = 16_000) {
        self.directory = directory
        self.remoteTarget = remoteTarget
        self.captureMicrophone = captureMicrophone
        self.microphoneEchoCancellation = microphoneEchoCancellation
        self.microphoneVoiceProcessing = microphoneVoiceProcessing
        self.outputSampleRate = outputSampleRate
    }
}

public enum RecordingWarning: Sendable, Equatable, Hashable {
    /// Output goes to built-in speakers: the microphone may pick up remote voices.
    case speakerEchoRisk(String)
    /// Bluetooth microphone (narrowband HFP profile likely).
    case bluetoothMicrophone(String)
    /// The chosen app has no audio process yet; the remote track starts when it appears.
    case waitingForAppAudio(String)
    /// The app's audio comes from a shared process (browser tabs, WebKit, system daemon).
    case sharedProcessCapture(String)
    /// Capture scope is the whole system (not limited to one app).
    case systemWideCapture
    /// Long run of exact digital silence (often a missing permission).
    case prolongedDigitalSilence(AudioSource)
    /// The reference stream is too late/missing; retain microphone speech.
    case echoReferenceUnavailable
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
        case .waitingForAppAudio(let app):
            "Esperando audio de \(app). La pista remota comenzará cuando \(app) reproduzca audio (se mantiene sincronizada)."
        case .sharedProcessCapture(let app):
            "\(app) reproduce el audio desde un proceso compartido: se grabará todo lo que suene en \(app) (por ejemplo, otras pestañas)."
        case .systemWideCapture:
            "Se está capturando el audio de TODO el sistema (excepto esta app), no solo de una aplicación."
        case .prolongedDigitalSilence(let source):
            source == .remoteSystemAudio
                ? "La pista remota está en silencio digital. Verifica el permiso 'Grabación de audio del sistema' y que la llamada esté activa."
                : "El micrófono entrega silencio digital. Verifica el permiso de micrófono y el dispositivo de entrada."
        case .echoReferenceUnavailable:
            "No llega a tiempo el audio remoto para reducir el eco. Tu micrófono sigue grabándose, pero puede contener voces de los altavoces."
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

/// Static reminder for a verified limitation (TD-23): muting yourself in the call
/// app does not pause the local microphone track, and no public API reveals
/// another app's mute state. It never pauses or resumes anything by itself.
public enum CallMuteReminder {
    /// Shown while the microphone is written during a recording that also captures a call.
    public static func isRelevant(capturesMicrophone: Bool, capturesRemoteAudio: Bool,
                                  microphonePaused: Bool, dismissed: Bool) -> Bool {
        capturesMicrophone && capturesRemoteAudio && !microphonePaused && !dismissed
    }

    public static func title(appName: String?) -> String {
        "Silenciarte en \(appName ?? "la llamada") no pausa tu micrófono aquí"
    }

    public static func message(appName: String?) -> String {
        "Meeting Intelligence no puede saber si estás silenciado en \(appName ?? "la llamada") y sigue grabando tu "
            + "micrófono. Para que no se grabe lo que digas, usa «Pausar mi micrófono» (⌃⌘M)."
    }
}

public enum RecordingEvent: Sendable {
    case level(AudioSource, AudioLevel)
    case warning(RecordingWarning)
    /// Processes currently included in the remote tap (empty for system-wide/none).
    case remoteProcesses([AudioProcessInfo])
    case microphonePaused(Bool)
    case remoteScope(CaptureScope)
}

public struct RecordingResult: Sendable {
    public var durationSeconds: Double
    public var tracks: [TrackStatistics]
    public var captureScope: CaptureScope
    public var remoteProcessDescription: String?
    public var inputDeviceName: String?
    public var warnings: [RecordingWarning]
    /// App recorded on the remote track (nil for system-wide / microphone only).
    public var sourceApp: AudioAppSelector?
    /// Spans where the user paused their microphone (silence written, timeline kept).
    public var microphonePauses: [PauseInterval]
}
