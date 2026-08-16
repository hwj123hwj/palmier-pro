import Foundation

// list_models, generate_video, generate_image — video/image generation through the
// configured fal.ai key. Jobs run in the background on placeholder assets.
extension ToolExecutor {

    func listModels(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["type"], path: "list_models")
        let filter = args.string("type")
        var models: [[String: Any]] = []
        for model in GenerationModel.all {
            if let filter, model.type.rawValue != filter { continue }
            models.append([
                "id": model.id,
                "type": model.type.rawValue,
                "channel": model.channel.rawValue,
                "displayName": model.displayName,
                "aspectRatios": model.aspectRatios,
                "durations": model.durations,
                "resolutions": model.resolutions,
                "requiresSourceImage": model.requiresSourceImage,
                "maxReferenceImages": model.maxReferenceImages,
            ])
        }
        guard let json = Self.jsonString(["models": models]) else {
            throw ToolError("Failed to encode model list")
        }
        return .ok(json)
    }

    func generateVideo(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let model = try resolveModel(args, type: .video, path: "generate_video") else {
            throw ToolError("generate_video: no video model requested and none is available.")
        }
        let prompt = try args.requireString("prompt")
        let sourceAssetId = try referenceAssetId(args.string("startFrameMediaRef"), editor: editor, path: "generate_video.startFrameMediaRef")
        let request = GenerationService.Request(
            model: model,
            prompt: prompt,
            aspectRatio: args.string("aspectRatio") ?? model.defaultAspectRatio,
            durationSeconds: args.int("duration") ?? model.durations.first,
            resolution: nil,
            sourceImageAssetId: sourceAssetId,
            referenceImageAssetIds: [],
            name: args.string("name"),
            folderId: try folderId(forFolderArg: args.string("folder"), editor: editor, path: "generate_video.folder")
        )
        return try submitGeneration(request, editor: editor)
    }

    func generateImage(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let model = try resolveModel(args, type: .image, path: "generate_image") else {
            throw ToolError("generate_image: no image model requested and none is available.")
        }
        let prompt = try args.requireString("prompt")
        var referenceIds: [String] = []
        if let startFrame = args.string("startFrameMediaRef"),
           let id = try referenceAssetId(startFrame, editor: editor, path: "generate_image.startFrameMediaRef") {
            referenceIds.append(id)
        }
        for ref in args.stringArray("referenceImageMediaRefs") {
            if let id = try referenceAssetId(ref, editor: editor, path: "generate_image.referenceImageMediaRefs") {
                referenceIds.append(id)
            }
        }
        let request = GenerationService.Request(
            model: model,
            prompt: prompt,
            aspectRatio: args.string("aspectRatio") ?? model.defaultAspectRatio,
            durationSeconds: nil,
            resolution: args.string("resolution") ?? model.resolutions.first,
            sourceImageAssetId: nil,
            referenceImageAssetIds: referenceIds,
            name: args.string("name"),
            folderId: try folderId(forFolderArg: args.string("folder"), editor: editor, path: "generate_image.folder")
        )
        return try submitGeneration(request, editor: editor)
    }

    private func submitGeneration(_ request: GenerationService.Request, editor: EditorViewModel) throws -> ToolResult {
        guard let asset = try? editor.generationService.submit(request, editor: editor) else {
            throw ToolError("Generation is not configured. Add a fal.ai API key in Settings → Agent.")
        }
        let json = Self.jsonString([
            "mediaRef": asset.id,
            "status": "generating",
            "model": request.model.displayName,
            "note": "Generation runs in the background and costs money. Poll get_media with ids:[\"\(asset.id)\"] until generationStatus clears; the asset is then usable in add_clips. On generationStatus 'failed', report the reason to the user before retrying.",
        ])
        return .ok(json ?? "{}")
    }

    private func resolveModel(_ args: [String: Any], type: GenerationModelType, path: String) throws -> GenerationModel? {
        if let id = args.string("model") {
            guard let model = GenerationModel.byId(id) else {
                throw ToolError("\(path): unknown model '\(id)'. Call list_models for valid ids.")
            }
            guard model.type == type else {
                throw ToolError("\(path): model '\(id)' generates \(model.type.rawValue), not \(type.rawValue).")
            }
            return model
        }
        return GenerationModel.all.first { $0.type == type }
    }

    private func referenceAssetId(_ id: String?, editor: EditorViewModel, path: String) throws -> String? {
        guard let id else { return nil }
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else {
            throw ToolError("\(path): '\(id)' is not in the media library.")
        }
        guard asset.type == .image else {
            throw ToolError("\(path): '\(id)' is not an image.")
        }
        return asset.id
    }

    private func folderId(forFolderArg path: String?, editor: EditorViewModel, path label: String) throws -> String? {
        guard let path else { return nil }
        return try folderId(atPath: path, editor: editor)
    }
}
