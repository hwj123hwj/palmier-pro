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
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw GenerationError.invalidPrompt }
        try validate(request)

        let mediaDirectory = editor.projectURL.map { $0.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true) }
        let ext: String
        switch request.model.type {
        case .video: ext = "mp4"
        case .audio: ext = "m4a"
        case .image: ext = "png"
        }
        let filename = "gen-\(UUID().uuidString.prefix(8)).\(ext)"
        let placeholderURL = (mediaDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent(filename)

        let assetType: ClipType
        switch request.model.type {
        case .video: assetType = .video
        case .audio: assetType = .audio
        case .image: assetType = .image
        }

        let asset = MediaAsset(
            url: placeholderURL,
            type: assetType,
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
        guard model.channel != .fal || GenerationKeyStore.isConfigured else {
            throw GenerationError.keyMissing
        }
        if model.requiresSourceImage, request.sourceImageAssetId == nil {
            throw GenerationError.invalidParameter("\(model.displayName) requires a start frame image.")
        }
        guard model.channel == .fal else { return }
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
            if request.model.channel != .fal {
                asset.generationStatus = .generating
                let staged = try await runBrowserScript(request: request, prompt: asset.generationInput?.prompt ?? "", editor: editor)
                asset.generationStatus = .downloading
                try editor.projectPackageCoordinator.beginMutation()
                defer { editor.projectPackageCoordinator.endMutation() }
                let committedURL = try await editor.commitStagedProjectMedia(
                    staged,
                    filename: asset.url.lastPathComponent,
                    maxBytes: maxDownloadBytes,
                    workAlreadyAdmitted: true
                )
                await finalize(asset: asset, committedURL: committedURL, editor: editor)
                return
            }

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

            await finalize(asset: asset, committedURL: committedURL, editor: editor)
        } catch is CancellationError {
            fail(asset, editor: editor, message: "Cancelled")
        } catch {
            fail(asset, editor: editor, message: error.localizedDescription)
        }
    }

    private func finalize(asset: MediaAsset, committedURL: URL, editor: EditorViewModel) async {
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
    }

    /// Drives the repo's ego-browser scripts and returns the produced file.
    /// Source and reference images travel as local file paths; the scripts
    /// upload them into the web UI's composer.
    private func runBrowserScript(request: Request, prompt: String, editor: EditorViewModel) async throws -> URL {
        let (script, timeout): (String, Duration)
        switch request.model.channel {
        case .browserChatGPT:
            (script, timeout) = ("generate-image-browser.sh", .seconds(300))
        case .browserGemini where request.model.type == .audio:
            (script, timeout) = ("generate-music-browser.sh", .seconds(480))
        case .browserGemini:
            (script, timeout) = ("generate-video-browser.sh", .seconds(540))
        case .fal:
            throw GenerationError.invalidParameter("unsupported channel")
        }
        let scriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("palmier-pro/scripts")
        let scriptURL = scriptsDir.appendingPathComponent(script)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw GenerationError.invalidParameter("Missing script ~/palmier-pro/scripts/\(script).")
        }

        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-browser-gen-\(UUID().uuidString.prefix(8))")
        var arguments = [prompt, stagedURL.path]
        if let sourceId = request.sourceImageAssetId {
            arguments += ["--source-image", try imagePath(forImageAsset: sourceId, editor: editor)]
        }
        for referenceId in request.referenceImageAssetIds {
            arguments += ["--reference-image", try imagePath(forImageAsset: referenceId, editor: editor)]
        }

        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        let started = ContinuousClock.now
        while process.isRunning {
            try Task.checkCancellation()
            if started.duration(to: .now) > timeout {
                process.terminate()
                throw GenerationError.invalidParameter("\(request.model.displayName) timed out.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: stagedURL.path) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: stagedURL)
            throw GenerationError.invalidParameter("Browser generation failed: \(err.suffix(300))")
        }
        return stagedURL
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

    /// Resolves an image asset the caller referenced as generation input.
    private func requireImageAsset(_ assetId: String, editor: EditorViewModel, role: String) throws -> MediaAsset {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
            throw GenerationError.invalidParameter("\(role) \(assetId) is not in the media library.")
        }
        guard asset.type == .image else {
            throw GenerationError.invalidParameter("\(role) \(assetId) is not an image.")
        }
        return asset
    }

    /// Local path for browser scripts, which upload the file into the web composer.
    private func imagePath(forImageAsset assetId: String, editor: EditorViewModel) throws -> String {
        try requireImageAsset(assetId, editor: editor, role: "Reference image").url.path
    }

    private func encodeImageDataURIs(assetIds: [String], editor: EditorViewModel) async throws -> [String] {
        let assets = try assetIds.enumerated().map { index, assetId in
            try requireImageAsset(assetId, editor: editor, role: index == 0 ? "Source image" : "Reference image")
        }
        let jobs = assets.map(\.url)
        let encoded = await Task.detached(priority: .userInitiated) {
            jobs.map { url in
                ImageEncoder.encode(url: url).map { "data:\($0.mime);base64,\($0.data.base64EncodedString())" }
            }
        }.value
        var results: [String] = []
        for (encoded, asset) in zip(encoded, assets) {
            guard let dataURI = encoded else {
                throw GenerationError.invalidParameter("Could not read reference image \(asset.url.lastPathComponent).")
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
