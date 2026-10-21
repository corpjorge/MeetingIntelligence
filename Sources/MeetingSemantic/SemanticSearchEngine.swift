import CoreML
import Embeddings
public import Foundation
public import MeetingCore
import OSLog

/// Local text embeddings for semantic search (TD-25): `intfloat/multilingual-e5-small`
/// (384 dims, MIT) through swift-embeddings / MLTensor.
///
/// * Downloaded once from Hugging Face into `<library>/Models` only when the user
///   enables semantic search; only model files are fetched, nothing is uploaded.
/// * Embeds transcript text locally; vectors live in `segmentEmbedding`.
/// * e5 expects the `query: ` / `passage: ` prefixes.
public actor SemanticSearchEngine {
    public static let modelId = "intfloat/multilingual-e5-small"
    public static let approximateDownloadBytes: Int64 = 470_000_000

    private let downloadBase: URL
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "semantic")
    private var bundle: XLMRoberta.ModelBundle?
    private let options: EncodeOptions = {
        var options = EncodeOptions.xlmRoberta
        options.postProcess = .meanPool(normalize: true)
        return options
    }()

    public init(modelsDirectory: URL) {
        downloadBase = modelsDirectory
    }

    public nonisolated var modelDirectory: URL {
        downloadBase.appendingPathComponent("models/\(Self.modelId)", isDirectory: true)
    }

    public nonisolated func isModelCached() -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.safetensors").path)
    }

    /// Downloads (first time, ~470 MB) and loads the model.
    public func prepare() async throws {
        guard bundle == nil else { return }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let started = Date()
        bundle = isModelCached()
            ? try await XLMRoberta.loadModelBundle(from: modelDirectory)
            : try await XLMRoberta.loadModelBundle(from: Self.modelId, downloadBase: downloadBase)
        logger.info("e5-small ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
    }

    public func unload() { bundle = nil }

    public func embedQuery(_ text: String) async throws -> SemanticQuery {
        let vectors = try await embed(["query: " + text])
        return SemanticQuery(vector: vectors[0], model: Self.modelId)
    }

    /// Embeds every missing or stale segment, in batches. Returns how many were embedded.
    @discardableResult
    public func indexPending(database: AppDatabase, batchSize: Int = 32,
                             progress: @Sendable (SemanticIndexCoverage) -> Void = { _ in }) async throws -> Int {
        var embedded = 0
        while true {
            try Task.checkCancellation()
            let pending = try database.segmentsNeedingEmbedding(model: Self.modelId, limit: batchSize)
            guard !pending.isEmpty else { break }
            let vectors = try await embed(pending.map { "passage: " + $0.text })
            try database.storeEmbeddings(Array(zip(pending, vectors)), model: Self.modelId)
            embedded += pending.count
            progress(try database.semanticIndexCoverage(model: Self.modelId))
            if pending.count < batchSize { break }
        }
        return embedded
    }

    private func embed(_ texts: [String]) async throws -> [[Float]] {
        try await prepare()
        guard let bundle else { throw CocoaError(.featureUnsupported) }
        let tensor = try bundle.batchEncode(texts, options: options)
        let array = await tensor.cast(to: Float.self).shapedArray(of: Float.self)
        let dim = array.shape.last ?? 0
        let scalars = array.scalars
        return (0..<texts.count).map { Array(scalars[($0 * dim)..<(($0 + 1) * dim)]) }
    }
}
