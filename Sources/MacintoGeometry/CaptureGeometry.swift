import CoreGraphics

/// Rectangle math for screenshots. All rects are global points with a top-left origin.
public enum CaptureGeometry {
    /// Margin around an app's windows in a cropped screenshot, in points.
    public static let defaultMargin: CGFloat = 8

    /// The area to capture for an app: the union of its windows that intersect `display`, grown by
    /// `margin`, clamped to `display`, and rounded outward to whole points (then clamped again).
    /// Returns nil when no window has a non-empty intersection with the display.
    public static func cropRect(windows: [CGRect], display: CGRect, margin: CGFloat = defaultMargin) -> CGRect? {
        let visible = windows.map { $0.standardized.intersection(display) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = visible.first else { return nil }
        let union = visible.dropFirst().reduce(first) { $0.union($1) }
        let grown = union.insetBy(dx: -max(0, margin), dy: -max(0, margin)).intersection(display)
        let minX = grown.minX.rounded(.down), minY = grown.minY.rounded(.down)
        let rounded = CGRect(x: minX, y: minY, width: grown.maxX.rounded(.up) - minX, height: grown.maxY.rounded(.up) - minY)
        let clamped = rounded.intersection(display)
        return clamped.isNull || clamped.isEmpty ? nil : clamped
    }

    /// Image pixels per point for a capture `width` points wide: 1 (points), or the display's
    /// backing scale with `native`, then reduced so the image is at most `maxWidth` pixels wide
    /// (`maxWidth` <= 0 means no limit).
    public static func scale(width: CGFloat, native: Bool, displayScale: CGFloat, maxWidth: Int) -> CGFloat {
        var s = native ? max(1, displayScale) : 1
        if maxWidth > 0, width > 0, width * s > CGFloat(maxWidth) { s = CGFloat(maxWidth) / width }
        return s
    }

    /// Output image size in pixels for a capture of `rect` at `scale` (at least 1x1).
    public static func pixelSize(_ rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }

    /// The click coordinate (global points) of pixel (px, py) in an image captured from a rect at
    /// `origin` with `scale` pixels per point.
    public static func clickPoint(px: CGFloat, py: CGFloat, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + px / scale, y: origin.y + py / scale)
    }
}
