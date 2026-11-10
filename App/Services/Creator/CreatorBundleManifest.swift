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

    static func templateIdentity(_ specification: CreatorTemplate.Specification) -> (id: String, revision: Int) {
        (specification.templateID ?? specification.kind.rawValue + "-v1", specification.templateID == nil ? 1 : 2)
    }

    static func parameters(_ specification: CreatorTemplate.Specification) -> [String: CreatorTemplateCatalog.Value] {
        specification.parameters ?? ["hue": .number(specification.hue), "speed": .number(specification.speed)]
    }

    static func files(for specification: CreatorTemplate.Specification, poster: Data? = nil) throws -> [String: Data] {
        var files = try CreatorTemplate.files(for: specification)
        if let poster {
            try validatePoster(poster)
            var project = try JSONSerialization.jsonObject(with: files["project.json"]!) as! [String: Any]
            project["preview"] = "preview.jpg"
            files["project.json"] = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys])
            files["preview.jpg"] = poster
        }
        let manifest = Self(schemaVersion: 1, bundleVersion: 2, specification: specification,
                            runtimePolicy: "trustedTemplateV1", policyVersion: 1, sdkVersion: 1,
                            packaging: poster == nil ? .renderDraft : .sealed,
                            posterDigest: poster.map(CreatorPersistence.hash))
        files[CreatorTemplate.metadataFile] = try CreatorPersistence.encode(manifest)
        return files
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
        guard names == base || names == base.union(["preview.jpg"]) else { throw CreatorTemplate.Failure.invalidBundle }
        var files: [String: Data] = [:]
        for url in urls {
            files[url.lastPathComponent] = try CreatorPersistence.bytes(url, limit: url.lastPathComponent == "preview.jpg" ? 512 * 1024 : 256 * 1024)
        }
        let metadata = files[CreatorTemplate.metadataFile]!
        let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        let specification: CreatorTemplate.Specification
        let manifest: Self?
        let rebuilt: [String: Data]
        if object?["bundleVersion"] != nil {
            let decoded = try JSONDecoder().decode(Self.self, from: metadata)
            guard decoded.schemaVersion == 1, decoded.bundleVersion == 2, decoded.policyVersion == 1,
                  decoded.sdkVersion == 1, decoded.runtimePolicy == "trustedTemplateV1" else { throw CreatorPersistence.Failure.unsupportedVersion }
            guard (decoded.packaging == .sealed) == (files["preview.jpg"] != nil) else { throw CreatorPersistence.Failure.incompleteBundle }
            specification = decoded.specification
            manifest = decoded
            rebuilt = try Self.files(for: specification, poster: files["preview.jpg"])
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
