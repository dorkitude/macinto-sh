// Draws the DMG window background (an arrow from the app to Applications):
//   swift scripts/make-dmg-background.swift OUT_DIR  ->  OUT_DIR/background.png, OUT_DIR/background@2x.png
// Layout must match scripts/dmg-settings.py (window 660x400, icons centered at x=180 and x=480, y=190).
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let width: CGFloat = 660, height: CGFloat = 400

for scale in [1, 2] {
    let s = CGFloat(scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * s), pixelsHigh: Int(height * s),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: width, height: height)  // draw in points; the rep holds scale x pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background: soft light gradient, so it reads in both Finder light and dark mode.
    NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Arrow between the icons (AppKit y is bottom-up; icon centers sit at y=190 from the top).
    let y = height - 190
    let red = NSColor(red: 0.85, green: 0.16, blue: 0.16, alpha: 0.9)
    red.setStroke()
    red.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 270, y: y))
    shaft.line(to: NSPoint(x: 375, y: y))
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 395, y: y))
    head.line(to: NSPoint(x: 368, y: y + 18))
    head.line(to: NSPoint(x: 368, y: y - 18))
    head.close()
    head.fill()

    // Caption under the icons.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let caption = NSAttributedString(string: "Drag Macinto to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.35, alpha: 1),
        .paragraphStyle: style,
    ])
    caption.draw(in: NSRect(x: 0, y: 62, width: width, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
