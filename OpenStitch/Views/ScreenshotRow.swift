import SwiftUI

/// One row in the ordered screenshot list.
struct ScreenshotRow: View {
    let screenshot: StitchWorkspace.Screenshot
    let index: Int
    let count: Int
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(decorative: screenshot.thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 78, height: 100)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                .accessibilityLabel("Preview of screenshot \(index + 1)")

            VStack(alignment: .leading, spacing: 6) {
                Text("Screenshot \(index + 1)")
                    .font(.headline)
                Text(screenshot.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(screenshot.pixelWidth) × \(screenshot.pixelHeight) px")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: moveUp) {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                .help("Move screenshot \(index + 1) up")
                .accessibilityLabel("Move screenshot \(index + 1) up")

                Button(action: moveDown) {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == count - 1)
                .help("Move screenshot \(index + 1) down")
                .accessibilityLabel("Move screenshot \(index + 1) down")

                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .help("Remove screenshot \(index + 1)")
                .accessibilityLabel("Remove screenshot \(index + 1)")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)

            Text("\(index + 1)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

#Preview {
    ScreenshotRow(
        screenshot: StitchWorkspace.Screenshot(
            url: URL(fileURLWithPath: "/tmp/example.png"),
            pixelWidth: 1179,
            pixelHeight: 2556,
            thumbnail: ScreenshotRow.previewImage
        ),
        index: 0,
        count: 3,
        moveUp: {},
        moveDown: {},
        remove: {}
    )
    .padding()
    .frame(width: 560)
}

private extension ScreenshotRow {
    static var previewImage: CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 160,
            height: 220,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 160, height: 220))
        return context!.makeImage()!
    }
}
