import Foundation
import Testing
@testable import PalmierPro

@Suite("browser generation status reporting")
@MainActor
struct BrowserGenerationStatusTests {
    @Test func inFlightPhaseIsVisibleThroughGetMedia() async throws {
        let scriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-gen-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let script = scriptDir.appendingPathComponent("generate-music-browser.sh")
        try "#!/bin/bash\nsleep 8\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: scriptDir) }

        let editor = EditorViewModel()
        editor.generationService.scriptsDirectoryOverride = scriptDir
        let model = try #require(GenerationModel.byId("browser-gemini-music"))
        let asset = try editor.generationService.submit(
            GenerationService.Request(model: model, prompt: "warm Rhodes chords", aspectRatio: ""),
            editor: editor
        )
        defer { editor.generationService.cancel(assetId: asset.id) }

        try await Task.sleep(for: .milliseconds(800))
        let running = try Self.status(of: asset.id, editor: editor)
        #expect(running == "generating")

        editor.generationService.cancel(assetId: asset.id)
        var terminal: String?
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            terminal = try Self.status(of: asset.id, editor: editor)
            if terminal?.hasPrefix("failed") == true { break }
        }
        #expect(terminal?.hasPrefix("failed") == true)
    }

    @MainActor
    private static func status(of assetId: String, editor: EditorViewModel) throws -> String? {
        let result = try ToolExecutor(editor: editor).getMedia(editor, ["ids": [assetId]])
        guard case .text(let text) = result.content[0],
              let data = text.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (payload["assets"] as? [[String: Any]])?.first
        else { return nil }
        return entry["generationStatus"] as? String
    }
}
