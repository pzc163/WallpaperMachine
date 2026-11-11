import SwiftUI

struct CreatorMediaMenu: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        @Bindable var model = controller.creator
        Menu {
            Button("Upload image or video") { controller.launch { try await controller.chooseCreatorMedia() } }
            Button("Paste image") { controller.launch { try await controller.pasteCreatorMedia() } }
            Button("Choose from wallpaper library") { controller.launch { try await controller.prepareCreatorLibraryMedia() } }
            Divider()
            Button("Import wallpaper project") { controller.launch { try await controller.importCreatorProject() } }
            Button("Export wallpaper project") { controller.launch { try await controller.exportCreatorProject() } }
                .disabled(model.selectedRevision == nil || model.hasSourceChanges)
        } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
        .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
        .help(L("Upload image or video")).accessibilityLabel(Text("Upload image or video")).accessibilityIdentifier("creator-media-upload")
        .sheet(isPresented: $model.showsMediaLibrary) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose from wallpaper library").font(.headline)
                if model.libraryMedia.isEmpty { Text("No supported image or video wallpapers.").foregroundStyle(.secondary) }
                List(model.libraryMedia) { item in
                    Button { controller.launch { try await controller.importCreatorLibraryMedia(item.id) } } label: { Text(verbatim: item.title) }
                }.frame(minHeight: 120, maxHeight: 340)
                HStack { Spacer(); Button("Cancel") { model.showsMediaLibrary = false } }
            }.padding(20).frame(width: 400)
        }
    }
}

struct CreatorMediaControls: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        if let media = controller.creator.detail?.media {
            VStack(alignment: .leading, spacing: 10) {
                Text("Media asset").font(.headline)
                Text(verbatim: "\(media.width) × \(media.height) · " + ByteCountFormatter.string(fromByteCount: Int64(media.base.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                Picker("Media fill", selection: number("mediaFill", default: 0)) {
                    Text("Fill").tag(0.0); Text("Fit").tag(1.0); Text("Stretch").tag(2.0)
                }.accessibilityIdentifier("creator-media-fill")
                VStack(alignment: .leading) {
                    Text("Media exposure").font(.caption)
                    Slider(value: number("mediaExposure", default: 0), in: -2...1, step: 0.01).accessibilityLabel(Text("Media exposure"))
                }
                if media.kind == .video {
                    VStack(alignment: .leading) {
                        Text("Video speed").font(.caption)
                        Slider(value: number("mediaSpeed", default: 1), in: 0.25...2, step: 0.01).accessibilityLabel(Text("Video speed"))
                    }
                    Text("Videos loop silently and pause with the wallpaper.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    ForEach(media.palette, id: \.self) { hex in
                        let c = CreatorParameterSchema.rgb(hex)
                        Circle().fill(Color(red: c[0], green: c[1], blue: c[2])).frame(width: 18, height: 18).accessibilityLabel(Text(verbatim: hex))
                    }
                    Spacer(); CreatorMediaMenu()
                }.accessibilityLabel(Text("Extracted palette"))
                Text("Media stays on this Mac. Only an explicitly enabled thumbnail is sent to a vision model.").font(.caption).foregroundStyle(.secondary)
            }.disabled(controller.creator.isBusy).accessibilityIdentifier("creator-media-controls")
        }
    }
    private func number(_ id: String, default fallback: Double) -> Binding<Double> {
        Binding(get: { if case .number(let value) = controller.creator.parameters[id] { return value }; return fallback }, set: { value in
            controller.launch(PanelActionCoordinator.key("creator.parameters"), policy: .latestWins) { try controller.setCreatorParameter(id, value: .number(value)) }
        })
    }
}
