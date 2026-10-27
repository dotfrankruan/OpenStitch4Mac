import AppKit
import CoreGraphics
import SwiftUI

/// A scrollable, fit-to-width preview of a potentially very tall stitched image.
///
/// SwiftUI's `Image` collapses inside a two-axis `ScrollView` and falls back to a narrow
/// strip when the aspect ratio is extreme. AppKit's `NSScrollView` + `NSImageView` draws
/// only the visible portion at native resolution, so even a 1280 × 60,000 px result stays
/// sharp and scrolls smoothly without keeping a large downscaled preview copy around.
struct LongImagePreview: NSViewRepresentable {
    let image: CGImage
    var horizontalPadding: CGFloat = 24

    func makeNSView(context: Context) -> LongImageScrollView {
        let scrollView = LongImageScrollView()
        scrollView.show(image: image, horizontalPadding: horizontalPadding)
        return scrollView
    }

    func updateNSView(_ scrollView: LongImageScrollView, context: Context) {
        scrollView.show(image: image, horizontalPadding: horizontalPadding)
    }
}

/// `NSScrollView` subclass that fits its image to the available width (downscaling only;
/// small screenshots are shown at their natural size) and keeps the top of the image at
/// the top of the viewport.
final class LongImageScrollView: NSScrollView {
    private let previewDocument = PreviewDocumentView()
    /// The document view is flipped, so the origin always means "top of the image".
    private var needsScrollToTop = true

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        borderType = .noBorder
        documentView = previewDocument
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(image: CGImage, horizontalPadding: CGFloat) {
        previewDocument.horizontalPadding = horizontalPadding
        previewDocument.imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        needsScrollToTop = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()

        guard let imageSize = previewDocument.imageView.image?.size,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return
        }

        let padding = previewDocument.horizontalPadding
        let availableWidth = max(1, contentSize.width - padding * 2)
        let scale = min(1, availableWidth / imageSize.width)
        let displayWidth = max(1, imageSize.width * scale)
        let displayHeight = max(1, imageSize.height * scale)

        previewDocument.frame = NSRect(
            x: 0,
            y: 0,
            width: max(contentSize.width, 1),
            height: max(contentSize.height, displayHeight)
        )
        previewDocument.imageView.frame = NSRect(
            x: padding + max(0, (contentSize.width - padding * 2 - displayWidth) / 2),
            y: 0,
            width: displayWidth,
            height: displayHeight
        )

        if needsScrollToTop, contentSize.width > 1, contentSize.height > 1 {
            needsScrollToTop = false
            contentView.scroll(to: NSPoint(x: 0, y: 0))
            reflectScrolledClipView(contentView)
        }
    }
}

/// Flipped container so the stitched image starts at the top and grows downwards.
private final class PreviewDocumentView: NSView {
    let imageView = PreviewImageView()
    var horizontalPadding: CGFloat = 24

    init() {
        super.init(frame: .zero)
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
}

private final class PreviewImageView: NSImageView {
    init() {
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        imageAlignment = .alignCenter
        setAccessibilityRole(.image)
        setAccessibilityLabel("Stitched long screenshot preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
