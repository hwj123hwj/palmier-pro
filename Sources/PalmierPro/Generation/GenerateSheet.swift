import SwiftUI

/// Compact generation sheet: prompt + model + format pickers → background job.
struct GenerateSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var videoModel = GenerationModel.defaultModel(for: .video)
    @State private var imageModel = GenerationModel.defaultModel(for: .image)
    @State private var isVideo = true
    @State private var aspectRatio: String?
    @State private var duration: Int?
    @State private var resolution: String?
    @State private var errorText: String?

    private var model: GenerationModel { isVideo ? videoModel : imageModel }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Generate"))
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))

            Picker(L10n.string("Kind"), selection: $isVideo) {
                Text(L10n.string("Video")).tag(true)
                Text(L10n.string("Image")).tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: isVideo) { _, _ in resetFormat() }

            TextEditor(text: $prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .frame(minHeight: 72)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                )

            Picker(L10n.string("Model"), selection: modelBinding) {
                ForEach(GenerationModel.all.filter { $0.type == (isVideo ? .video : .image) }) { candidate in
                    Text(verbatim: candidate.displayName).tag(candidate.id)
                }
            }

            Picker(L10n.string("Aspect Ratio"), selection: aspectBinding) {
                ForEach(model.aspectRatios, id: \.self) { ratio in
                    Text(verbatim: ratio).tag(ratio)
                }
            }

            if isVideo {
                Picker(L10n.string("Duration"), selection: durationBinding) {
                    ForEach(model.durations, id: \.self) { seconds in
                        Text(L10n.string("\(seconds)s")).tag(seconds)
                    }
                }
            } else {
                Picker(L10n.string("Resolution"), selection: resolutionBinding) {
                    ForEach(model.resolutions, id: \.self) { value in
                        Text(verbatim: value).tag(value)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                Button(L10n.string("Generate")) { submit() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 420)
        .onAppear(perform: resetFormat)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.id }, set: { id in
            if let selected = GenerationModel.byId(id) {
                if selected.type == .video { videoModel = selected } else { imageModel = selected }
            }
            resetFormat()
        })
    }

    private var aspectBinding: Binding<String> {
        Binding(
            get: { aspectRatio ?? model.defaultAspectRatio },
            set: { aspectRatio = $0 }
        )
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { duration ?? model.durations.first ?? 5 },
            set: { duration = $0 }
        )
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { resolution ?? model.resolutions.first ?? "1K" },
            set: { resolution = $0 }
        )
    }

    private func resetFormat() {
        aspectRatio = nil
        duration = nil
        resolution = nil
        errorText = nil
    }

    private func submit() {
        do {
            let request = GenerationService.Request(
                model: model,
                prompt: prompt,
                aspectRatio: aspectRatio ?? model.defaultAspectRatio,
                durationSeconds: isVideo ? (duration ?? model.durations.first) : nil,
                resolution: isVideo ? nil : (resolution ?? model.resolutions.first),
                sourceImageAssetId: nil,
                referenceImageAssetIds: [],
                folderId: editor.mediaPanelCurrentFolderId
            )
            let asset = try editor.generationService.submit(request, editor: editor)
            editor.mediaPanelToast = MediaPanelToast(message: L10n.string("Generating \(asset.name)."))
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
