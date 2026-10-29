public import Foundation

public enum CaptureError: LocalizedError, Sendable, Equatable {
    case microphonePermissionDenied
    case noInputDevice
    case inputDeviceUnavailable
    case appNotProducingAudio
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case fileCreationFailed(String)
    case unreadableRecording(String)
    case alreadyRecording
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Sin permiso de micrófono. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
        case .noInputDevice:
            "No hay un micrófono disponible."
        case .inputDeviceUnavailable:
            "El micrófono elegido ya no está disponible. Vuelve a conectarlo o selecciona otro; no se cambiará automáticamente a tus audífonos."
        case .appNotProducingAudio:
            "La aplicación elegida no está reproduciendo audio en este momento. Abre la llamada o elige capturar el audio del sistema."
        case .tapCreationFailed(let s):
            "No se pudo crear el tap de audio de procesos (OSStatus \(s)). Verifica el permiso 'Grabación de audio del sistema'."
        case .aggregateDeviceFailed(let s):
            "No se pudo crear el dispositivo agregado de captura (OSStatus \(s))."
        case .deviceStartFailed(let s):
            "No se pudo iniciar la captura (OSStatus \(s))."
        case .coreAudio(let op, let s):
            "Error de Core Audio en \(op) (OSStatus \(s))."
        case .unsupportedFormat(let detail):
            "Formato de audio no soportado: \(detail)."
        case .fileCreationFailed(let path):
            "No se pudo crear el archivo \(path)."
        case .unreadableRecording(let path):
            "No se pudo leer la grabación \(path)."
        case .alreadyRecording:
            "Ya hay una grabación en curso."
        case .notRecording:
            "No hay una grabación en curso."
        }
    }
}
