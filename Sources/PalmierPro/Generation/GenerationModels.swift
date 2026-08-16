import Foundation

/// Static catalog of generation models available through the configured provider.
enum GenerationModelType: String, Codable, Sendable {
    case video
    case image
}

/// How a model is reached: the fal.ai API with a stored key, or a browser
/// session driven through the repo's ego-browser scripts (no key, subscription quota).
enum GenerationChannel: String, Codable, Sendable {
    case fal
    case browserChatGPT
    case browserGemini
}

struct GenerationModel: Identifiable, Sendable, Equatable {
    let id: String
    let type: GenerationModelType
    let displayName: String
    let channel: GenerationChannel
    /// fal.ai queue endpoint; empty for browser channels.
    let endpoint: String
    let aspectRatios: [String]
    /// Video durations in seconds; empty for image models.
    let durations: [Int]
    /// Image resolutions; empty for video models.
    let resolutions: [String]
    /// True when the model requires a source image (image-to-video).
    let requiresSourceImage: Bool
    /// Maximum number of reference images accepted alongside the prompt.
    let maxReferenceImages: Int

    static let all: [GenerationModel] = [
        GenerationModel(
            id: "browser-gemini-video", type: .video,
            displayName: "Gemini Veo (Browser)",
            channel: .browserGemini,
            endpoint: "",
            aspectRatios: [], durations: [], resolutions: [],
            requiresSourceImage: false, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "browser-chatgpt-image", type: .image,
            displayName: "GPT Image (Browser)",
            channel: .browserChatGPT,
            endpoint: "",
            aspectRatios: [], durations: [], resolutions: [],
            requiresSourceImage: false, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "kling-v2.5-turbo-text-to-video", type: .video,
            displayName: "Kling 2.5 Turbo Pro",
            channel: .fal,
            endpoint: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video",
            aspectRatios: ["16:9", "9:16", "1:1"],
            durations: [5, 10], resolutions: [], requiresSourceImage: false, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "kling-v2.5-turbo-image-to-video", type: .video,
            displayName: "Kling 2.5 Turbo Pro (Image to Video)",
            channel: .fal,
            endpoint: "fal-ai/kling-video/v2.5-turbo/pro/image-to-video",
            aspectRatios: ["16:9", "9:16", "1:1"],
            durations: [5, 10], resolutions: [], requiresSourceImage: true, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "nano-banana-pro", type: .image,
            displayName: "Nano Banana Pro",
            channel: .fal,
            endpoint: "fal-ai/nano-banana-pro",
            aspectRatios: ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"],
            durations: [], resolutions: ["1K", "2K", "4K"], requiresSourceImage: false, maxReferenceImages: 14
        ),
    ]

    static func byId(_ id: String) -> GenerationModel? {
        all.first { $0.id == id }
    }

    static func defaultModel(for type: GenerationModelType) -> GenerationModel {
        all.first { $0.type == type } ?? all[0]
    }

    var defaultAspectRatio: String { aspectRatios.contains("16:9") ? "16:9" : (aspectRatios.first ?? "") }
}

enum GenerationKeyStore {
    private static let account = "fal-api-key"

    static var storedKey: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty { return env }
        #endif
        return KeychainStore.load(account: account) ?? ""
    }

    static func save(_ key: String?) {
        if let key, !key.isEmpty {
            KeychainStore.save(key, account: account)
        } else {
            KeychainStore.delete(account: account)
        }
    }

    static var isConfigured: Bool { !storedKey.isEmpty }
}
