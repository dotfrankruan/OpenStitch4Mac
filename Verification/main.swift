import CoreGraphics
import Foundation
import ImageIO

// Independent CLI harness for the OpenStitch stitching engine. Compiles the exact
// engine sources from OpenStitch/Stitching/ with swiftc (no AppKit / SwiftUI), stitches
// the three bundled sample screenshots, writes the PNG, and pixel-compares it against
// the reference page image.
//
// Build (from repo root):
//   swiftc -O -swift-version 5 \
//     OpenStitch/Stitching/ImageStitcher.swift \
//     OpenStitch/Stitching/ImageLoader.swift \
//     Verification/main.swift \
//     -o Verification/out/stitch-cli
//
// Usage:
//   Verification/out/stitch-cli [--tolerance N] [--make-solid path R G B W H]

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = rootURL.appendingPathComponent("Verification/out", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var failures: [String] = []
var checks: [(String, Bool, String)] = []

func record(_ name: String, _ passed: Bool, _ detail: String) {
    checks.append((name, passed, detail))
    print("\(passed ? "PASS" : "FAIL")  \(name)  — \(detail)")
    if !passed { failures.append("\(name): \(detail)") }
}

// MARK: - Utility modes

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if let index = args.firstIndex(of: "--make-solid"), args.count >= index + 6 {
        let path = args[index + 1]
        let red = Double(args[index + 2]) ?? 0
        let green = Double(args[index + 3]) ?? 0
        let blue = Double(args[index + 4]) ?? 0
        let width = Int(args[index + 5]) ?? 600
        let height = Int(args[index + 6]) ?? 900
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        try ImageLoader.writePNG(image, to: URL(fileURLWithPath: path))
        print("wrote solid \(width)x\(height) PNG to \(path)")
        exit(0)
    }
} catch {
    FileHandle.standardError.write(Data("make-solid failed: \(error)\n".utf8))
    exit(1)
}

// MARK: - Rendering helpers

func rgbaBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let context = CGContext(
                data: base,
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

struct CompareMetrics {
    var comparedWidth = 0
    var comparedHeight = 0
    var mismatchedPixels = 0
    var maxChannelDiff = 0
    var meanAbsDiff = 0.0
    var rowsWithMismatch: [Int] = []
    var heightOffset = 0
}

func compare(_ lhs: CGImage, _ rhs: CGImage, tolerance: Int, verticalOffset: Int = 0) -> CompareMetrics {
    let a = rgbaBytes(lhs)
    let b = rgbaBytes(rhs)
    let width = min(lhs.width, rhs.width)
    guard width > 0 else { return CompareMetrics() }

    var metrics = CompareMetrics()
    metrics.heightOffset = verticalOffset
    let heightA = lhs.height
    let heightB = rhs.height
    var totalAbs = 0
    var samples = 0
    var mismatchedRows = Set<Int>()

    for y in 0..<heightA {
        let yb = y + verticalOffset
        guard yb >= 0, yb < heightB else { continue }
        metrics.comparedHeight += 1
        var rowMismatch = false
        for x in 0..<width {
            let ia = (y * lhs.width + x) * 4
            let ib = (yb * rhs.width + x) * 4
            var pixelDiff = 0
            for channel in 0..<3 {
                let diff = abs(Int(a[ia + channel]) - Int(b[ib + channel]))
                totalAbs += diff
                samples += 1
                if diff > pixelDiff { pixelDiff = diff }
                if diff > metrics.maxChannelDiff { metrics.maxChannelDiff = diff }
            }
            if pixelDiff > tolerance {
                metrics.mismatchedPixels += 1
                rowMismatch = true
            }
        }
        if rowMismatch { mismatchedRows.insert(y) }
    }
    metrics.comparedWidth = width
    metrics.meanAbsDiff = samples > 0 ? Double(totalAbs) / Double(samples) : 0
    metrics.rowsWithMismatch = mismatchedRows.sorted()
    return metrics
}

// MARK: - 1. Load sample screenshots

let shotURLs = (1...3).map { rootURL.appendingPathComponent("Samples/screenshot-\($0).png") }
let expectedShotSize = (width: 1280, height: 1500)
var sampleImages: [CGImage] = []

for (index, url) in shotURLs.enumerated() {
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("missing sample: \(url.path)\n".utf8))
        exit(1)
    }
    guard let metadata = ImageLoader.metadata(for: url) else {
        record("metadata for screenshot-\(index + 1)", false, "metadata returned nil")
        exit(1)
    }
    guard let image = ImageLoader.loadImage(url: url) else {
        record("load screenshot-\(index + 1)", false, "loadImage returned nil")
        exit(1)
    }
    record(
        "load screenshot-\(index + 1)",
        metadata.pixelWidth == expectedShotSize.width
            && metadata.pixelHeight == expectedShotSize.height
            && image.width == expectedShotSize.width
            && image.height == expectedShotSize.height,
        "metadata=\(metadata.pixelWidth)x\(metadata.pixelHeight) decoded=\(image.width)x\(image.height) (expected \(expectedShotSize.width)x\(expectedShotSize.height))"
    )
    sampleImages.append(image)
}

