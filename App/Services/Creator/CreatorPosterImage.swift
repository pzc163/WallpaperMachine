import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes native whole-page pixels; never substitutes a canvas export for a snapshot.
enum CreatorPosterImage {
    static func encode(_ image: NSImage) throws -> (jpeg: Data, metrics: [String: Double]) {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0, source.width <= 8192, source.height <= 8192,
              source.width * source.height <= 16_777_216 else { throw CreatorRuntimeFailure.invalidCapture }
        let scale = min(1, 1280 / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let raw = bitmap.data
        else { throw CreatorRuntimeFailure.invalidCapture }
        bitmap.interpolationQuality = .high
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        var opaque = 0, lit = 0, colors = Set<UInt32>()
        for y in 0..<32 { for x in 0..<32 {
            let offset = (min(height - 1, (2 * y + 1) * height / 64) * width + min(width - 1, (2 * x + 1) * width / 64)) * 4
            if bytes[offset + 3] >= 250 { opaque += 1 }
            if max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) >= 12 { lit += 1 }
            colors.insert(UInt32(bytes[offset] / 4) << 16 | UInt32(bytes[offset + 1] / 4) << 8 | UInt32(bytes[offset + 2] / 4))
        } }
        guard opaque >= 922, lit >= 4, colors.count >= 2, let pixels = bitmap.makeImage() else { throw CreatorRuntimeFailure.invalidCapture }
        let metrics = ["posterWidth": Double(width), "posterHeight": Double(height), "opaqueSamples": Double(opaque),
                       "pixelSamples": 1024.0, "distinctColors": Double(colors.count)]
        for quality in [0.86, 0.68] {
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CreatorRuntimeFailure.invalidCapture }
            CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CreatorRuntimeFailure.invalidCapture }
            if data.length <= 512 * 1024 {
                let result = data as Data
                try CreatorBundleManifest.validatePoster(result)
                return (result, metrics)
            }
        }
        throw CreatorRuntimeFailure.invalidCapture
    }
}
