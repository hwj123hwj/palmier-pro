import Foundation

/// Static catalog of generation models available through the configured provider.
enum GenerationModelType: String, Codable, Sendable {
    case video
    case image
}

struct GenerationModel: Identifiable, Sendable, Equatable {
    let id: String
    let type: GenerationModelType
    let displayName: String
    /// fal.ai queue endpoint, e.g. "fal-ai/kling-video/v2.5-turbo/pro/text-to-video".
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
            id: "kling-v2.5-turbo-text-to-video", type: .video,
            displayName: "Kling 2.5 Turbo Pro",
            endpoint: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video",
            aspectRatios: ["16:9", "9:16", "1:1"],
            durations: [5, 10], resolutions: [], requiresSourceImage: false, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "kling-v2.5-turbo-image-to-video", type: .video,
            displayName: "Kling 2.5 Turbo Pro (Image to Video)",
            endpoint: "fal-ai/kling-video/v2.5-turbo/pro/image-to-video",
            aspectRatios: ["16:9", "9:16", "1:1"],
            durations: [5, 10], resolutions: [], requiresSourceImage: true, maxReferenceImages: 0
        ),
        GenerationModel(
            id: "nano-banana-pro", type: .image,
            displayName: "Nano Banana Pro",
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

    var defaultAspectRatio: String { aspectRatios.contains("16:9") ? "16:9" : aspectRatios[0] }
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