// MARK: - 2. Stitch

let started = CFAbsoluteTimeGetCurrent()
let result: StitchResult
do {
    result = try ImageStitcher(configuration: .standard).stitch(sampleImages)
} catch {
    FileHandle.standardError.write(Data("stitch failed: \(error)\n".utf8))
    exit(1)
}
let elapsed = CFAbsoluteTimeGetCurrent() - started

print("")
print("engine: \(ImageStitcher.Configuration.standard.analysisWidth) px analysis width, "
      + "maxDifference=\(ImageStitcher.Configuration.standard.maximumDifference), "
      + "maxOutputHeight=\(ImageStitcher.Configuration.standard.maximumOutputHeight)")
print("stitched: \(result.width) x \(result.height) px in \(String(format: "%.3f", elapsed)) s")
print("overlaps: \(result.overlaps) px")

record(
    "stitched width == 1280",
    result.width == 1280,
    "actual \(result.width)"
)
record(
    "stitched height in 4196...4200",
    (4196...4200).contains(result.height),
    "actual \(result.height) (ideal 4200 = 3*1500 - 2*150; rounding may drop 1-2 rows)"
)
for (index, overlap) in result.overlaps.enumerated() {
    record(
        "overlap[\(index)] ~= 150 px",
        abs(overlap - 150) <= 2,
        "actual \(overlap)"
    )
}

// MARK: - 3. Write PNG

let stitchedURL = outDir.appendingPathComponent("stitched-samples.png")
do {
    try ImageLoader.writePNG(result.image, to: stitchedURL)
    var size = 0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: stitchedURL.path),
       let byteCount = attributes[.size] as? Int {
        size = byteCount
    }
    let decodeCheck = ImageLoader.metadata(for: stitchedURL)
    record(
        "write stitched PNG",
        size > 0 && decodeCheck?.pixelWidth == result.width && decodeCheck?.pixelHeight == result.height,
        "\(stitchedURL.path) bytes=\(size) decode=\(decodeCheck?.pixelWidth ?? -1)x\(decodeCheck?.pixelHeight ?? -1)"
    )
} catch {
    record("write stitched PNG", false, "\(error)")
}

// MARK: - 4. Pixel compare against the reference page

