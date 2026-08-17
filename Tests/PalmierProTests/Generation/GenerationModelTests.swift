import Testing
@testable import PalmierPro

@Suite("Generation catalog and provider mapping")
struct GenerationModelTests {
    @Test func catalogEndpointsAreUniqueAndCovered() {
        #expect(Set(GenerationModel.all.map(\.id)).count == GenerationModel.all.count)
        #expect(Set(GenerationModel.all.filter { $0.channel == .fal }.map(\.endpoint)).count
            == GenerationModel.all.filter { $0.channel == .fal }.count)
        #expect(GenerationModel.all.contains { $0.type == .video && !$0.requiresSourceImage })
        #expect(GenerationModel.all.contains { $0.type == .image })
        #expect(GenerationModel.all.contains { $0.type == .audio })
        for model in GenerationModel.all {
            if model.channel == .fal {
                #expect(!model.aspectRatios.isEmpty)
                if model.type == .video { #expect(!model.durations.isEmpty) }
                if model.type == .image { #expect(!model.resolutions.isEmpty) }
                #expect(!model.endpoint.isEmpty)
            } else {
                #expect(model.endpoint.isEmpty)
            }
            #expect(!model.requiresSourceImage || model.acceptsSourceImage)
        }
        #expect(GenerationModel.all.contains { $0.channel == .browserChatGPT && $0.type == .image })
        #expect(GenerationModel.all.contains { $0.channel == .browserGemini && $0.type == .video })
        #expect(GenerationModel.all.contains { $0.channel == .browserGemini && $0.type == .audio })
    }

    @Test func browserChannelsSupportImageInputs() {
        let veo = GenerationModel.byId("browser-gemini-video")!
        #expect(veo.supportsSourceImage && !veo.requiresSourceImage)
        let chatgpt = GenerationModel.byId("browser-chatgpt-image")!
        #expect(chatgpt.maxReferenceImages > 0)
        let music = GenerationModel.byId("browser-gemini-music")!
        #expect(music.type == .audio && !music.supportsSourceImage && music.maxReferenceImages == 0)
        let klingT2V = GenerationModel.byId("kling-v2.5-turbo-text-to-video")!
        #expect(!klingT2V.supportsSourceImage)
    }

    @Test func videoInputCarriesSchemaFields() throws {
        let model = try #require(GenerationModel.byId("kling-v2.5-turbo-image-to-video"))
        let input = FalProvider.input(
            model: model, prompt: "a drone shot", aspectRatio: "16:9",
            durationSeconds: 10, resolution: nil,
            sourceImageDataURI: "data:image/png;base64,AAA", referenceImageDataURIs: []
        )
        #expect(input["prompt"] as? String == "a drone shot")
        #expect(input["aspect_ratio"] as? String == "16:9")
        #expect(input["duration"] as? String == "10")
        #expect(input["image_url"] as? String == "data:image/png;base64,AAA")
    }

    @Test func imageReferencesMapToFirstPlusArray() {
        let model = GenerationModel.byId("nano-banana-pro")!
        let refs = ["data:image/png;base64,1", "data:image/png;base64,2", "data:image/png;base64,3"]
        let input = FalProvider.input(
            model: model, prompt: "a lab swimming", aspectRatio: "16:9",
            durationSeconds: nil, resolution: "2K",
            sourceImageDataURI: nil, referenceImageDataURIs: refs
        )
        #expect(input["image_url"] as? String == refs[0])
        #expect((input["image_urls"] as? [String]) == Array(refs.dropFirst()))
        #expect(input["resolution"] as? String == "2K")
    }

    @Test func resultURLsReadVideoAndImages() {
        #expect(FalProvider.resultURLs(["video": ["url": "https://x/v.mp4"]]).count == 1)
        let images: [[String: Any]] = [["url": "https://x/1.png"], ["url": "https://x/2.png"]]
        #expect(FalProvider.resultURLs(["images": images]).count == 2)
        #expect(FalProvider.resultURLs([:]).isEmpty)
    }
}
