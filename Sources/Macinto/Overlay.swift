import AppKit
import QuartzCore

/// The big flashing red apple shown at the top-right of the main screen while macinto is enabled.
/// Click-through, non-activating, on all Spaces, above normal windows. Excluded from macinto's own captures.
@MainActor
final class Overlay {
    static let size: CGFloat = 75
    private let margin: CGFloat = 12
    private var panel: NSPanel?
    private let appleLayer = CALayer()

    var isVisible: Bool { panel?.isVisible ?? false }

    var frameDescription: String {
        guard let f = panel?.frame, let screen = NSScreen.screens.first else { return "-" }
        // Report in top-left-origin global points, like every other macinto coordinate.
        let y = screen.frame.maxY - f.maxY
        return String(format: "%.0f,%.0f %.0fx%.0f", f.minX, y, f.width, f.height)
    }

    var frameJSON: JSON {
        guard let f = panel?.frame, let screen = NSScreen.screens.first else { return .null }
        return .rect(CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height))
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.title = "macinto overlay"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let image = AppleImage.emoji(pointSize: Self.size * 0.82, canvas: Self.size)
        appleLayer.contents = image.layerContents(forContentsScale: 2)
        appleLayer.contentsScale = 2
        appleLayer.frame = view.bounds
        appleLayer.shadowColor = NSColor.systemRed.cgColor
        appleLayer.shadowRadius = 8
        appleLayer.shadowOpacity = 0.8
        appleLayer.shadowOffset = .zero
        view.layer?.addSublayer(appleLayer)
        p.contentView = view
        return p
    }

    func show() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
        startPulse()
    }

    func hide() {
        appleLayer.removeAllAnimations()
        panel?.orderOut(nil)
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame // below the menu bar
        panel.setFrameOrigin(NSPoint(x: vf.maxX - Self.size - margin, y: vf.maxY - Self.size - margin))
    }

    private func startPulse() {
        appleLayer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.25
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 0.82
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.6
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        appleLayer.add(group, forKey: "pulse")
    }
}
