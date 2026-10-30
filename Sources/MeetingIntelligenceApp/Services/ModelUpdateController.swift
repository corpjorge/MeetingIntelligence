import Foundation
import MeetingCore
import MeetingSpeech
import OSLog

/// In-app model versions (TD-27): sizes, update checks on demand, safe updates and
/// removal of models the app does not use. Hugging Face is contacted only when the
/// user presses "Buscar actualizaciones" or "Actualizar".
@Observable
final class ModelUpdateController {
    enum State: Equatable {
        case unchecked
        case checking
        case notInstalled
        case upToDate(String)
        case available(ModelUpdatePlan)
        case pinned(String)
        case updating(Double?)
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        var model: ManagedModel
        var bytes: Int64
        var state: State
        var id: String { model.id }
    }

    private(set) var rows: [Row] = []
    private(set) var unusedFolders: [UnusedModelFolder] = []
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var updatingIds: Set<String> = []
    var blockedReason: String?

    private let asr: ParakeetUltraProvider
    private let diarizer: DiarizationService
    private let booster: AcousticVocabularyBooster
    private let semantic: SemanticIndexController
    private let settings: AppSettings
    private let processing: ProcessingCoordinator
    private let recording: RecordingController
    private let installer = ModelInstaller()
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "models")

    init(asr: ParakeetUltraProvider, diarizer: DiarizationService, booster: AcousticVocabularyBooster,
         semantic: SemanticIndexController, settings: AppSettings, processing: ProcessingCoordinator,
         recording: RecordingController) {
        self.asr = asr
        self.diarizer = diarizer
        self.booster = booster
        self.semantic = semantic
        self.settings = settings
        self.processing = processing
        self.recording = recording
    }

    var models: [ManagedModel] {
        [asr.managedModel, diarizer.managedModel, booster.managedModel(inUse: settings.acousticVocabularyBoost),
         semantic.managedModel]
    }

    var isUpdating: Bool { !updatingIds.isEmpty }

    /// FluidAudio's shared cache (`…/FluidAudio/Models`).
    var fluidAudioModelsDirectory: URL { asr.cacheDirectory.deletingLastPathComponent() }

    /// Undoes an update interrupted between the swap and the verification (crash, quit).
    func recoverInterruptedUpdates() {
        for model in models { installer.recoverInterrupted(model) }
    }

    /// Sizes and unused folders; no network.
    func refreshInventory() {
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
        rows = models.map { model in
            let state: State = if updatingIds.contains(model.id), let current = previous[model.id] {
                current
            } else if !model.isInstalled {
                .notInstalled
            } else if let current = previous[model.id], current != .notInstalled {
                current
            } else {
                .unchecked
            }
            return Row(model: model, bytes: StorageMaintenance.size(of: model.directory), state: state)
        }
        let used = Set([asr.managedModel.directory, diarizer.managedModel.directory,
                        booster.managedModel(inUse: true).directory])
        unusedFolders = ModelInventory.unusedFolders(in: fluidAudioModelsDirectory, used: used)
    }

    func checkForUpdates() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }
        refreshInventory()
        for row in rows where row.model.isInstalled && !updatingIds.contains(row.id) {
            set(row.id, .checking)
            let state: State
            do {
                state = switch try await installer.check(row.model) {
                case .notInstalled: .notInstalled
                case .upToDate(let revision): .upToDate(revision)
                case .updateAvailable(let plan): .available(plan)
                case .pinned(let revision): .pinned(revision)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            if !updatingIds.contains(row.id) { set(row.id, state) }
        }
        lastChecked = Date()
    }

    /// Why an update cannot start now, or nil.
    var busyReason: String? {
        if let blockedReason { return blockedReason }
        if isUpdating { return "se actualiza otro modelo" }
        return activityReason
    }

    private var activityReason: String? {
        if recording.isActive { return "se graba una reunión" }
        if processing.active != nil || !processing.queue.isEmpty { return "se procesa una reunión" }
        return nil
    }

    func update(_ id: String) async {
        guard !updatingIds.contains(id), let row = rows.first(where: { $0.id == id }),
              case .available(let plan) = row.state else { return }
        if let busyReason {
            set(id, .failed(ModelInstallError.busy(busyReason).localizedDescription))
            return
        }
        let model = row.model
        guard let lease = acquireLease(for: model) else { return }
        defer { lease.release() }
        updatingIds.insert(id)
        defer { updatingIds.remove(id) }
        set(id, .updating(0))
        let report: @MainActor @Sendable (Double?) -> Void = { [weak self] fraction in
            guard let self, case .updating(.some(_)) = self.rows.first(where: { $0.id == id })?.state else { return }
            self.set(id, .updating(fraction))
        }
        do {
            let staging = try await installer.stage(model, plan: plan) { done, total in
                let fraction = total > 0 ? Double(done) / Double(total) : nil
                Task { @MainActor in report(fraction) }
            }
            try await install(model, plan: plan, staging: staging)
        } catch {
            set(id, .failed(error.localizedDescription))
        }
        refreshInventory()
    }

    private func acquireLease(for model: ManagedModel) -> ModelUpdateLease? {
        do {
            return try installer.beginUpdate(model)
        } catch let error as ModelInstallError {
            set(model.id, .failed(error.localizedDescription))
        } catch {
            set(model.id, .failed("No se pudo reservar el modelo para modificarlo: \(error.localizedDescription)"))
        }
        return nil
    }

    private func install(_ model: ManagedModel, plan: ModelUpdatePlan, staging: URL) async throws {
        if let reason = activityReason {
            try? FileManager.default.removeItem(at: staging)
            throw ModelInstallError.busy(reason)
        }
        processing.suspendStarts()
        defer { processing.resumeStarts() }
        await unload(model.id)
        if recording.isActive {
            try? FileManager.default.removeItem(at: staging)
            throw ModelInstallError.busy("se graba una reunión")
        }
        try installer.swapIn(model, staging: staging)
        set(model.id, .updating(nil))
        do {
            try await verify(model.id)
        } catch {
            try installer.rollback(model)
            await unload(model.id)
            set(model.id, .failed("La versión nueva no cargó; se restauró la anterior. \(error.localizedDescription)"))
            return
        }
        installer.commit(model)
        set(model.id, .upToDate(plan.revision))
        logger.notice("Updated \(model.id, privacy: .public) to \(plan.revision, privacy: .public)")
    }

    /// Deletes a model the app does not use (it downloads again if the feature is turned on).
    func deleteUnusedModel(_ id: String) async {
        guard !updatingIds.contains(id), let model = models.first(where: { $0.id == id }), model.unusedReason != nil,
              model.isInstalled, let lease = acquireLease(for: model) else { return }
        defer { lease.release() }
        await unload(id)
        do {
            try FileManager.default.removeItem(at: model.directory)
        } catch {
            set(id, .failed(error.localizedDescription))
        }
        refreshInventory()
    }

    func deleteFolder(_ folder: UnusedModelFolder) {
        do {
            try FileManager.default.removeItem(at: folder.url)
        } catch {
            logger.error("Could not delete model folder: \(error.localizedDescription, privacy: .public)")
        }
        refreshInventory()
    }

    private func set(_ id: String, _ state: State) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].state = state }
    }

    private func unload(_ id: String) async {
        switch id {
        case asr.managedModel.id: await asr.unload()
        case diarizer.managedModel.id: await diarizer.unload()
        case booster.managedModel(inUse: true).id: await booster.unload()
        default: await semantic.unloadModel()
        }
    }

    /// Loads the new files the same way processing will.
    private func verify(_ id: String) async throws {
        switch id {
        case asr.managedModel.id: try await asr.prepare { _ in }
        case diarizer.managedModel.id: try await diarizer.prepare()
        case booster.managedModel(inUse: true).id: try await booster.prepare()
        default: try await semantic.verifyModel()
        }
    }
}
