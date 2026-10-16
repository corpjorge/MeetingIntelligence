public import CoreAudio
import Foundation

/// Thin, typed accessors over the Core Audio HAL property API.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T? {
        var addr = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: T) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: element, count: Int(size) / MemoryLayout<T>.size)
        let status = items.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? items : []
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func hostTimeToSeconds(_ hostTime: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
    }

    static func nowSeconds() -> Double {
        hostTimeToSeconds(AudioGetCurrentHostTime())
    }
}

/// An audio client process known to the HAL.
public struct AudioProcessInfo: Sendable, Hashable, Identifiable {
    public var id: AudioObjectID { objectID }
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let executablePath: String?
    public let isRunningOutput: Bool

    public var displayName: String {
        if let executablePath { return (executablePath as NSString).lastPathComponent }
        return bundleID ?? "PID \(pid)"
    }
}

public enum AudioProcessCatalog {
    /// Every process currently registered as an audio client.
    public static func allProcesses() -> [AudioProcessInfo] {
        HAL.array(HAL.systemObject, kAudioHardwarePropertyProcessObjectList, element: AudioObjectID(0)).compactMap { obj in
            guard let pid: pid_t = HAL.scalar(obj, kAudioProcessPropertyPID, default: 0) else { return nil }
            let running: UInt32 = HAL.scalar(obj, kAudioProcessPropertyIsRunningOutput, default: 0) ?? 0
            return AudioProcessInfo(objectID: obj, pid: pid,
                                    bundleID: HAL.string(obj, kAudioProcessPropertyBundleID),
                                    executablePath: executablePath(of: pid),
                                    isRunningOutput: running != 0)
        }
    }

    /// Microsoft Teams processes: matched by bundle ID prefix or by living inside
    /// the Teams app bundle (Teams plays call audio from helper processes whose
    /// bundle IDs are Edge WebView2's, e.g. `com.microsoft.edgewebview2.helper`).
    public static func teamsProcesses(in processes: [AudioProcessInfo] = allProcesses()) -> [AudioProcessInfo] {
        processes.filter(isTeams)
    }

    public static func isTeams(_ process: AudioProcessInfo) -> Bool {
        if let bundle = process.bundleID?.lowercased(),
           bundle.hasPrefix("com.microsoft.teams") {
            return true
        }
        if let path = process.executablePath,
           path.contains("/Microsoft Teams.app/") || path.contains("/Microsoft Teams classic.app/")
            || path.contains("/Microsoft Teams (work or school).app/") {
            return true
        }
        return false
    }

    public static func currentProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var addr = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(HAL.systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Transport of an audio device, used to warn about echo (speakers) and Bluetooth profiles.
public enum DeviceTransport: String, Sendable {
    case builtIn, bluetooth, bluetoothLE, usb, virtual, aggregate, airPlay, other

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        default: self = .other
        }
    }

    public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: AudioObjectID { deviceID }
    public let deviceID: AudioObjectID
    public let uid: String?
    public let name: String
    public let transport: DeviceTransport
    public let nominalSampleRate: Double?
    /// Data source name for built-in devices ("Internal Speakers", "Headphones").
    public let dataSourceName: String?

    /// True when output is likely audible to the microphone (echo risk).
    public var isLikelySpeakers: Bool {
        guard transport == .builtIn else { return false }
        if let source = dataSourceName?.lowercased() {
            return !(source.contains("headphone") || source.contains("auricular") || source.contains("audífono"))
        }
        return true
    }
}

public enum AudioDevices {
    public static func defaultInput() -> AudioDeviceInfo? {
        guard let id: AudioObjectID = HAL.scalar(HAL.systemObject, kAudioHardwarePropertyDefaultInputDevice, default: 0),
              id != kAudioObjectUnknown else { return nil }
        return info(id, scope: kAudioObjectPropertyScopeInput)
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        guard let id: AudioObjectID = HAL.scalar(HAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: 0),
              id != kAudioObjectUnknown else { return nil }
        return info(id, scope: kAudioObjectPropertyScopeOutput)
    }

    public static func info(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioDeviceInfo {
        let transport: UInt32 = HAL.scalar(id, kAudioDevicePropertyTransportType, default: 0) ?? 0
        let rate: Float64? = HAL.scalar(id, kAudioDevicePropertyNominalSampleRate, default: 0)
        var dataSourceName: String?
        if let source: UInt32 = HAL.scalar(id, kAudioDevicePropertyDataSource, scope: scope, default: 0) {
            dataSourceName = dataSourceNameFor(device: id, source: source, scope: scope)
        }
        return AudioDeviceInfo(deviceID: id,
                               uid: HAL.string(id, kAudioDevicePropertyDeviceUID),
                               name: HAL.string(id, kAudioObjectPropertyName) ?? "Dispositivo \(id)",
                               transport: DeviceTransport(code: transport),
                               nominalSampleRate: rate,
                               dataSourceName: dataSourceName)
    }

    private static func dataSourceNameFor(device: AudioObjectID, source: UInt32, scope: AudioObjectPropertyScope) -> String? {
        var addr = HAL.address(kAudioDevicePropertyDataSourceNameForIDCFString, scope: scope)
        var sourceID = source
        var name: Unmanaged<CFString>?
        let status: OSStatus = withUnsafeMutablePointer(to: &sourceID) { sourcePtr in
            withUnsafeMutablePointer(to: &name) { namePtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePtr), mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePtr), mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// Registers a HAL property listener and removes it on `invalidate()`/deinit.
final class HALPropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = HAL.address(selector)
        self.queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            self.block = block
        }
    }

    func invalidate() {
        if let block {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            self.block = nil
        }
    }

    deinit { invalidate() }
}
