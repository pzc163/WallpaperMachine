import Foundation
import ImageIO

/// Verifies persisted native measurements against the actual encoded JPEG.
enum CreatorPosterMetadata {
    static func validate(jpeg: Data, metrics: [String: Double], context: ValidationReport.Context) throws {
        try CreatorBundleManifest.validatePoster(jpeg)
        guard Set(metrics.keys) == ["posterWidth", "posterHeight", "opaqueSamples", "pixelSamples", "distinctColors"],
              metrics.values.allSatisfy({ $0.isFinite && $0.rounded() == $0 }),
              metrics["pixelSamples"] == 1024, (922...1024).contains(metrics["opaqueSamples"] ?? 0),
              (2...1024).contains(metrics["distinctColors"] ?? 0),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              metrics["posterWidth"] == Double(width), metrics["posterHeight"] == Double(height),
              abs(Double(width) / Double(height) - Double(context.width) / Double(context.height)) <= 0.02
        else { throw CreatorRuntimeFailure.invalidCapture }
    }
}
