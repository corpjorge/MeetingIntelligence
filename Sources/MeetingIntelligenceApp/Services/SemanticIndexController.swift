import Foundation
import MeetingCore
import MeetingSemantic
import OSLog

/// Opt-in semantic search (TD-25): model download, background indexing and query vectors.
/// Nothing is downloaded or embedded while the setting is off.
@Observable
final class SemanticIndexController {
    enum Status: Equatable {
        case disabled
        case preparing(String)
        case indexing(SemanticIndexCoverage)
        case ready(SemanticIndexCoverage)
        case failed(String)
    }

    private(set) var status: Status = .disabled
    var blockedReason: String?
    private let engine: SemanticSearchEngine
    private let database: AppDatabase
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private var generation = 0
    private var rerun = false
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "semantic")

    init(paths: AppPaths, database: AppDatabase, settings: AppSettings) {
        engine = SemanticSearchEngine(modelsDirectory: paths.modelsDirectory)
        self.database = database
        self.settings = settings
    }

    var modelDirectory: URL { engine.modelDirectory }

    var managedModel: ManagedModel { engine.managedModel(inUse: settings.semanticSearch) }

    /// Stops indexing and releases the model (before an update or a delete).
    func unloadModel() async {
        let previous = stopRun()
        await previous?.value
        await engine.unload()
    }

    /// Loads the model files as search will, then resumes indexing if enabled.
    func verifyModel() async throws {
        try await engine.prepare()
        if !settings.semanticSearch { await engine.unload() }
        refresh()
    }

    /// Applies the current setting: starts indexing when enabled, stops when disabled.
    func refresh() {
        guard settings.semanticSearch else {
            let previous = stopRun()
            status = .disabled
            let engine = self.engine
            Task {
                await previous?.value
                await engine.unload()
            }
            return
        }
        schedule()
    }

    /// Indexes new or edited segments (coalesces calls while a run is active).
    func schedule() {
        guard settings.semanticSearch else { return }
        if let blockedReason {
            status = .failed(blockedReason)
            return
        }
        if task != nil { rerun = true; return }
        generation += 1
        rerun = false
        let current = generation
        task = Task { [weak self] in await self?.run(generation: current) }
    }

    @discardableResult
    private func stopRun() -> Task<Void, Never>? {
        let previous = task
        previous?.cancel()
        task = nil
        rerun = false
        generation += 1
        return previous
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled && settings.semanticSearch
    }

    private func run(generation token: Int) async {
        repeat {
            rerun = false
            do {
                guard isCurrent(token) else { break }
                status = .preparing(engine.isModelCached() ? "Cargando el modelo" : "Descargando e5-small (~470 MB)")
                try await engine.prepare()
                guard isCurrent(token) else { break }
                let model = SemanticSearchEngine.modelId
                status = .indexing(try database.semanticIndexCoverage(model: model))
                try await engine.indexPending(database: database) { coverage in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, case .indexing = self.status else { return }
                        self.status = .indexing(coverage)
                    }
                }
                guard isCurrent(token) else { break }
                status = .ready(try database.semanticIndexCoverage(model: model))
            } catch is CancellationError {
                break
            } catch {
                guard isCurrent(token) else { break }
                logger.error("Semantic indexing failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
                break
            }
        } while rerun && isCurrent(token)
        if generation == token { task = nil }
    }

    /// Query vector for the chat, or nil (setting off, model missing, or failure → keyword search only).
    func query(for question: String) async -> SemanticQuery? {
        guard settings.semanticSearch, engine.isModelCached() else { return nil }
        do {
            return try await engine.embedQuery(question)
        } catch {
            logger.error("Query embedding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clearIndex() {
        let previous = stopRun()
        Task {
            await previous?.value
            do {
                try database.clearSemanticIndex()
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
            refresh()
        }
    }
}
