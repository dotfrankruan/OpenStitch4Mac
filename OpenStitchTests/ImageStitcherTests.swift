import CoreGraphics
import XCTest
@testable import OpenStitch

final class ImageStitcherTests: XCTestCase {
    func testStitchesOverlappingCrops() throws {
        let source = makePatternImage(width: 240, height: 900)
        let first = try crop(source, y: 0, height: 420)
        let second = try crop(source, y: 280, height: 420)

        let result = try ImageStitcher().stitch([first, second])

        XCTAssertEqual(result.overlaps.count, 1)
        XCTAssertEqual(Double(result.overlaps[0]), 140, accuracy: 4)
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(Double(result.height), 700, accuracy: 4)
    }

    func testStitchesThreeScreenshots() throws {
        let source = makePatternImage(width: 240, height: 1200)
        let first = try crop(source, y: 0, height: 420)
        let second = try crop(source, y: 280, height: 420)
        let third = try crop(source, y: 560, height: 420)

        let result = try ImageStitcher().stitch([first, second, third])

        XCTAssertEqual(result.overlaps.count, 2)
        XCTAssertEqual(Double(result.overlaps[0]), 140, accuracy: 5)
        XCTAssertEqual(Double(result.overlaps[1]), 140, accuracy: 5)
        XCTAssertEqual(Double(result.height), 980, accuracy: 8)
    }

    func testRejectsImagesWithoutOverlap() throws {
        let first = solidImage(red: 1, green: 0, blue: 0)
        let second = solidImage(red: 0, green: 0, blue: 1)

        XCTAssertThrowsError(try ImageStitcher().stitch([first, second])) { error in
            guard case StitchError.noOverlap(0) = error else {
                return XCTFail("Expected noOverlap, got \(error)")
            }
        }
    }

    func testRequiresTwoImages() {
        let single = solidImage(red: 1, green: 1, blue: 1)

        XCTAssertThrowsError(try ImageStitcher().stitch([single])) { error in
            guard case StitchError.notEnoughImages = error else {
                return XCTFail("Expected notEnoughImages, got \(error)")
            }
        }
        XCTAssertThrowsError(try ImageStitcher().stitch([])) { error in
            guard case StitchError.notEnoughImages = error else {
                return XCTFail("Expected notEnoughImages, got \(error)")
            }
        }
    }

    func testRejectsTooTallResult() throws {
        let source = makePatternImage(width: 240, height: 900)
        let first = try crop(source, y: 0, height: 420)
        let second = try crop(source, y: 280, height: 420)

        let tightConfiguration = ImageStitcher.Configuration(maximumOutputHeight: 500)
        XCTAssertThrowsError(try ImageStitcher(configuration: tightConfiguration).stitch([first, second])) { error in
            guard case StitchError.resultTooTall = error else {
                return XCTFail("Expected resultTooTall, got \(error)")
            }
        }
    }

    func testNormalizesDifferentWidths() throws {
        let source = makePatternImage(width: 240, height: 900)
        let first = try crop(source, y: 0, height: 420)
        let secondCrop = try crop(source, y: 280, height: 420)
        let wideSecond = try scaled(secondCrop, toWidth: 480)

        let result = try ImageStitcher().stitch([first, wideSecond])

        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(Double(result.height), 700, accuracy: 8)
        XCTAssertEqual(Double(result.overlaps[0]), 140, accuracy: 8)
    }

    func testPreservesTopToBottomOrder() throws {
        let source = makePatternImage(width: 240, height: 900)
        let first = try crop(source, y: 0, height: 420)
        let second = try crop(source, y: 280, height: 420)

        let result = try ImageStitcher().stitch([first, second])

        let stitchedBytes = rgbaBytes(result.image)
        let firstBytes = rgbaBytes(first)
        let secondBytes = rgbaBytes(second)

        XCTAssertEqual(
            pixelRow(stitchedBytes, width: result.width, row: 0),
            pixelRow(firstBytes, width: first.width, row: 0),
            "The first screenshot should be at the top of the stitched image."
        )
        XCTAssertEqual(
            pixelRow(stitchedBytes, width: result.width, row: result.height - 1),
            pixelRow(secondBytes, width: second.width, row: second.height - 1),
            "The last screenshot should be at the bottom of the stitched image."
        )
    }

    // MARK: - Helpers

    private func makePatternImage(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for y in stride(from: 0, to: height, by: 30) {
            let red = CGFloat((y * 37) % 256) / 255
            let green = CGFloat((y * 91) % 256) / 255
            let blue = CGFloat((y * 53) % 256) / 255
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 12 + (y % 37), y: y, width: 170, height: 17))

            context.setFillColor(CGColor(red: 0.15, green: CGFloat((y * 29) % 256) / 255, blue: 0.85, alpha: 1))
            context.fill(CGRect(x: 190, y: y + 19, width: 40, height: 8))
        }
        return context.makeImage()!
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = makeContext(width: 240, height: 420)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 420))
        return context.makeImage()!
    }

    private func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else {
            throw StitchError.renderingFailed
        }
        return cropped
    }

    private func scaled(_ image: CGImage, toWidth width: Int) throws -> CGImage {
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        guard let context = makeContext(width: width, height: height) else {
            throw StitchError.renderingFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw StitchError.renderingFailed }
        return output
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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

    /// Renders an image into a known RGBA layout so rows can be compared.
    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private var colorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private func pixelRow(_ bytes: [UInt8], width: Int, row: Int) -> [UInt8] {
        let start = row * width * 4
        return Array(bytes[start..<(start + width * 4)])
    }
}
