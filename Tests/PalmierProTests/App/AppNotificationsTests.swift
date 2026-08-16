import Testing
@testable import PalmierPro

@Suite("App notifications")
@MainActor
struct AppNotificationsTests {
    @Test func generatedAssetCountsPickTheRightMessagePerType() {
        let count = 2
        #expect(AppNotifications.generationBody(assetName: "", assetType: .video, count: count)
                == L10n.string("\(count) videos are ready in Palmier Pro."))
        #expect(AppNotifications.generationBody(assetName: "", assetType: .sequence, count: count)
                == L10n.string("\(count) videos are ready in Palmier Pro."))
        #expect(AppNotifications.generationBody(assetName: "", assetType: .audio, count: count)
                == L10n.string("\(count) audio clips are ready in Palmier Pro."))
        #expect(AppNotifications.generationBody(assetName: "", assetType: .image, count: count)
                == L10n.string("\(count) images are ready in Palmier Pro."))
        #expect(AppNotifications.generationBody(assetName: "", assetType: .text, count: count)
                == L10n.string("\(count) text clips are ready in Palmier Pro."))
        #expect(AppNotifications.generationBody(assetName: "", assetType: .lottie, count: count)
                == L10n.string("\(count) Lottie animations are ready in Palmier Pro."))
    }

    @Test func unnamedGeneratedAssetsPickTheRightMessagePerType() {
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .video, count: 1)
                == L10n.string("Your video is ready."))
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .sequence, count: 1)
                == L10n.string("Your video is ready."))
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .audio, count: 1)
                == L10n.string("Your audio clip is ready."))
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .image, count: 1)
                == L10n.string("Your image is ready."))
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .text, count: 1)
                == L10n.string("Your text clip is ready."))
        #expect(AppNotifications.generationBody(assetName: " ", assetType: .lottie, count: 1)
                == L10n.string("Your Lottie animation is ready."))
    }
}
