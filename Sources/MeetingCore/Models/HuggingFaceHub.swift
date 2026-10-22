public import Foundation
import os

/// Public Hugging Face Hub endpoints (no account, no token). Only called when the user
/// asks to check or apply updates; it sends nothing but the repository name.
public struct HuggingFaceHub: ModelRepositorySource {
    let base = URL(string: "https://huggingface.co")!

    public init() {}

    public func latestRevision(repository: String) async throws -> String {
        struct Info: Decodable { var sha: String }
        let url = base.appendingPathComponent("api/models/\(repository)/revision/main")
        return try JSONDecoder().decode(Info.self, from: try await get(url).0).sha
    }

    public func files(repository: String, revision: String) async throws -> [RemoteModelFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { var oid: String }
            var type: String
            var path: String
            var size: Int64?
            var oid: String
            var lfs: LFS?
        }
        var next: URL? = URL(string: "\(base.absoluteString)/api/models/\(repository)/tree/\(revision)?recursive=true")
        var files: [RemoteModelFile] = []
        while let url = next {
            let (data, response) = try await get(url)
            files += try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }.map {
                RemoteModelFile(path: $0.path, size: $0.size ?? 0, sha256: $0.lfs?.oid, gitOid: $0.oid)
            }
            next = Self.nextPage(response)
        }
        return files
    }

    public func download(repository: String, revision: String, path: String, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "\(base.absoluteString)/\(repository)/resolve/\(revision)/\(encoded)") else {
            throw ModelInstallError.network("ruta inválida \(path)")
        }
        try await FileDownload(url: url, destination: destination, progress: progress).run()
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelInstallError.network("HTTP \(http.statusCode)")
            }
            return (data, response)
        } catch let error as ModelInstallError {
            throw error
        } catch {
            throw ModelInstallError.network(error.localizedDescription)
        }
    }

    /// `Link: <…>; rel="next"` pagination of the tree endpoint.
    static func nextPage(_ response: URLResponse) -> URL? {
        guard let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            if let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">") {
                return URL(string: String(part[part.index(after: start)..<end]))
            }
        }
        return nil
    }
}

/// One file download with byte progress (the async URLSession API reports none).
final class FileDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    let url: URL
    let destination: URL
    let progress: @Sendable (Int64) -> Void
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, any Error>?, moveError: (any Error)?)>(
        initialState: (nil, nil))

    init(url: URL, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelInstallError.network("HTTP \(http.statusCode) al descargar \(destination.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            state.withLock { $0.moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, moveError) = state.withLock { s -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            defer { s.continuation = nil }
            return (s.continuation, s.moveError)
        }
        if let error = error ?? moveError {
            continuation?.resume(throwing: error is ModelInstallError ? error : ModelInstallError.network(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
