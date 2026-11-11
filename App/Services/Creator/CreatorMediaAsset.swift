import Foundation
import ImageIO

/// Only content-addressed, flat asset names are ever exposed to a wallpaper.
struct CreatorMediaFile: Codable, Equatable, Sendable {
    let path: String
    let mime: String
    let bytes: Int
    let digest: String
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumBundleBytes = 128 * 1024 * 1024
    static let types = ["jpg": "image/jpeg", "png": "image/png", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"]
    func validate() throws {
        guard CreatorPersistence.validDigest(digest), (1...Self.maximumBytes).contains(bytes),
              let ext = path.split(separator: ".").last.map(String.init), Self.types[ext] == mime,
              path == "assets/" + digest + "." + ext else { throw CreatorPersistence.Failure.invalidRecord }
    }
    var url: String { "wm-media://bundle/" + path }
    static func make(_ data: Data, extension ext: String) throws -> Self {
        let digest = CreatorPersistence.hash(data)
        guard let mime = types[ext] else { throw CreatorPersistence.Failure.invalidRecord }
        let result = Self(path: "assets/" + digest + "." + ext, mime: mime, bytes: data.count, digest: digest)
        try result.validate(); return result
    }
}

struct CreatorMediaBinding: Codable, Equatable, Sendable {
    static let parameters: [CreatorParameterSchema.Parameter] = [
        .init(id: "mediaFill", label: "Media fill", type: .number, defaultValue: .number(0), min: 0, max: 2, step: 1),
        .init(id: "mediaExposure", label: "Media exposure", type: .number, defaultValue: .number(0), min: -2, max: 1, step: 0.01),
        .init(id: "mediaSpeed", label: "Media speed", type: .number, defaultValue: .number(1), min: 0.25, max: 2, step: 0.01)
    ]
    static func validateParameters(_ schema: CreatorParameterSchema) throws {
        for native in parameters {
            guard let p = schema.parameters.first(where: { $0.id == native.id }), p.type == native.type,
                  p.min == native.min, p.max == native.max, p.step == native.step else { throw CreatorRepairIssue.field("properties", .range, policy: true) }
        }
        guard case .number(let fill) = schema.values["mediaFill"], fill.rounded() == fill else { throw CreatorPersistence.Failure.invalidRecord }
    }
    enum Kind: String, Codable, Sendable { case image, video }
    var version = 1
    let kind: Kind
    let width: Int
    let height: Int
    let base: CreatorMediaFile
    let mask: CreatorMediaFile
    let thumbnail: CreatorMediaFile
    let palette: [String]
    var files: [CreatorMediaFile] { [base, mask, thumbnail] }
    func validate() throws {
        guard version == 1, (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216,
              base.mime.hasPrefix(kind == .image ? "image/" : "video/"), mask.mime == "image/png", thumbnail.mime == "image/jpeg",
              (1...5).contains(palette.count), palette.allSatisfy({ $0.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil })
        else { throw CreatorPersistence.Failure.invalidRecord }
        for file in files { try file.validate() }
    }
    var promptContext: String {
        "User-selected local \(kind.rawValue), \(width)x\(height). Native palette: \(palette.joined(separator: ", ")). uBaseTexture contains the selected media; uLumaMask contains its luminance. Preserve the native media binding. Do not invent paths, URLs or image bytes."
    }
}

struct CreatorPreparedMedia: Sendable {
    let binding: CreatorMediaBinding
    let files: [String: Data]
    func validate() throws {
        try binding.validate()
        guard Set(files.keys) == Set(binding.files.map(\.path)), files.values.reduce(0, { $0 + $1.count }) <= CreatorMediaFile.maximumBundleBytes else { throw CreatorPersistence.Failure.invalidRecord }
        for item in binding.files {
            guard let data = files[item.path], data.count == item.bytes, CreatorPersistence.hash(data) == item.digest else { throw CreatorTemplate.Failure.changedContent }
            if item.mime.hasPrefix("image/") {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                      CGImageSourceGetType(source) as String? == (item.mime == "image/png" ? "public.png" : "public.jpeg"),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 2048, h <= 2048,
                      item == binding.base ? (w == binding.width && h == binding.height) : (w <= 512 && h <= 512)
                else { throw CreatorPersistence.Failure.invalidRecord }
            }
        }
    }
}
