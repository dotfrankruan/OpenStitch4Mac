import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A tiny wrapper that lets an immutable `CGImage` cross a concurrency boundary.
/// `CGImage` is documented as immutable and thread safe; it simply is not annotated
/// `Sendable` by the SDK.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// A wrapper used to hand a non-`Sendable` stitching result back to the main actor.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Reads images from disk (with correct orientation handling) and encodes PNGs.
enum ImageLoader {
    struct Metadata: Sendable, Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// True when the URL looks like an image file that ImageIO may be able to decode.
    static func isSupportedImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    /// Original pixel dimensions, taking the EXIF orientation into account.
    static func metadata(for url: URL) -> Metadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // Orientations 5–8 rotate by 90° or 270°, which swaps width and height.
        return orientation >= 5
            ? Metadata(pixelWidth: height, pixelHeight: width)
            : Metadata(pixelWidth: width, pixelHeight: height)
    }

    /// Loads an image, applying its EXIF orientation and optionally downsampling it.
    /// `maxPixelSize` is the longest edge of the returned image.
    static func loadImage(url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }

        let fullSize = max(width, height)
        guard fullSize > 0 else { return nil }
        let longestEdge = min(maxPixelSize ?? fullSize, fullSize)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Thumbnail creation can return an image whose long edge overshoots slightly
        // when the source is small; never let that happen for full-resolution loads.
        guard image.width > 0, image.height > 0 else { return nil }
        return image
    }

    /// A small thumbnail used by the screenshot list.
    static func thumbnail(url: URL, maxPixelSize: Int = 320) -> CGImage? {
        loadImage(url: url, maxPixelSize: maxPixelSize)
    }

    /// Downscales an image so that its longest edge is at most `maxDimension` points.
    /// Used only for on-screen previews; exported files always keep full resolution.
    static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxDimension else { return image }
        let scale = CGFloat(maxDimension) / CGFloat(longestEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// PNG-encodes an image, preserving the original pixel dimensions.
    static func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes an image to disk as a PNG file.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = pngData(for: image) else { throw ImageLoaderError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    /// Writes a PNG into a temporary directory for sharing or opening in another app.
    static func writeTemporaryPNG(_ image: CGImage, fileNamePrefix: String = "OpenStitch") throws -> URL {
        let name = "\(fileNamePrefix)-\(Self.timestamp()).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try writePNG(image, to: url)
        return url
    }

    /// Suggested file name for exports, e.g. `OpenStitch-2026-10-27-193000.png`.
    static func suggestedFileName(prefix: String = "OpenStitch") -> String {
        "\(prefix)-\(Self.timestamp()).png"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum ImageLoaderError: LocalizedError {
    case encodingFailed
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The image could not be encoded as a PNG."
        case .unreadable(let url):
            return "\"\(url.lastPathComponent)\" could not be opened as an image."
        }
    }
}
