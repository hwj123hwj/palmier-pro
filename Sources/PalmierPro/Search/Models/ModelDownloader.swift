import CoreML
import CryptoKit
import Foundation

/// Downloads, verifies, compiles, and installs the search encoders under Application Support.
/// Layout: Models/<model>-v<version>/{ImageEncoder.mlmodelc, TextEncoder.mlmodelc, tokenizer/, spec.json}
final class ModelDownloader: @unchecked Sendable {
    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable {
            let name: String
            let sha256: String
            let bytes: Int64
        }
        struct Files: Codable, Sendable {
            let imageEncoder: File
            let textEncoder: File
            let tokenizer: File
        }
        let model: String
        let version: Int
        let embeddingDim: Int
        let imageSize: Int
        let contextLength: Int
        let files: Files

        var spec: VisualEmbedder.Spec {
            .init(model: model, version: version, embeddingDim: embeddingDim,
                  imageSize: imageSize, contextLength: contextLength)
        }
    }

    struct InstalledModel: Sendable {
        let imageEncoderURL: URL
        let textEncoderURL: URL
        let tokenizerFolder: URL
        let spec: VisualEmbedder.Spec
    }

    enum DownloadError: Error {
        case httpError(Int, String)
        case checksumMismatch(String)
        case unzipFailed
        case missingPackage(String)
    }

    /// Retry budget for one file; each attempt resumes from the partial file.
    private static let downloadAttempts = 40

    static let modelsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/Models")

    static func installDir(for manifest: Manifest) -> URL {
        modelsDir.appendingPathComponent("\(manifest.model)-v\(manifest.version)")
    }

    static func installed(for manifest: Manifest) -> InstalledModel? {
        let dir = installDir(for: manifest)
        let image = dir.appendingPathComponent("ImageEncoder.mlmodelc")
        let text = dir.appendingPathComponent("TextEncoder.mlmodelc")
        let tokenizer = dir.appendingPathComponent("tokenizer", isDirectory: true)
        guard FileManager.default.fileExists(atPath: image.path),
              FileManager.default.fileExists(atPath: text.path),
              FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path)
        else { return nil }
        return InstalledModel(imageEncoderURL: image, textEncoderURL: text, tokenizerFolder: tokenizer, spec: manifest.spec)
    }

    /// Idempotent: returns immediately if already installed. `progress` is 0...1 across both files.
    func install(
        manifest: Manifest,
        baseURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> InstalledModel {
        if let existing = Self.installed(for: manifest) { return existing }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("palmier-model-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files = [manifest.files.imageEncoder, manifest.files.textEncoder, manifest.files.tokenizer]
        let totalBytes = files.reduce(0) { $0 + $1.bytes }
        var doneBytes: Int64 = 0
        var staged: [String: URL] = [:]

        for file in files {
            let base = Double(doneBytes)
            let zipURL = try await download(baseURL.appendingPathComponent(file.name), to: staging) { fileFraction in
                progress?((base + fileFraction * Double(file.bytes)) / Double(totalBytes))
            }
            do {
                try Self.verify(zipURL, sha256: file.sha256)
            } catch {
                // A resumed partial that no longer matches must not poison later attempts.
                try? FileManager.default.removeItem(at: Self.partialURL(for: file.name))
                throw error
            }
            let extracted = try Self.unzip(zipURL, in: staging)
            // Encoder zips contain an .mlpackage to compile; the tokenizer zip is plain files.
            if extracted.pathExtension == "mlpackage" {
                staged[file.name] = try await MLModel.compileModel(at: extracted)
            } else {
                staged[file.name] = extracted
            }
            doneBytes += file.bytes
            progress?(Double(doneBytes) / Double(totalBytes))
        }

        let dir = Self.installDir(for: manifest)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: staged[manifest.files.imageEncoder.name]!,
                        to: dir.appendingPathComponent("ImageEncoder.mlmodelc"))
        try fm.moveItem(at: staged[manifest.files.textEncoder.name]!,
                        to: dir.appendingPathComponent("TextEncoder.mlmodelc"))
        try fm.moveItem(at: staged[manifest.files.tokenizer.name]!,
                        to: dir.appendingPathComponent("tokenizer", isDirectory: true))
        try JSONEncoder().encode(manifest.spec).write(to: dir.appendingPathComponent("spec.json"))

        guard let installed = Self.installed(for: manifest) else { throw DownloadError.unzipFailed }
        return installed
    }

    /// Partial downloads live in a stable temp path so retries — including a
    /// fresh install attempt after a failure — resume instead of restarting.
    private static func partialURL(for name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-model-" + name + ".part")
    }

    /// Resumable download: appends to the partial file over bounded retries so
    /// links that reset or stall mid-transfer can still finish.
    private func download(
        _ url: URL,
        to dir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        let partial = Self.partialURL(for: url.lastPathComponent)
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw DownloadError.httpError(-1, url.lastPathComponent)
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        for _ in 0..<Self.downloadAttempts {
            var request = URLRequest(url: url)
            let offset = Int64(try handle.offset())
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            request.timeoutInterval = 60
            do {
                let (temp, response) = try await URLSession.shared.download(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(code) else {
                    try? FileManager.default.removeItem(at: temp)
                    throw DownloadError.httpError(code, url.lastPathComponent)
                }
                if offset > 0, code == 200 {
                    // Server ignored the Range header; start over from byte zero.
                    try handle.truncate(atOffset: 0)
                }
                let start = Int64(try handle.offset())
                let expected = response.expectedContentLength
                let reader = try FileHandle(forReadingFrom: temp)
                defer { try? reader.close() }
                var written = start
                while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    if expected > 0 { progress(Double(written) / Double(start + expected)) }
                }
                if expected >= 0, written != start + expected {
                    throw DownloadError.httpError(-2, url.lastPathComponent)
                }
                try FileManager.default.removeItem(at: temp)
                try fm.moveItem(at: partial, to: dest)
                return dest
            } catch is CancellationError {
                throw CancellationError()
            } catch let DownloadError.httpError(code, _) where (400..<600).contains(code) {
                throw DownloadError.httpError(code, url.lastPathComponent)
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw DownloadError.httpError(-3, url.lastPathComponent)
    }

    static func verify(_ url: URL, sha256 expected: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw DownloadError.checksumMismatch(url.lastPathComponent) }
    }

    private static func unzip(_ zipURL: URL, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent(zipURL.deletingPathExtension().lastPathComponent + "-extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, out.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DownloadError.unzipFailed }
        // Each zip contains exactly one top-level entry (.mlpackage or tokenizer/).
        let entries = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard let entry = entries.first, entries.count == 1 else {
            throw DownloadError.missingPackage(zipURL.lastPathComponent)
        }
        return entry
    }
}