let pageURL = rootURL.appendingPathComponent("Samples/sample-page-full.png")
let tolerance = 2
if let page = ImageLoader.loadImage(url: pageURL) {
    record(
        "reference page dimensions",
        page.width == 1280 && page.height == 4200,
        "\(page.width)x\(page.height)"
    )

    // A naive whole-image comparison cannot align seams independently: each detected
    // overlap can be 1-2 px longer than the true overlap, which shifts everything below
    // that seam by 1-2 px. Report it for transparency, then compare tile-by-tile.
    var best: CompareMetrics?
    for offset in -3...3 {
        let metrics = compare(result.image, page, tolerance: tolerance, verticalOffset: offset)
        if best == nil || metrics.mismatchedPixels < best!.mismatchedPixels {
            best = metrics
        }
    }
    let naive = best!
    let naiveTotal = max(1, naive.comparedWidth * naive.comparedHeight)
    print("")
    print("naive whole-image compare vs Samples/sample-page-full.png:")
    print("  best global vertical offset: \(naive.heightOffset) px")
    print("  mismatched pixels: \(naive.mismatchedPixels) / \(naiveTotal) "
          + "(\(String(format: "%.4f", 100.0 * Double(naive.mismatchedPixels) / Double(naiveTotal)))%)")
    print("  max channel difference: \(naive.maxChannelDiff), "
          + "mean absolute channel difference: \(String(format: "%.4f", naive.meanAbsDiff))")
    print("  (seam rounding shifts rows below each seam, so this metric is informational only)")

    // Piecewise comparison: every screenshot must reappear pixel-exact in the stitched
    // output, allowing a per-seam cumulative shift of at most 2 px.
    let shotHeights = sampleImages.map(\.height)
    var expectedStarts: [Int] = [0]
    for i in 0..<result.overlaps.count {
        expectedStarts.append(expectedStarts[i] + shotHeights[i] - result.overlaps[i])
    }
    var piecewiseOffsets: [Int] = []
    var piecewiseTotalMismatch = 0
    var piecewiseMaxDiff = 0
    var piecewiseComparedPixels = 0
    for (i, start) in expectedStarts.enumerated() {
        let tileHeight = i < expectedStarts.count - 1
            ? expectedStarts[i + 1] - start
            : result.height - start
        guard tileHeight > 0 else { continue }
        guard let tile = result.image.cropping(
            to: CGRect(x: 0, y: start, width: result.width, height: tileHeight)
        ) else {
            record("tile \(i) crop", false, "cropping failed")
            continue
        }
        var bestTile: (offset: Int, metrics: CompareMetrics)?
        for offset in -3...3 {
            let pageStart = start + offset
            guard pageStart >= 0, pageStart + tileHeight <= page.height else { continue }
            guard let pageTile = page.cropping(
                to: CGRect(x: 0, y: start + offset, width: page.width, height: tileHeight)
            ) else { continue }
            let metrics = compare(tile, pageTile, tolerance: tolerance)
            if bestTile == nil || metrics.mismatchedPixels < bestTile!.metrics.mismatchedPixels {
                bestTile = (offset, metrics)
            }
        }
        guard let bestTile else {
            record("tile \(i) compare", false, "no comparable page crop")
            continue
        }
        let pixels = max(1, bestTile.metrics.comparedWidth * bestTile.metrics.comparedHeight)
        piecewiseComparedPixels += pixels
        piecewiseTotalMismatch += bestTile.metrics.mismatchedPixels
        piecewiseMaxDiff = max(piecewiseMaxDiff, bestTile.metrics.maxChannelDiff)
        piecewiseOffsets.append(bestTile.offset)
        record(
            "tile \(i) (stitched y=\(start), height=\(tileHeight)) matches reference",
            bestTile.metrics.mismatchedPixels == 0 && bestTile.metrics.maxChannelDiff <= tolerance,
            "best page offset=\(bestTile.offset) mismatched=\(bestTile.metrics.mismatchedPixels)/\(pixels) "
                + "maxDiff=\(bestTile.metrics.maxChannelDiff)"
        )
    }
    let piecewisePercent = 100.0 * Double(piecewiseTotalMismatch) / Double(max(1, piecewiseComparedPixels))
    record(
        "every screenshot reappears in the stitched output",
        piecewiseTotalMismatch == 0 && piecewiseMaxDiff <= tolerance,
        "total mismatched=\(piecewiseTotalMismatch) (\(String(format: "%.4f", piecewisePercent))%) "
            + "maxDiff=\(piecewiseMaxDiff) offsets=\(piecewiseOffsets)"
    )
    record(
        "seam rounding is within 0...2 px per seam",
        piecewiseOffsets.allSatisfy { (0...2).contains($0) }
            && zip(piecewiseOffsets, piecewiseOffsets.dropFirst()).allSatisfy { $0 <= $1 },
        "cumulative page offsets=\(piecewiseOffsets) (0, 1, 2 expected for 150->151 px overlap)"
    )
    let missingRows = max(0, page.height - result.height)
    record(
        "stitched result height loses at most 2 rows to rounding",
        missingRows <= 2,
        "stitched=\(result.height) reference=\(page.height) missing=\(missingRows)"
    )
} else {
    record("load reference page", false, "could not decode Samples/sample-page-full.png")
}

// MARK: - 5. Error-path spot checks with the same engine build

func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 600, height: Int = 900) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

do {
    _ = try ImageStitcher().stitch([solid(1, 0, 0), solid(0, 0, 1)])
    record("solid red+blue rejected as no-overlap", false, "stitch unexpectedly succeeded")
} catch let error as StitchError {
    if case .noOverlap(0) = error {
        record("solid red+blue rejected as no-overlap", true, "\(error.errorDescription ?? "")")
    } else {
        record("solid red+blue rejected as no-overlap", false, "wrong error: \(error)")
    }
} catch {
    record("solid red+blue rejected as no-overlap", false, "wrong error type: \(error)")
}

do {
    _ = try ImageStitcher(configuration: ImageStitcher.Configuration(maximumOutputHeight: 500))
        .stitch([try crop(sampleImages[0], y: 0, height: 500), try crop(sampleImages[1], y: 0, height: 500)])
    record("result-too-tall rejected", false, "stitch unexpectedly succeeded")
} catch let error as StitchError {
    if case .resultTooTall = error {
        record("result-too-tall rejected", true, "\(error.errorDescription ?? "")")
    } else {
        record("result-too-tall rejected", false, "wrong error: \(error)")
    }
} catch {
    record("result-too-tall rejected", false, "wrong error type: \(error)")
}

func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
    guard let cropped = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else {
        throw StitchError.renderingFailed
    }
    return cropped
}

// MARK: - Summary

print("")
let passed = checks.filter(\.1).count
print("SUMMARY: \(passed)/\(checks.count) checks passed, \(failures.count) failed")
for failure in failures { print("  FAILED: \(failure)") }
print(failures.isEmpty ? "RESULT: PASS" : "RESULT: FAIL")
exit(failures.isEmpty ? 0 : 1)
