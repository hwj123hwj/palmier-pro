import Testing
@testable import PalmierPro

@Suite("Generation catalog and provider mapping")
struct GenerationModelTests {
    @Test func catalogEndpointsAreUniqueAndCovered() {
        #expect(Set(GenerationModel.all.map(\.endpoint)).count == GenerationModel.all.count)
        #expect(GenerationModel.all.contains { $0.type == .video && !$0.requiresSourceImage })
        #expect(GenerationModel.all.contains { $0.type == .image })
        for model in GenerationModel.all {
            #expect(!model.aspectRatios.isEmpty)
            if model.type == .video { #expect(!model.durations.isEmpty) }
            if model.type == .image { #expect(!model.resolutions.isEmpty) }
        }
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
