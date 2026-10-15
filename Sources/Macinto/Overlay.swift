import AppKit
import QuartzCore

/// The big flashing red apple shown at the top-right of the main screen while macinto is enabled.
/// Tucked into the corner just under the menu bar, non-activating, on all Spaces, above normal
/// windows, and excluded from macinto's own captures. Hovering it shows a warning; clicking it opens
/// the Macinto.sh window. While macinto posts synthetic mouse events it turns click-through for a
/// moment, so an agent's click on that spot reaches whatever is underneath.
@MainActor
final class Overlay {
    static let size: CGFloat = 75
    private let margin: CGFloat = 2
    private var panel: NSPanel?
    private var tip: NSPanel?
    private var restoreHits: DispatchWorkItem?
    /// Called when the user clicks the apple.
    var onClick: (() -> Void)?
    static weak var current: Overlay?
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
        Overlay.current = self
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    private func makePanel() -> NSPanel {
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.title = "macinto overlay"

        let view = AppleView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        view.onClick = { [weak self] in self?.hideTip(); self?.onClick?() }
        view.onHover = { [weak self] inside in inside ? self?.showTip() : self?.hideTip() }
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
        hideTip()
        panel?.orderOut(nil)
    }

    /// Make the apple click-through while synthetic mouse events are delivered, then restore it.
    static func passThrough(_ body: () throws -> Void) rethrows {
        guard let o = current, let panel = o.panel, panel.isVisible else { return try body() }
        o.restoreHits?.cancel()
        o.hideTip()
        panel.ignoresMouseEvents = true
        defer {
            let work = DispatchWorkItem { [weak o] in o?.panel?.ignoresMouseEvents = false }
            o.restoreHits = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        try body()
    }

    private static let warning = "Careful!  Macinto.sh is enabled, which means any terminal or agent can control your computer."

    private func showTip() {
        guard let panel, panel.isVisible else { return }
        if tip == nil {
            let label = NSTextField(wrappingLabelWithString: Self.warning)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = NSColor(srgbRed: 0xc0 / 255, green: 0xca / 255, blue: 0xf5 / 255, alpha: 1)
            label.preferredMaxLayoutWidth = 240
            let size = label.fittingSize
            let pad: CGFloat = 10
            let t = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            t.isOpaque = false
            t.backgroundColor = .clear
            t.hasShadow = true
            t.ignoresMouseEvents = true
            t.level = .statusBar
            t.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            t.sharingType = .none
            let box = NSView(frame: t.contentView!.bounds)
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor(srgbRed: 0x24 / 255, green: 0x28 / 255, blue: 0x3b / 255, alpha: 0.97).cgColor
            box.layer?.cornerRadius = 10
            box.layer?.borderWidth = 1
            box.layer?.borderColor = NSColor(srgbRed: 0xf7 / 255, green: 0x76 / 255, blue: 0x8e / 255, alpha: 0.8).cgColor
            label.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
            box.addSubview(label)
            t.contentView = box
            tip = t
        }
        guard let tip else { return }
        // Just left of the apple, top-aligned with it.
        let f = panel.frame
        tip.setFrameOrigin(NSPoint(x: f.minX - tip.frame.width - 6, y: f.maxY - tip.frame.height))
        tip.orderFrontRegardless()
    }

    private func hideTip() { tip?.orderOut(nil) }

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

/// Never becomes key or main, so clicking the apple doesn't take focus by itself.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AppleView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
