import CoreAudio
import Foundation
import MeetingCore

protocol RemoteAudioTap: AnyObject {
    var isRunning: Bool { get }
    func rebuild(target: ProcessTapSource.Target) throws
    func stop()
}

struct TapRetryPolicy: Equatable {
    var initialDelay = 1.0
    var maximumDelay = 30.0
    private(set) var failures = 0
    private(set) var nextAttemptAt: Double?

    mutating func recordFailure(at now: Double) -> Double {
        let delay = min(maximumDelay, initialDelay * Double(1 << min(failures, 16)))
        failures += 1
        nextAttemptAt = now + delay
        return delay
    }

    mutating func reset() {
        failures = 0
        nextAttemptAt = nil
    }

    func isDue(at now: Double) -> Bool {
        guard let nextAttemptAt else { return false }
        return now >= nextAttemptAt
    }
}

enum RemoteTapEvent: Equatable {
    case warning(RecordingWarning)
    case processes([AudioProcessInfo])
    case recovered(RecordingWarning?)
    case retryScheduled(Double)
}

final class RemoteTapSupervisor {
    private let tap: any RemoteAudioTap
    private let now: () -> Double
    var onEvent: (RemoteTapEvent) -> Void = { _ in }
    private(set) var desired: ProcessTapSource.Target?
    private var desiredProcesses: [AudioProcessInfo] = []
    private(set) var tappedProcesses: [AudioProcessInfo] = []
    private(set) var retry = TapRetryPolicy()
    private(set) var isFailing = false
    private(set) var lastStartedAt: Double?
    private var outage: RecordingWarning?

    init(tap: any RemoteAudioTap, now: @escaping () -> Double = HostClock.nowSeconds) {
        self.tap = tap
        self.now = now
    }

    func start(_ target: ProcessTapSource.Target, processes: [AudioProcessInfo] = []) throws {
        desired = target
        desiredProcesses = processes
        try tap.rebuild(target: target)
        tappedProcesses = processes
        lastStartedAt = now()
    }

    func processesChanged(_ processes: [AudioProcessInfo], appName: String) {
        guard Self.ids(processes) != Self.ids(desiredProcesses) else {
            retryIfDue()
            return
        }
        desiredProcesses = processes
        retry.reset()
        guard !processes.isEmpty else {
            desired = nil
            isFailing = false
            tap.stop()
            tappedProcesses = []
            onEvent(.processes([]))
            onEvent(.warning(.waitingForAppAudio(appName)))
            return
        }
        desired = .processes(processes.map(\.objectID))
        attempt(reporting: .remoteTapRebuilt("procesos de \(appName) actualizados (\(processes.count))"))
    }

    func outputDeviceChanged(_ name: String) {
        guard desired != nil else { return }
        retry.reset()
        attempt(reporting: .outputDeviceChanged(name))
    }

    func formatChanged(sampleRate: Double) {
        guard desired != nil, !isFailing else { return }
        attempt(reporting: .remoteTapRebuilt("la salida de audio cambió a \(Int(sampleRate.rounded())) Hz"))
    }

    func retryIfDue() {
        guard desired != nil, isFailing, retry.isDue(at: now()) else { return }
        attempt(reporting: .remoteTapRebuilt("se restableció la captura remota"))
    }

    func stop() {
        desired = nil
        isFailing = false
        retry.reset()
        tap.stop()
    }

    private func attempt(reporting success: RecordingWarning) {
        guard let desired else { return }
        do {
            try tap.rebuild(target: desired)
        } catch {
            isFailing = true
            let delay = retry.recordFailure(at: now())
            if outage == nil {
                let warning = RecordingWarning.sourceFailed(
                    .remoteSystemAudio, "\(error.localizedDescription) Se reintentará automáticamente.")
                outage = warning
                onEvent(.warning(warning))
            }
            onEvent(.retryScheduled(delay))
            return
        }
        isFailing = false
        retry.reset()
        lastStartedAt = now()
        if case .processes = desired, Self.ids(tappedProcesses) != Self.ids(desiredProcesses) {
            tappedProcesses = desiredProcesses
            onEvent(.processes(desiredProcesses))
        }
        if let outage {
            self.outage = nil
            onEvent(.recovered(outage))
        }
        onEvent(.warning(success))
    }

    private static func ids(_ processes: [AudioProcessInfo]) -> Set<AudioObjectID> {
        Set(processes.map(\.objectID))
    }
}
