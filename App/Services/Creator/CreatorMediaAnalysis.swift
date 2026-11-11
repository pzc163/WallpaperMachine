import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WallpaperMedia

/// One-shot native import/analysis. Never sends a file or a path to a model.
enum CreatorMediaAnalysis {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static func prepare(_ url: URL) async throws -> CreatorPreparedMedia {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else { throw CreatorPersistence.Failure.invalidRecord }
        let data = try CreatorPersistence.bytes(url, limit: CreatorMediaFile.maximumBytes)
        if imageExtensions.contains(ext) { return try image(data) }
        if ext == "webm" {
            guard case .success(let file) = WebMOpening.open(data: data), file.duration.seconds.isFinite,
                  file.duration.seconds > 0, file.duration.seconds <= 600,
                  file.codedSize.width > 0, file.codedSize.height > 0, file.codedSize.width <= 4096, file.codedSize.height <= 4096,
                  let frame = file.copyPosterImage(at: .zero) else { throw CreatorPersistence.Failure.invalidRecord }
            return try prepared(base: data, ext: ext, kind: .video, frame: frame)
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 600, try await asset.load(.isPlayable) else { throw CreatorPersistence.Failure.invalidRecord }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CreatorPersistence.Failure.invalidRecord }
        let dimensions = try await track.load(.naturalSize)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 4096, dimensions.height <= 4096 else { throw CreatorPersistence.Failure.tooLarge }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 2048, height: 2048)
        let frame = try await withTaskCancellationHandler { try await generator.image(at: .zero).image } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        // Decode and digest from the same selected file, and detect replacement during analysis.
        guard data == (try CreatorPersistence.bytes(url, limit: CreatorMediaFile.maximumBytes)) else { throw CreatorRuntimeFailure.staleInput }
        return try prepared(base: data, ext: ext, kind: .video, frame: frame)
    }
    static func image(_ data: Data) throws -> CreatorPreparedMedia {
        guard data.count <= CreatorMediaFile.maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 67_108_864,
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
        else { throw CreatorPersistence.Failure.invalidRecord }
        // Normalization removes EXIF/GPS and bounds texture allocation; originals are never altered.
        return try prepared(base: encode(frame, type: .jpeg, quality: 0.9), ext: "jpg", kind: .image, frame: frame)
    }
    private static func prepared(base: Data, ext: String, kind: CreatorMediaBinding.Kind, frame: CGImage) throws -> CreatorPreparedMedia {
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false]), original = CIImage(cgImage: frame)
        let factor = min(1, 512 / Double(max(frame.width, frame.height)))
        let reduced = original.transformed(by: .init(scaleX: factor, y: factor))
        guard let small = context.createCGImage(reduced, from: reduced.extent.integral) else { throw CreatorPersistence.Failure.invalidRecord }
        let luminance = reduced.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)])
        guard let mask = context.createCGImage(luminance, from: reduced.extent.integral) else { throw CreatorPersistence.Failure.invalidRecord }
        let thumbnailBytes = try encode(small, type: .jpeg, quality: 0.72), maskBytes = try encode(mask, type: .png)
        let baseFile = try CreatorMediaFile.make(base, extension: ext), thumbnail = try CreatorMediaFile.make(thumbnailBytes, extension: "jpg"), maskFile = try CreatorMediaFile.make(maskBytes, extension: "png")
        let binding = CreatorMediaBinding(kind: kind, width: frame.width, height: frame.height, base: baseFile, mask: maskFile, thumbnail: thumbnail, palette: palette(original, context: context))
        var files = [baseFile.path: base]
        files[thumbnail.path] = thumbnailBytes; files[maskFile.path] = maskBytes
        let result = CreatorPreparedMedia(binding: binding, files: files)
        try result.validate(); return result
    }
    private static func palette(_ image: CIImage, context: CIContext) -> [String] {
        let image = image.transformed(by: .init(scaleX: 64 / image.extent.width, y: 64 / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        context.render(image, toBitmap: &pixels, rowBytes: 256, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index+1]), b = Int(pixels[index+2]), key = (r >> 5) * 64 + (g >> 5) * 8 + (b >> 5)
            let old = bins[key] ?? (0, 0, 0, 0); bins[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        return bins.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(5).map {
            String(format: "#%02x%02x%02x", $0.value.r / $0.value.count, $0.value.g / $0.value.count, $0.value.b / $0.value.count)
        }
    }
    static func encode(_ image: CGImage, type: UTType, quality: Double = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw CreatorPersistence.Failure.invalidRecord }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CreatorPersistence.Failure.invalidRecord }
        return data as Data
    }
}
