import AppKit
import CoreImage

/// Renders the 🍎 emoji into images for the status item and the overlay.
enum AppleImage {
    static func emoji(_ s: String = "🍎", pointSize: CGFloat, canvas: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
            let str = NSAttributedString(string: s, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
    }

    /// Grayscale, low-alpha version for the disabled state.
    static func dimmed(_ image: NSImage, alpha: CGFloat = 0.4) -> NSImage {
        let size = image.size
        return NSImage(size: size, flipped: false) { rect in
            guard let cg = image.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) else { return false }
            let ci = CIImage(cgImage: cg)
            let gray = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0,
                                                                         kCIInputBrightnessKey: 0.05])
            let ctx = CIContext()
            guard let out = ctx.createCGImage(gray, from: ci.extent) else { return false }
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            NSGraphicsContext.current?.cgContext.draw(out, in: rect)
            return true
        }
    }
}
