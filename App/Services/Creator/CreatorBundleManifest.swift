import Foundation
import ImageIO

/// Native bundle format, independent of the model contract and template revision.
struct CreatorBundleManifest: Codable, Equatable, Sendable {
    enum Packaging: String, Codable, Sendable { case renderDraft, sealed }
    let schemaVersion: Int
    let bundleVersion: Int
    let specification: CreatorTemplate.Specification
    let runtimePolicy: String
    let policyVersion: Int
    let sdkVersion: Int
    let packaging: Packaging
    let posterDigest: String?
    var presentation: CreatorBundlePresentation? = nil
    var media: CreatorMediaBinding? = nil

    static func templateIdentity(_ specification: CreatorTemplate.Specification) -> (id: String, revision: Int) {
        if specification.kind == .code { return (CreatorCodeOutput.templateID, 1) }
        return (specification.templateID ?? specification.kind.rawValue + "-v1", specification.templateID == nil ? 1 : (specification.rendererRevision ?? 2))
    }

    static func parameters(_ specification: CreatorTemplate.Specification) -> [String: CreatorTemplateCatalog.Value] {
        if specification.kind == .code { return specification.parameters ?? [:] }
        return specification.parameters ?? ["hue": .number(specification.hue), "speed": .number(specification.speed)]
    }

