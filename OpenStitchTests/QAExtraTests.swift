import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import OpenStitch

/// Independent, hermetic QA coverage added by the QA pass. Every fixture is generated in
/// code inside a per-test temporary directory; nothing depends on the developer's files.
final class QAExtraTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStitchQA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - EXIF orientation

    /// A JPEG stored as 600x300 with EXIF orientation 6 displays as 300x600. Metadata and
    /// loadImage must both report/return the upright (swapped) dimensions, and the loaded
    /// pixels must actually be rotated, not merely resized.
    func testEXIFOrientationSixSwapsDimensionsAndUprightsPixels() throws {
        // Stored image: top half red, bottom half blue.
        let stored = twoToneImage(width: 600, height: 300, topRed: true)

        let orientation6 = try writeJPEG(stored, orientation: 6, name: "orientation-6.jpg")
        let metadata = try XCTUnwrap(ImageLoader.metadata(for: orientation6))
        XCTAssertEqual(metadata.pixelWidth, 300, "Orientation 6 swaps stored width/height")
        XCTAssertEqual(metadata.pixelHeight, 600)

        let loaded = try XCTUnwrap(ImageLoader.loadImage(url: orientation6), "Orientation 6 JPEG must decode")
        XCTAssertEqual(loaded.width, 300)
        XCTAssertEqual(loaded.height, 600)

        // Rotating 90° CW maps the stored top half onto the displayed right half.
        let bytes = rgbaBytes(loaded)
        let right = pixel(bytes, width: loaded.width, x: 260, y: 300)
        let left = pixel(bytes, width: loaded.width, x: 40, y: 300)
        XCTAssertTrue(
            right.red > 180 && right.blue < 80,
            "Displayed right half should be the stored top half (red), got \(right)"
        )
        XCTAssertTrue(
            left.blue > 180 && left.red < 80,
            "Displayed left half should be the stored bottom half (blue), got \(left)"
        )

        // Orientation 3 only rotates 180°, so no dimension swap.
        let orientation3 = try writeJPEG(stored, orientation: 3, name: "orientation-3.jpg")
        let metadata3 = try XCTUnwrap(ImageLoader.metadata(for: orientation3))
        XCTAssertEqual(metadata3.pixelWidth, 600)
        XCTAssertEqual(metadata3.pixelHeight, 300)
        let loaded3 = try XCTUnwrap(ImageLoader.loadImage(url: orientation3))
        XCTAssertEqual(loaded3.width, 600)
        XCTAssertEqual(loaded3.height, 300)

        // Orientation 8 rotates 90° CCW: dimensions swap as well.
        let orientation8 = try writeJPEG(stored, orientation: 8, name: "orientation-8.jpg")
        let metadata8 = try XCTUnwrap(ImageLoader.metadata(for: orientation8))
        XCTAssertEqual(metadata8.pixelWidth, 300)
        XCTAssertEqual(metadata8.pixelHeight, 600)
        let loaded8 = try XCTUnwrap(ImageLoader.loadImage(url: orientation8))
        XCTAssertEqual(loaded8.width, 300)
        XCTAssertEqual(loaded8.height, 600)

        // Orientation 1 keeps stored dimensions and pixels.
        let orientation1 = try writeJPEG(stored, orientation: 1, name: "orientation-1.jpg")
        let metadata1 = try XCTUnwrap(ImageLoader.metadata(for: orientation1))
        XCTAssertEqual(metadata1.pixelWidth, 600)
        XCTAssertEqual(metadata1.pixelHeight, 300)
    }

    /// Large sources can be downsampled on load; the longest edge must respect maxPixelSize
    /// and the result must stay decodable at full size when no cap is requested.
    func testLoadImageRespectsMaxPixelSize() throws {
        let image = patternImage(width: 1200, height: 800)
        let url = try writePNG(image, name: "large.png")

        let full = try XCTUnwrap(ImageLoader.loadImage(url: url))
        XCTAssertEqual(full.width, 1200)
        XCTAssertEqual(full.height, 800)

        let small = try XCTUnwrap(ImageLoader.loadImage(url: url, maxPixelSize: 256))
        XCTAssertEqual(Double(max(small.width, small.height)), 256, accuracy: 1, "longest edge must be capped at 256")
        XCTAssertEqual(Double(small.width) / Double(small.height), 1200.0 / 800.0, accuracy: 0.02)

        let thumbnail = try XCTUnwrap(ImageLoader.thumbnail(url: url, maxPixelSize: 80))
        XCTAssertEqual(Double(max(thumbnail.width, thumbnail.height)), 80, accuracy: 1)
    }

    // MARK: - PNG round-trip & exporter helpers

    func testPNGRoundTripIsLossless() throws {
        let image = patternImage(width: 300, height: 200)

        let data = try XCTUnwrap(ImageLoader.pngData(for: image), "pngData must succeed")
        XCTAssertGreaterThan(data.count, 100)

        let decoded = try XCTUnwrap(decodeImage(data))
        XCTAssertEqual(decoded.width, 300)
        XCTAssertEqual(decoded.height, 200)

        let originalBytes = rgbaBytes(image)
        let decodedBytes = rgbaBytes(decoded)
        let maxDiff = maxChannelDifference(originalBytes, decodedBytes)
        XCTAssertLessThanOrEqual(maxDiff, 1, "PNG round-trip must be lossless (max channel diff \(maxDiff))")

        let url = try writePNG(image, name: "round-trip.png")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 100)

        let reloaded = try XCTUnwrap(ImageLoader.loadImage(url: url))
        XCTAssertEqual(reloaded.width, 300)
        XCTAssertEqual(reloaded.height, 200)
        XCTAssertLessThanOrEqual(maxChannelDifference(originalBytes, rgbaBytes(reloaded)), 1)
    }

    func testPNGKeepsTransparency() throws {
        let width = 64
        let height = 64
        let context = try XCTUnwrap(makeContext(width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.clear(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let data = try XCTUnwrap(ImageLoader.pngData(for: image))
        let decoded = try XCTUnwrap(decodeImage(data))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)

        let bytes = rgbaBytes(decoded)
        let opaque = pixel(bytes, width: width, x: 10, y: 10)
        let transparent = pixel(bytes, width: width, x: width - 10, y: 10)
        XCTAssertEqual(opaque.alpha, 255, "Opaque half must stay opaque")
        XCTAssertEqual(transparent.alpha, 0, "Transparent half must stay transparent")
    }

    func testWritePNGAndTemporaryPNG() throws {
        let image = patternImage(width: 40, height: 30)

        let directURL = try writePNG(image, name: "direct.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directURL.path))
        XCTAssertEqual(try XCTUnwrap(ImageLoader.metadata(for: directURL)).pixelWidth, 40)

        let temporaryURL = try ImageLoader.writeTemporaryPNG(image, fileNamePrefix: "QATest")
        addTeardownBlock { try? FileManager.default.removeItem(at: temporaryURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(temporaryURL.lastPathComponent.hasPrefix("QATest-"))
        XCTAssertEqual(temporaryURL.pathExtension, "png")
        let tempMetadata = try XCTUnwrap(ImageLoader.metadata(for: temporaryURL))
        XCTAssertEqual(tempMetadata.pixelWidth, 40)
        XCTAssertEqual(tempMetadata.pixelHeight, 30)
        let temporaryAttributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = try XCTUnwrap(temporaryAttributes[.size] as? Int)
        XCTAssertGreaterThan(size, 50)

        let suggested = ImageLoader.suggestedFileName()
        XCTAssertTrue(
            suggested.range(of: #"^OpenStitch-\d{4}-\d{2}-\d{2}-\d{6}\.png$"#, options: .regularExpression) != nil,
            "Unexpected suggested file name: \(suggested)"
        )
    }

    func testDownscaledCapsLongestEdgeAndNeverUpscales() throws {
        let tall = patternImage(width: 1280, height: 4200)
        let fitted = ImageLoader.downscaled(tall, maxDimension: 600)
        XCTAssertEqual(fitted.height, 600)
        XCTAssertEqual(Double(fitted.width), 183, accuracy: 1.0, "Aspect ratio must be preserved")

        let wide = patternImage(width: 4000, height: 500)
        let fittedWide = ImageLoader.downscaled(wide, maxDimension: 1000)
        XCTAssertEqual(fittedWide.width, 1000)
        XCTAssertEqual(Double(fittedWide.height), 125, accuracy: 1.0)

        let small = patternImage(width: 100, height: 80)
        let untouched = ImageLoader.downscaled(small, maxDimension: 200)
        XCTAssertEqual(untouched.width, 100)
        XCTAssertEqual(untouched.height, 80)
    }

    // MARK: - Stitching edge cases

    func testStitchesTransparentScreenshotsOntoOpaqueBackground() throws {
        let page = patternImage(width: 240, height: 900)
        let first = try crop(page, y: 0, height: 420)
        let second = try crop(page, y: 280, height: 420)

        // Punch a transparent vertical band into both screenshots in the same place.
        let transparentFirst = try withTransparentBand(first, fromX: 200, width: 40)
        let transparentSecond = try withTransparentBand(second, fromX: 200, width: 40)

        let result = try ImageStitcher().stitch([transparentFirst, transparentSecond])
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(Double(result.height), 700, accuracy: 5)
        XCTAssertEqual(Double(result.overlaps[0]), 140, accuracy: 4)

        let bytes = rgbaBytes(result.image)
        let transparentPixel = pixel(bytes, width: result.width, x: 220, y: 200)
        XCTAssertEqual(transparentPixel.alpha, 255, "Output should be opaque for export")
        XCTAssertGreaterThanOrEqual(transparentPixel.red, 250, "Transparent source pixels render on white")
        XCTAssertGreaterThanOrEqual(transparentPixel.green, 250)
        XCTAssertGreaterThanOrEqual(transparentPixel.blue, 250)
    }

    func testTinyScreenshotsStitch() throws {
        let page = patternImage(width: 64, height: 120)
        let first = try crop(page, y: 0, height: 32)
        let second = try crop(page, y: 16, height: 32) // 16 px overlap = 50 %

        let result = try ImageStitcher().stitch([first, second])
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(Double(result.overlaps[0]), 16, accuracy: 2)
        XCTAssertEqual(Double(result.height), 48, accuracy: 2)
    }

    func testDegenerateOnePixelImagesFailGracefully() throws {
        let red = solidImage(red: 1, green: 0, blue: 0, width: 1, height: 1)
        let blue = solidImage(red: 0, green: 0, blue: 1, width: 1, height: 1)

        XCTAssertThrowsError(try ImageStitcher().stitch([red, blue])) { error in
            guard case StitchError.noOverlap(0) = error else {
                return XCTFail("Expected graceful noOverlap, got \(error)")
            }
        }
    }

    func testMixedWidthAndHeightScreenshotsNormalizeToFirstWidth() throws {
        let page = patternImage(width: 300, height: 1200)
        let first = try crop(page, y: 0, height: 400) // 300x400
        let secondCrop = try crop(page, y: 250, height: 400) // 300x400, 150 px overlap
        let wideSecond = try scaled(secondCrop, toWidth: 450) // 450x600

        let result = try ImageStitcher().stitch([first, wideSecond])
        XCTAssertEqual(result.width, 300, "Output width follows the first screenshot")
        XCTAssertEqual(Double(result.overlaps[0]), 150, accuracy: 4)
        XCTAssertEqual(Double(result.height), 650, accuracy: 8)

        // Narrower input must be upscaled to the first screenshot's width too.
        let narrowSecond = try scaled(secondCrop, toWidth: 200) // 200x267
        let resultNarrow = try ImageStitcher().stitch([first, narrowSecond])
        XCTAssertEqual(resultNarrow.width, 300)
        XCTAssertEqual(Double(resultNarrow.height), 650, accuracy: 10)
    }

    func testFourScreenshotsStitch() throws {
        let page = patternImage(width: 200, height: 2000)
        let starts = [0, 240, 480, 720] // 300 tall, 60 px overlap
        let shots = try starts.map { try crop(page, y: $0, height: 300) }

        let result = try ImageStitcher().stitch(shots)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.overlaps.count, 3)
        for (index, overlap) in result.overlaps.enumerated() {
            XCTAssertEqual(Double(overlap), 60, accuracy: 3, "overlap \(index)")
        }
        XCTAssertEqual(Double(result.height), 1020, accuracy: 12)
    }

    func testUnrelatedImagesAreRejected() throws {
        let first = noiseImage(width: 160, height: 240, seed: 7)
        let second = noiseImage(width: 160, height: 240, seed: 99)

        XCTAssertThrowsError(try ImageStitcher().stitch([first, second])) { error in
            guard case StitchError.noOverlap(0) = error else {
                return XCTFail("Expected noOverlap, got \(error)")
            }
        }
    }

    func testResultTooTallIsRejected() throws {
        let page = patternImage(width: 240, height: 900)
        let first = try crop(page, y: 0, height: 420)
        let second = try crop(page, y: 280, height: 420)

        let configuration = ImageStitcher.Configuration(maximumOutputHeight: 500)
        XCTAssertThrowsError(try ImageStitcher(configuration: configuration).stitch([first, second])) { error in
            guard case StitchError.resultTooTall = error else {
                return XCTFail("Expected resultTooTall, got \(error)")
            }
        }

        // The same pair must succeed with the default 60,000 px budget.
        XCTAssertNoThrow(try ImageStitcher().stitch([first, second]))
    }

    // MARK: - Unsupported files

    func testUnsupportedFilesAreRejected() throws {
        let textURL = tempDirectory.appendingPathComponent("notes.txt")
        try "not an image".write(to: textURL, atomically: true, encoding: .utf8)
        let pdfURL = tempDirectory.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdfURL)
        let extensionlessURL = tempDirectory.appendingPathComponent("README")
        try "hello".write(to: extensionlessURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(ImageLoader.isSupportedImage(textURL))
        XCTAssertFalse(ImageLoader.isSupportedImage(pdfURL))
        XCTAssertFalse(ImageLoader.isSupportedImage(extensionlessURL))
        XCTAssertFalse(ImageLoader.isSupportedImage(URL(string: "https://example.com/a.png")!))
        XCTAssertTrue(ImageLoader.isSupportedImage(tempDirectory.appendingPathComponent("photo.PNG")))

        XCTAssertNil(ImageLoader.metadata(for: textURL))
        XCTAssertNil(ImageLoader.loadImage(url: textURL))

        // A corrupt file with an image extension is accepted by the extension check but
        // must fail to decode, so the workspace can report it instead of crashing.
        let corruptURL = tempDirectory.appendingPathComponent("corrupt.png")
        try Data(repeating: 0x7F, count: 512).write(to: corruptURL)
        XCTAssertTrue(ImageLoader.isSupportedImage(corruptURL))
        XCTAssertNil(ImageLoader.metadata(for: corruptURL))
        XCTAssertNil(ImageLoader.loadImage(url: corruptURL))
    }

    // MARK: - Performance smoke test

    /// 20 screenshots is the documented maximum. Reports timing and verifies the full
    /// pipeline still produces the expected height within a generous budget.
    func testTwentyScreenshotPerformance() throws {
        let width = 240
        let shotHeight = 400
        let overlap = 100
        let page = patternImage(width: width, height: shotHeight + 19 * (shotHeight - overlap))
        let shots = try (0..<20).map { index in
            try crop(page, y: index * (shotHeight - overlap), height: shotHeight)
        }

        let started = CFAbsoluteTimeGetCurrent()
        let result = try ImageStitcher().stitch(shots)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let expectedHeight = shotHeight + 19 * (shotHeight - overlap)
        XCTAssertEqual(result.overlaps.count, 19)
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(Double(result.height), Double(expectedHeight), accuracy: 45)
        for (index, overlapValue) in result.overlaps.enumerated() {
            XCTAssertEqual(Double(overlapValue), Double(overlap), accuracy: 4, "overlap \(index)")
        }

        let message = "20-image stitch (\(width)x\(shotHeight) each, 19 overlaps) took "
            + String(format: "%.3f", elapsed) + " s"
        print("[QA-PERF] \(message)")
        XCTContext.runActivity(named: message) { _ in }
        XCTAssertLessThan(elapsed, 20.0, "20-image stitch must stay well under 20 s; took \(elapsed) s")
    }

    // MARK: - Workspace state (app logic)

    @MainActor
    func testWorkspaceCapsSelectionAtTwentyAndWarns() async throws {
        let urls = try (0..<21).map { index in
            try writePNG(patternImage(width: 40, height: 60), name: "cap-\(index).png")
        }
        let workspace = StitchWorkspace()
        await workspace.add(urls: urls)

        XCTAssertEqual(workspace.screenshots.count, 20, "Only the first 20 screenshots may be imported")
        XCTAssertNil(workspace.result)
        let alert = try XCTUnwrap(workspace.alert, "The cap should be surfaced to the user")
        XCTAssertFalse(alert.message.isEmpty)
        XCTAssertTrue(alert.message.contains("20"))
    }

    @MainActor
    func testWorkspaceRejectsNonImageFiles() async throws {
        let textURL = tempDirectory.appendingPathComponent("readme.txt")
        try "hello".write(to: textURL, atomically: true, encoding: .utf8)

        let workspace = StitchWorkspace()
        await workspace.add(urls: [textURL])

        XCTAssertTrue(workspace.screenshots.isEmpty)
        let alert = try XCTUnwrap(workspace.alert)
        XCTAssertTrue(alert.title.contains("add screenshots"), "Unexpected title: \(alert.title)")
    }

    @MainActor
    func testWorkspaceStitchSuccessAndNoOverlapAlert() async throws {
        // Success path: three overlapping crops.
        let page = patternImage(width: 240, height: 1200)
        let shots = try [0, 280, 560].map { start in
            try crop(page, y: start, height: 420)
        }
        let urls = try shots.enumerated().map { index, image in
            try writePNG(image, name: "workspace-\(index).png")
        }

        let workspace = StitchWorkspace()
        await workspace.add(urls: urls)
        XCTAssertEqual(workspace.screenshots.count, 3)
        XCTAssertTrue(workspace.canStitch)

        await workspace.stitch()
        let result = try XCTUnwrap(workspace.result, "Stitching 3 overlapping screenshots must succeed")
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.overlaps.count, 2)
        XCTAssertTrue(workspace.isShowingResult, "The result sheet should be presented automatically")
        XCTAssertNil(workspace.alert)

        // Failure path: unrelated solid colours must surface the error alert and no result.
        workspace.clear()
        let redURL = try writePNG(solidImage(red: 1, green: 0, blue: 0, width: 600, height: 900), name: "red.png")
        let blueURL = try writePNG(solidImage(red: 0, green: 0, blue: 1, width: 600, height: 900), name: "blue.png")
        await workspace.add(urls: [redURL, blueURL])
        await workspace.stitch()

        XCTAssertNil(workspace.result)
        XCTAssertFalse(workspace.isShowingResult)
        let alert = try XCTUnwrap(workspace.alert, "A no-overlap stitch must present an alert")
        XCTAssertTrue(alert.title.contains("stitch screenshots"), "Unexpected title: \(alert.title)")
        XCTAssertTrue(alert.message.contains("overlap"), "Unexpected message: \(alert.message)")
    }

    @MainActor
    func testWorkspaceEditsInvalidateResult() async throws {
        let page = patternImage(width: 200, height: 1200)
        let shots = try [0, 280, 560].map { start in
            try crop(page, y: start, height: 420)
        }
        let urls = try shots.enumerated().map { index, image in
            try writePNG(image, name: "edit-\(index).png")
        }
        let workspace = StitchWorkspace()
        await workspace.add(urls: urls)
        await workspace.stitch()
        XCTAssertNotNil(workspace.result)

        workspace.move(from: 0, by: 1)
        XCTAssertNil(workspace.result, "Reordering must invalidate the previous result")

        workspace.move(from: 1, by: -1) // restore top-to-bottom order
        await workspace.stitch()
        XCTAssertNotNil(workspace.result)

        workspace.remove(at: 0)
        XCTAssertNil(workspace.result, "Removing must invalidate the previous result")

        let fileName = try XCTUnwrap(workspace.screenshots.first?.fileName)
        XCTAssertEqual(fileName, "edit-1.png", "Removal should keep the remaining order")
    }

    // MARK: - Fixtures

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

    /// Deterministic high-frequency pattern so overlap detection has real structure.
    private func patternImage(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for y in stride(from: 0, to: height, by: 20) {
            let red = CGFloat((y * 37) % 256) / 255
            let green = CGFloat((y * 91) % 256) / 255
            let blue = CGFloat((y * 53) % 256) / 255
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 10 + (y % 29), y: y, width: max(1, width - 60), height: 12))

            context.setFillColor(CGColor(red: 0.12, green: CGFloat((y * 17) % 256) / 255, blue: 0.85, alpha: 1))
            context.fill(CGRect(x: max(0, width - 40), y: y + 14, width: 24, height: 5))
        }
        return context.makeImage()!
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Independently seeded random RGB noise. Channels must be independent: a fixture with
    /// a shared structural ramp is *not* unrelated content and can legitimately match.
    private func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        let context = makeContext(width: width, height: height)!
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func nextChannel() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33 & 0xFF) / 255
        }
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(
                    CGColor(red: nextChannel(), green: nextChannel(), blue: nextChannel(), alpha: 1)
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    private func twoToneImage(width: Int, height: Int, topRed: Bool) -> CGImage {
        let context = makeContext(width: width, height: height)!
        let topColor = topRed
            ? CGColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1)
            : CGColor(red: 0.08, green: 0.08, blue: 0.85, alpha: 1)
        let bottomColor = topRed
            ? CGColor(red: 0.08, green: 0.08, blue: 0.85, alpha: 1)
            : CGColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1)
        // Quartz origin is bottom-left: the "top" half is the upper y range.
        context.setFillColor(bottomColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(topColor)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    private func withTransparentBand(_ image: CGImage, fromX x: Int, width bandWidth: Int) throws -> CGImage {
        let context = try XCTUnwrap(makeContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.clear(CGRect(x: x, y: 0, width: bandWidth, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    private func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else {
            throw StitchError.renderingFailed
        }
        return cropped
    }

    private func scaled(_ image: CGImage, toWidth width: Int) throws -> CGImage {
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        let context = try XCTUnwrap(makeContext(width: width, height: height))
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @discardableResult
    private func writePNG(_ image: CGImage, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try ImageLoader.writePNG(image, to: url)
        return url
    }

    private func writeJPEG(_ image: CGImage, orientation: UInt32, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageLoaderError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.98
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageLoaderError.encodingFailed
        }
        return url
    }

    private func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders into a known premultiplied RGBA layout so pixels can be compared.
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
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
    }

    private func maxChannelDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return .max }
        var maximum = 0
        for index in stride(from: 0, to: lhs.count, by: 4) {
            for channel in 0..<4 {
                maximum = max(maximum, abs(Int(lhs[index + channel]) - Int(rhs[index + channel])))
            }
        }
        return maximum
    }
}
