import SwiftUI

/// Compact generation sheet: prompt + model + format pickers → background job.
struct GenerateSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var videoModel = GenerationModel.defaultModel(for: .video)
    @State private var imageModel = GenerationModel.defaultModel(for: .image)
    @State private var audioModel = GenerationModel.defaultModel(for: .audio)
    @State private var kind: GenerationModelType = .video
    @State private var aspectRatio: String?
    @State private var duration: Int?
    @State private var resolution: String?
    @State private var startFrameAssetId: String?
    @State private var referenceAssetIds: [String] = []
    @State private var errorText: String?

    private var model: GenerationModel {
        switch kind {
        case .video: videoModel
        case .image: imageModel
        case .audio: audioModel
        }
    }

    private var libraryImages: [MediaAsset] {
        editor.mediaAssets.filter { $0.type == .image }
    }

    private var unselectedReferences: [MediaAsset] {
        libraryImages.filter { !referenceAssetIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Generate"))
                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))

            Picker(L10n.string("Kind"), selection: $kind) {
                Text(L10n.string("Video")).tag(GenerationModelType.video)
                Text(L10n.string("Image")).tag(GenerationModelType.image)
                Text(L10n.string("Music")).tag(GenerationModelType.audio)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in resetFormat() }

            TextEditor(text: $prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .frame(minHeight: 72)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                )

            Picker(L10n.string("Model"), selection: modelBinding) {
                ForEach(GenerationModel.all.filter { $0.type == kind }) { candidate in
                    Text(verbatim: candidate.displayName).tag(candidate.id)
                }
            }

            if model.channel == .fal {
                Picker(L10n.string("Aspect Ratio"), selection: aspectBinding) {
                    ForEach(model.aspectRatios, id: \.self) { ratio in
                        Text(verbatim: ratio).tag(ratio)
                    }
                }
            } else {
                Text(L10n.string("Runs in your browser session and bills your web subscription. Prompt style and aspect follow the site."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if kind == .video && model.channel == .fal {
                Picker(L10n.string("Duration"), selection: durationBinding) {
                    ForEach(model.durations, id: \.self) { seconds in
                        Text(L10n.string("\(seconds)s")).tag(seconds)
                    }
                }
            } else if kind == .image && model.channel == .fal {
                Picker(L10n.string("Resolution"), selection: resolutionBinding) {
                    ForEach(model.resolutions, id: \.self) { value in
                        Text(verbatim: value).tag(value)
                    }
                }
            }

            if model.type == .video && model.supportsSourceImage {
                Picker(L10n.string("Start Frame"), selection: $startFrameAssetId) {
                    Text(L10n.string("None")).tag(String?.none)
                    ForEach(libraryImages) { asset in
                        Text(verbatim: asset.name).tag(String?.some(asset.id))
                    }
                }
            }

            if model.type == .image && model.maxReferenceImages > 0 {
                referencePicker
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
                    .disabled(!canSubmit)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 420)
        .onAppear(perform: resetFormat)
    }

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text(L10n.string("References"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Menu {
                    ForEach(unselectedReferences) { asset in
                        Button {
                            referenceAssetIds.append(asset.id)
                        } label: {
                            Text(verbatim: asset.name)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .menuStyle(.borderlessButton)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .disabled(referenceAssetIds.count >= model.maxReferenceImages)
            }
            if !referenceAssetIds.isEmpty {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(referenceAssetIds, id: \.self) { assetId in
                        if let asset = libraryImages.first(where: { $0.id == assetId }) {
                            referenceChip(asset.name) {
                                referenceAssetIds.removeAll { $0 == assetId }
                            }
                        }
                    }
                }
            }
        }
    }

    private func referenceChip(_ name: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "photo")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(verbatim: name)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
        )
    }

    private var canSubmit: Bool {
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasPrompt && !(model.requiresSourceImage && startFrameAssetId == nil)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.id }, set: { id in
            guard let selected = GenerationModel.byId(id) else { return }
            switch selected.type {
            case .video: videoModel = selected
            case .image: imageModel = selected
            case .audio: audioModel = selected
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
        startFrameAssetId = nil
        referenceAssetIds = []
        errorText = nil
    }

    private func submit() {
        do {
            let request = GenerationService.Request(
                model: model,
                prompt: prompt,
                aspectRatio: aspectRatio ?? model.defaultAspectRatio,
                durationSeconds: kind == .video ? (duration ?? model.durations.first) : nil,
                resolution: kind == .image ? (resolution ?? model.resolutions.first) : nil,
                sourceImageAssetId: kind == .video ? startFrameAssetId : nil,
                referenceImageAssetIds: kind == .image ? referenceAssetIds : [],
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
