import CoreGraphics
import Foundation

/// The stitched output plus the detected overlap for every adjacent pair.
struct StitchResult {
    /// The fully rendered long screenshot at original resolution.
    let image: CGImage
    /// Rows removed from the bottom of each screenshot, in source-image pixels.
    let overlaps: [Int]

    var width: Int { image.width }
    var height: Int { image.height }
}

enum StitchError: LocalizedError {
    case notEnoughImages
    case unreadableImage(Int)
    case noOverlap(Int)
    case resultTooTall
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .notEnoughImages:
            return "Choose at least two screenshots."
        case .unreadableImage(let index):
            return "Screenshot \(index + 1) could not be read."
        case .noOverlap(let index):
            return "Could not find enough overlap between screenshots \(index + 1) and \(index + 2)."
        case .resultTooTall:
            return "The result is too tall to render. Try using fewer screenshots."
        case .renderingFailed:
            return "The stitched image could not be rendered."
        }
    }
}

/// Stitches vertically consecutive screenshots by locating the overlapping content
/// between each adjacent pair. The implementation mirrors the iOS engine one-to-one;
/// only the image type changed (`CGImage` instead of `UIImage`) and the renderer is a
/// plain `CGContext` instead of `UIGraphicsImageRenderer`.
struct ImageStitcher {
    struct Configuration {
        /// Width (in pixels) that every screenshot is sampled to before comparing rows.
        var analysisWidth = 144
        var minimumOverlapRatio = 0.08
        var maximumOverlapRatio = 0.92
        /// Mean absolute row difference (0...1) below which a match is accepted.
        var maximumDifference = 0.105
        /// Fraction of the width ignored on both sides while comparing.
        var horizontalInsetRatio = 0.08
        var maximumOutputHeight = 60_000

        static let standard = Configuration()
    }

    let configuration: Configuration

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    func stitch(_ sourceImages: [CGImage]) throws -> StitchResult {
        guard sourceImages.count >= 2 else { throw StitchError.notEnoughImages }

        let images = try normalizedImages(sourceImages)
        let analyses = try images.enumerated().map { index, image in
            guard let analysis = GrayImage(image: image, targetWidth: configuration.analysisWidth) else {
                throw StitchError.unreadableImage(index)
            }
            return analysis
        }

        var overlapPixels: [Int] = []
        for index in 0..<(analyses.count - 1) {
            guard let match = bestOverlap(upper: analyses[index], lower: analyses[index + 1]),
                  match.difference <= configuration.maximumDifference else {
                throw StitchError.noOverlap(index)
            }

            let scale = CGFloat(images[index + 1].height) / CGFloat(analyses[index + 1].height)
            overlapPixels.append(Int((CGFloat(match.rows) * scale).rounded()))
        }

        let outputHeight = images[0].height + zip(images.dropFirst(), overlapPixels).reduce(0) { total, pair in
            total + pair.0.height - pair.1
        }
        guard outputHeight > 0, outputHeight <= configuration.maximumOutputHeight else {
            throw StitchError.resultTooTall
        }

        let outputWidth = images[0].width
        let rendered = try render(images: images, overlaps: overlapPixels, width: outputWidth, height: outputHeight)
        return StitchResult(image: rendered, overlaps: overlapPixels)
    }

    // MARK: - Normalization

    private func normalizedImages(_ images: [CGImage]) throws -> [CGImage] {
        guard let first = images.first else { throw StitchError.notEnoughImages }
        let targetWidth = first.width
        guard targetWidth > 0, first.height > 0 else { throw StitchError.unreadableImage(0) }

        return try images.enumerated().map { index, image in
            guard image.width > 0, image.height > 0 else { throw StitchError.unreadableImage(index) }
            let targetHeight = max(1, Int((CGFloat(image.height) * CGFloat(targetWidth) / CGFloat(image.width)).rounded()))
            if image.width == targetWidth {
                return image
            }
            guard let context = Self.makeBitmapContext(width: targetWidth, height: targetHeight) else {
                throw StitchError.renderingFailed
            }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let scaled = context.makeImage() else { throw StitchError.renderingFailed }
            return scaled
        }
    }

    // MARK: - Rendering

    private func render(images: [CGImage], overlaps: [Int], width: Int, height: Int) throws -> CGImage {
        guard let context = Self.makeBitmapContext(width: width, height: height) else {
            throw StitchError.renderingFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Core Graphics bitmaps use a bottom-left origin while the output is composed
        // from the top down, so each tile's vertical position is mirrored around the
        // canvas height. Screenshots themselves stay right side up.
        var top = 0
        for (index, image) in images.enumerated() {
            let tileHeight = image.height
            let quartzY = height - top - tileHeight
            context.draw(image, in: CGRect(x: 0, y: quartzY, width: width, height: tileHeight))
            top += tileHeight
            if index < overlaps.count {
                top -= overlaps[index]
            }
        }

        guard let output = context.makeImage() else { throw StitchError.renderingFailed }
        return output
    }

    private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Overlap detection

    private func bestOverlap(upper: GrayImage, lower: GrayImage) -> (rows: Int, difference: Double)? {
        let maxRows = min(
            Int(Double(min(upper.height, lower.height)) * configuration.maximumOverlapRatio),
            min(upper.height, lower.height) - 1
        )
        let minRows = max(8, Int(Double(min(upper.height, lower.height)) * configuration.minimumOverlapRatio))
        guard maxRows >= minRows else { return nil }

        let inset = Int(Double(min(upper.width, lower.width)) * configuration.horizontalInsetRatio)
        let xRange = inset..<max(inset + 1, min(upper.width, lower.width) - inset)
        var best: (rows: Int, difference: Double)?

        for rows in minRows...maxRows {
            var rowDifferences = [Double]()
            rowDifferences.reserveCapacity(rows)

            for row in 0..<rows {
                let upperY = upper.height - rows + row
                var sum = 0
                for x in xRange {
                    sum += abs(Int(upper[x, upperY]) - Int(lower[x, row]))
                }
                rowDifferences.append(Double(sum) / Double(xRange.count * 255))
            }

            // Ignore a small number of changing rows such as a blinking cursor or scroll indicator.
            rowDifferences.sort()
            let keptCount = max(1, Int(Double(rowDifferences.count) * 0.9))
            let rawDifference = rowDifferences.prefix(keptCount).reduce(0, +) / Double(keptCount)
            // A tiny preference for longer matches prevents short, flat areas from winning by chance.
            let adjustedDifference = rawDifference - Double(rows) * 0.000002

            if best == nil || adjustedDifference < best!.difference {
                best = (rows, adjustedDifference)
            }
        }
        return best
    }
}

/// A downsampled grayscale copy of a screenshot used for overlap comparison.
private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage, targetWidth: Int) {
        let imageWidth = image.width
        let imageHeight = image.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let scaledWidth = min(targetWidth, imageWidth)
        let scaledHeight = max(1, Int((CGFloat(imageHeight) * CGFloat(scaledWidth) / CGFloat(imageWidth)).rounded()))

        var buffer = [UInt8](repeating: 0, count: scaledWidth * scaledHeight)
        let didDraw = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: scaledWidth,
                    height: scaledHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: scaledWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
            return true
        }
        guard didDraw else { return nil }
        width = scaledWidth
        height = scaledHeight
        pixels = buffer
    }

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }
}
