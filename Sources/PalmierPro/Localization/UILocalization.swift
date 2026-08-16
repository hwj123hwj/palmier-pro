extension ClipType {
    @MainActor
    var localizedTrackLabel: String {
        switch self {
        case .video, .sequence: L10n.string("Video")
        case .audio: L10n.string("Audio")
        case .image: L10n.string("Image")
        case .text: L10n.string("Text")
        case .lottie: "Lottie"
        case .subtitle: L10n.string("Subtitle")
        }
    }
}

extension CropAspectLock {
    @MainActor
    var localizedLabel: String {
        switch self {
        case .free: L10n.string("Freeform")
        case .original: L10n.string("Original")
        case .fixed: label
        }
    }
}
