import Foundation

/// Owns generation jobs: placeholder asset → provider submit → poll → download → install.
/// One task per in-flight asset; cancelling the task marks the asset failed.
@MainActor
final class GenerationService {
    struct Request {
        var model: GenerationModel
        var prompt: String
        var aspectRatio: String
        var durationSeconds: Int?
        var resolution: String?
        var sourceImageAssetId: String?
        var referenceImageAssetIds: [String] = []
        var name: String?
        var folderId: String?
    }

    enum GenerationError: LocalizedError {
        case keyMissing
        case invalidPrompt
        case invalidParameter(String)

        var errorDescription: String? {
            switch self {
            case .keyMissing: FalProvider.ProviderError.missingKey.errorDescription
            case .invalidPrompt: "The generation prompt is empty."
            case .invalidParameter(let detail): detail
            }
        }
    }

    private let provider = FalProvider()
    private var tasks: [String: Task<Void, Never>] = [:]
    private let pollInterval: Duration = .seconds(3)
    private let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024

    func submit(_ request: Request, editor: EditorViewModel) throws -> MediaAsset {
        guard GenerationKeyStore.isConfigured else { throw GenerationError.keyMissing }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw GenerationError.invalidPrompt }
        try validate(request)

        let mediaDirectory = editor.projectURL.map { $0.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true) }
        let ext = request.model.type == .video ? "mp4" : "png"
        let filename = "gen-\(UUID().uuidString.prefix(8)).\(ext)"
        let placeholderURL = (mediaDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent(filename)

        let asset = MediaAsset(
            url: placeholderURL,
            type: request.model.type == .video ? .video : .image,
            name: request.name ?? String(prompt.prefix(30)),
            generationInput: GenerationInput(
                prompt: prompt,
                model: request.model.id,
                duration: request.durationSeconds ?? 0,
                aspectRatio: request.aspectRatio,
                resolution: request.resolution
            )
        )
        asset.folderId = request.folderId
        asset.generationStatus = .preparing

        editor.importMediaAsset(asset)
        tasks[asset.id] = Task { [weak self] in
            await self?.run(request: request, asset: asset, editor: editor)
        }
        return asset
    }

    func cancel(assetId: String) {
        tasks[assetId]?.cancel()
    }

    /// A relaunch cannot resume provider jobs; anything still pending from a previous
    /// session is reported as interrupted rather than spinning forever.
    func markStaleJobsFailed(editor: EditorViewModel) {
        var updates: [MediaAsset] = []
        for asset in editor.mediaAssets
        where tasks[asset.id] == nil && asset.isGenerated && asset.isGenerating {
            asset.generationStatus = .failed("Generation interrupted")
            updates.append(asset)
        }
        if !updates.isEmpty { editor.updateManifestMetadata(for: updates) }
    }

    private func validate(_ request: Request) throws {
        let model = request.model
        guard model.aspectRatios.contains(request.aspectRatio) else {
            throw GenerationError.invalidParameter("Aspect ratio \(request.aspectRatio) is not supported by \(model.displayName).")
        }
        if model.type == .video, let duration = request.durationSeconds {
            guard model.durations.contains(duration) else {
                throw GenerationError.invalidParameter("Duration \(duration)s is not supported by \(model.displayName).")
            }
        }
        if model.type == .image, let resolution = request.resolution {
            guard model.resolutions.contains(resolution) else {
                throw GenerationError.invalidParameter("Resolution \(resolution) is not supported by \(model.displayName).")
            }
        }
        if model.type == .image, request.referenceImageAssetIds.count > model.maxReferenceImages {
            throw GenerationError.invalidParameter("\(model.displayName) accepts at most \(model.maxReferenceImages) reference images.")
        }
    }

    private func run(request: Request, asset: MediaAsset, editor: EditorViewModel) async {
        defer { tasks[asset.id] = nil }
        do {
            let sourceURI = try await encodeImageDataURI(assetId: request.sourceImageAssetId, editor: editor)
            let referenceURIs = try await encodeImageDataURIs(assetIds: request.referenceImageAssetIds, editor: editor)
            let input = FalProvider.input(
                model: request.model,
                prompt: asset.generationInput?.prompt ?? "",
                aspectRatio: request.aspectRatio,
                durationSeconds: request.durationSeconds,
                resolution: request.resolution,
                sourceImageDataURI: sourceURI,
                referenceImageDataURIs: request.referenceImageAssetIds.isEmpty && request.model.type == .image
                    ? (sourceURI.map { [$0] } ?? [])
                    : referenceURIs
            )

            asset.generationStatus = .generating
            let submit = try await provider.submit(endpoint: request.model.endpoint, input: input)
            while true {
                try Task.checkCancellation()
                let status = try await provider.status(submit: submit)
                if status.status == "COMPLETED" { break }
                try await Task.sleep(for: pollInterval)
            }

            let payload = try await provider.result(submit: submit)
            guard let resultURL = FalProvider.resultURLs(payload).first else {
                throw GenerationError.invalidParameter("The model returned no media.")
            }

            asset.generationStatus = .downloading
            let stagedURL = try await download(resultURL)
            try editor.projectPackageCoordinator.beginMutation()
            defer { editor.projectPackageCoordinator.endMutation() }
            let committedURL = try await editor.commitStagedProjectMedia(
                stagedURL,
                filename: asset.url.lastPathComponent,
                maxBytes: maxDownloadBytes,
                workAlreadyAdmitted: true
            )

            asset.url = committedURL
            asset.generationStatus = .none
            _ = await asset.loadMetadata()
            editor.updateManifestMetadata(for: [asset])
            editor.prepareMediaVisuals(for: asset)
            editor.searchIndex.schedule(asset)
            editor.onProjectCheckpointRequired?()
            AppNotifications.generationComplete(
                assetId: asset.id,
                projectURL: editor.projectURL,
                assetName: asset.name,
                assetType: asset.type,
                count: 1
            )
        } catch is CancellationError {
            fail(asset, editor: editor, message: "Cancelled")
        } catch {
            fail(asset, editor: editor, message: error.localizedDescription)
        }
    }

    private func fail(_ asset: MediaAsset, editor: EditorViewModel, message: String) {
        asset.generationStatus = .failed(message)
        editor.updateManifestMetadata(for: [asset])
        editor.onProjectCheckpointRequired?()
        Log.generation.error("generation failed id=\(asset.id) error=\(message)")
    }

    private func encodeImageDataURI(assetId: String?, editor: EditorViewModel) async throws -> String? {
        guard let assetId else { return nil }
        return try await encodeImageDataURIs(assetIds: [assetId], editor: editor).first
    }

    private func encodeImageDataURIs(assetIds: [String], editor: EditorViewModel) async throws -> [String] {
        var urlsWithType: [(url: URL, isSource: Bool)] = []
        for (index, assetId) in assetIds.enumerated() {
            guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
                throw GenerationError.invalidParameter("Reference image \(assetId) is not in the media library.")
            }
            guard asset.type == .image else {
                throw GenerationError.invalidParameter("Reference \(assetId) is not an image.")
            }
            urlsWithType.append((asset.url, index == 0))
        }
        let jobs = urlsWithType
        let encoded = await Task.detached(priority: .userInitiated) {
            jobs.map { job in
                ImageEncoder.encode(url: job.url).map { "data:\($0.mime);base64,\($0.data.base64EncodedString())" }
            }
        }.value
        var results: [String] = []
        for (encoded, job) in zip(encoded, urlsWithType) {
            guard let dataURI = encoded else {
                throw GenerationError.invalidParameter("Could not read reference image \(job.url.lastPathComponent).")
            }
            results.append(dataURI)
        }
        return results
    }

    private func download(_ url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 600
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tempURL)
                throw FalProvider.ProviderError.http(http.statusCode, "")
            }
            return tempURL
        }.value
    }
}
