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
            Row(model: model, bytes: StorageMaintenance.size(of: model.directory),
                state: model.isInstalled ? (previous[model.id] ?? .unchecked) : .notInstalled)
        }
        let used = Set([asr.managedModel.directory, diarizer.managedModel.directory,
                        booster.managedModel(inUse: true).directory])
        unusedFolders = ModelInventory.unusedFolders(in: fluidAudioModelsDirectory, used: used)
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        refreshInventory()
        for row in rows where row.state != .notInstalled {
            set(row.id, .checking)
            do {
                switch try await installer.check(row.model) {
                case .notInstalled: set(row.id, .notInstalled)
                case .upToDate(let revision): set(row.id, .upToDate(revision))
                case .updateAvailable(let plan): set(row.id, .available(plan))
                case .pinned(let revision): set(row.id, .pinned(revision))
                }
            } catch {
                set(row.id, .failed(error.localizedDescription))
            }
        }
        lastChecked = Date()
    }

    /// Why an update cannot start now, or nil.
    var busyReason: String? {
        if recording.state == .recording { return "se graba una reunión" }
        if processing.active != nil || !processing.queue.isEmpty { return "se procesa una reunión" }
        return nil
    }

    func update(_ id: String) async {
        guard let row = rows.first(where: { $0.id == id }), case .available(let plan) = row.state else { return }
        if let busyReason {
            set(id, .failed(ModelInstallError.busy(busyReason).localizedDescription))
            return
        }
        let model = row.model
        set(id, .updating(0))
        do {
            let staging = try await installer.stage(model, plan: plan) { done, total in
                Task { @MainActor [weak self] in
                    self?.set(id, .updating(total > 0 ? Double(done) / Double(total) : nil))
                }
            }
            await unload(model.id)
            try installer.swapIn(model, staging: staging)
            do {
                set(id, .updating(nil))
                try await verify(model.id)
                installer.commit(model)
                set(id, .upToDate(plan.revision))
                logger.notice("Updated \(model.id, privacy: .public) to \(plan.revision, privacy: .public)")
            } catch {
                try installer.rollback(model)
                await unload(model.id)
                set(id, .failed("La versión nueva no cargó; se restauró la anterior. \(error.localizedDescription)"))
            }
        } catch {
            set(id, .failed(error.localizedDescription))
        }
        refreshInventory()
    }

    /// Deletes a model the app does not use (it downloads again if the feature is turned on).
    func deleteUnusedModel(_ id: String) async {
        guard let model = models.first(where: { $0.id == id }), model.unusedReason != nil else { return }
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