    static func files(for specification: CreatorTemplate.Specification, poster: Data? = nil,
                      presentation: CreatorBundlePresentation? = nil, source: Data? = nil, assets: [String: Data]? = nil) throws -> [String: Data] {
        var files = try specification.kind == .code ? CreatorCodeOutput.files(specification: specification, html: source) : CreatorTemplate.files(for: specification)
        if let presentation {
            try presentation.validate()
            guard specification.templateID != nil || specification.kind == .code else { throw CreatorPersistence.Failure.invalidRecord }
            var project = try JSONSerialization.jsonObject(with: files["project.json"]!) as! [String: Any]
            project["title"] = presentation.title
            project["description"] = presentation.summary
            files["project.json"] = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        if let poster {
            try validatePoster(poster)
            var project = try JSONSerialization.jsonObject(with: files["project.json"]!) as! [String: Any]
            project["preview"] = "preview.jpg"
            files["project.json"] = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys])
            files["preview.jpg"] = poster
        }
        let media = try source.flatMap { try CreatorEngineDocument.read(String(decoding: $0, as: UTF8.self))?.metadata.media }
        if let media {
            let prepared = CreatorPreparedMedia(binding: media, files: try assets ?? CreatorMediaDefaults.files(media))
            try prepared.validate()
            files.merge(prepared.files) { _, next in next }
        } else if let assets, !assets.isEmpty { throw CreatorPersistence.Failure.invalidRecord }
        let manifest = Self(schemaVersion: 1, bundleVersion: media == nil ? 2 : 3, specification: specification,
                            runtimePolicy: specification.runtimePolicy, policyVersion: 1, sdkVersion: 1,
                            packaging: poster == nil ? .renderDraft : .sealed,
                            posterDigest: poster.map(CreatorPersistence.hash), presentation: presentation, media: media)
        files[CreatorTemplate.metadataFile] = try CreatorPersistence.encode(manifest)
        return files
    }

    static func write(_ files: [String: Data], to directory: URL) throws {
        try CreatorPersistence.directory(directory, create: true)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            if path.hasPrefix("assets/") {
                guard path.range(of: "^assets/[a-f0-9]{64}\\.(jpg|png|mp4|mov|m4v|webm)$", options: .regularExpression) != nil else { throw CreatorPersistence.Failure.invalidPath }
                try CreatorPersistence.directory(directory.appendingPathComponent("assets"), create: true)
            } else if !["creator.json", "project.json", "index.html", "preview.jpg"].contains(path) { throw CreatorPersistence.Failure.invalidPath }
            try CreatorPersistence.atomicWrite(data, to: directory.appendingPathComponent(path), limit: CreatorMediaFile.maximumBytes)
        }
    }

    static func validatePoster(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 512 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...1280).contains(width), (1...1280).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              CGImageSourceGetStatus(source) == .statusComplete else { throw CreatorPersistence.Failure.invalidRecord }
    }

    /// Legacy packages keep their exact three-file reconstruction and digest algorithm.
    static func read(_ directory: URL, scopedRevision: Bool = false, expectedDigest: String? = nil) throws -> CreatorDraftStore.Snapshot {
        let urls = try CreatorPersistence.directories(directory)
        let names = Set(urls.map(\.lastPathComponent))
        let base: Set<String> = ["creator.json", "project.json", "index.html"]
        guard base.isSubset(of: names), names.isSubset(of: base.union(["preview.jpg", "assets"])) else { throw CreatorTemplate.Failure.invalidBundle }
        var files: [String: Data] = [:]
        for url in urls where url.lastPathComponent != "assets" {
            files[url.lastPathComponent] = try CreatorPersistence.bytes(url, limit: url.lastPathComponent == "preview.jpg" ? 512 * 1024 : 256 * 1024)
        }
        let metadata = files[CreatorTemplate.metadataFile]!
        let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        let decodedManifest = object?["bundleVersion"] == nil ? nil : try JSONDecoder().decode(Self.self, from: metadata)
        if let media = decodedManifest?.media {
            guard decodedManifest?.bundleVersion == 3, names.contains("assets") else { throw CreatorTemplate.Failure.invalidBundle }
            try media.validate()
            let children = try CreatorPersistence.directories(directory.appendingPathComponent("assets"))
            guard Set(children.map { "assets/" + $0.lastPathComponent }) == Set(media.files.map(\.path)) else { throw CreatorTemplate.Failure.invalidBundle }
            var total = 0
            for item in media.files {
                if files[item.path] != nil { continue }
                let data = try CreatorPersistence.bytes(directory.appendingPathComponent(item.path), limit: CreatorMediaFile.maximumBytes)
                total += data.count
                guard total <= CreatorMediaFile.maximumBundleBytes else { throw CreatorPersistence.Failure.tooLarge }
                files[item.path] = data
            }
        } else if names.contains("assets") || decodedManifest?.bundleVersion == 3 { throw CreatorTemplate.Failure.invalidBundle }
        let specification: CreatorTemplate.Specification
        let manifest: Self?
        let rebuilt: [String: Data]
        if let decoded = decodedManifest {
            guard decoded.schemaVersion == 1, [2, 3].contains(decoded.bundleVersion), decoded.policyVersion == 1,
                  decoded.sdkVersion == 1, decoded.runtimePolicy == decoded.specification.runtimePolicy else { throw CreatorPersistence.Failure.unsupportedVersion }
            guard (decoded.packaging == .sealed) == (files["preview.jpg"] != nil) else { throw CreatorPersistence.Failure.incompleteBundle }
            specification = decoded.specification
            manifest = decoded
            rebuilt = try Self.files(for: specification, poster: files["preview.jpg"], presentation: decoded.presentation, source: decoded.specification.kind == .code ? files["index.html"] : nil, assets: files.filter { $0.key.hasPrefix("assets/") })
        } else {
            specification = try JSONDecoder().decode(CreatorTemplate.Specification.self, from: metadata)
            manifest = nil
            rebuilt = try CreatorTemplate.files(for: specification)
        }
        if !scopedRevision {
            let expectedID = manifest == nil ? specification.wallpaperID : "ai-" + CreatorPersistence.uuidName(specification.projectID)
            guard directory.lastPathComponent == expectedID else { throw CreatorTemplate.Failure.invalidPath }
        }
        guard rebuilt == files else { throw CreatorTemplate.Failure.changedContent }
        let digest = CreatorTemplate.digest(files)
        if let expectedDigest, digest != expectedDigest { throw CreatorTemplate.Failure.changedContent }
        return CreatorDraftStore.Snapshot(specification: specification, files: files, digest: digest, manifest: manifest)
    }
}
