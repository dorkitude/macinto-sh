import AppKit
import ApplicationServices

/// Accessibility tree inspection. Element ids are index paths from the window root
/// ("0" is the window, "0.3.1" is child 1 of child 3), resolved fresh on every call.
enum AXTree {
    struct Failure: Error { let message: String }

    static let maxNodes = 3000

    static func target(appName: String?) throws -> NSRunningApplication {
        if let appName {
            guard let a = Apps.find(appName) else { throw Failure(message: "no running app matches '\(appName)'") }
            return a
        }
        guard let a = NSWorkspace.shared.frontmostApplication else { throw Failure(message: "no frontmost app") }
        return a
    }

    /// The focused window of the app, falling back to its main window, its first window, then the app itself.
    static func root(of app: NSRunningApplication) -> AXUIElement {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        if let w: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) { return w }
        if let w: AXUIElement = attr(appEl, kAXMainWindowAttribute) { return w }
        if let ws: [AXUIElement] = attr(appEl, kAXWindowsAttribute), let w = ws.first { return w }
        return appEl
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) ?? []
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = attrValue(el, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &pos),
              let s: AXValue = attrValue(el, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func attrValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func stringish(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    static func clip(_ s: String, _ n: Int = 60) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\"", with: "'")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    /// Strings in JSON output are capped so one huge text view can't blow up the response.
    static func cap(_ s: String?, _ n: Int = 500) -> JSON {
        guard let s, !s.isEmpty else { return .null }
        return .string(s.count > n ? String(s.prefix(n)) + "…" : s)
    }

    static func describe(_ el: AXUIElement, id: String, depth: Int) -> JSON {
        var o: [String: JSON] = [
            "id": .string(id),
            "depth": .int(depth),
            "role": .string(stringish(el, kAXRoleAttribute) ?? "?"),
            "subrole": cap(stringish(el, kAXSubroleAttribute)),
            "title": cap(stringish(el, kAXTitleAttribute)),
            "description": cap(stringish(el, kAXDescriptionAttribute)),
            "value": cap(stringish(el, kAXValueAttribute)),
            "help": cap(stringish(el, kAXHelpAttribute)),
            "frame": frame(el).map { JSON.rect($0) } ?? .null,
        ]
        let enabled: Bool? = attr(el, kAXEnabledAttribute)
        let focused: Bool? = attr(el, kAXFocusedAttribute)
        o["enabled"] = .bool(enabled ?? true)
        o["focused"] = .bool(focused ?? false)
        return .object(o)
    }

    static func dump(appName: String?, maxDepth: Int) throws -> JSON {
        let app = try target(appName: appName)
        let root = root(of: app)
        var elements: [JSON] = []
        var count = 0
        func walk(_ el: AXUIElement, _ id: String, _ depth: Int) {
            guard count < maxNodes else { return }
            count += 1
            elements.append(describe(el, id: id, depth: depth))
            guard depth < maxDepth else { return }
            for (i, c) in children(el).enumerated() { walk(c, "\(id).\(i)", depth + 1) }
        }
        walk(root, "0", 0)
        return [
            "app": Apps.json(app, frontmost: app.isActive),
            "elements": .array(elements),
            "truncated": .bool(count >= maxNodes),
            "max_elements": .int(maxNodes),
        ]
    }

    static func resolve(_ id: String, appName: String?) throws -> AXUIElement {
        let comps = id.split(separator: ".").map { Int($0) }
        guard !comps.isEmpty, comps.allSatisfy({ $0 != nil }), comps[0] == 0 else {
            throw CommandError.usage("bad element id '\(id)' (expected a path like 0.3.1 from 'macinto.sh ui')")
        }
        var el = root(of: try target(appName: appName))
        for idx in comps.dropFirst().map({ $0! }) {
            let kids = children(el)
            guard idx < kids.count else {
                throw Failure(message: "element \(id) not found (the UI changed; run 'macinto.sh ui' again)")
            }
            el = kids[idx]
        }
        return el
    }

    static func check(_ err: AXError, _ what: String) throws {
        guard err == .success else { throw Failure(message: "\(what) failed (AXError \(err.rawValue))") }
    }

    static func press(_ id: String, appName: String?) throws -> JSON {
        let el = try resolve(id, appName: appName)
        try check(AXUIElementPerformAction(el, kAXPressAction as CFString), "AXPress on \(id)")
        return describe(el, id: id, depth: 0)
    }

    static func focus(_ id: String, appName: String?) throws -> JSON {
        let el = try resolve(id, appName: appName)
        try check(AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue), "focus on \(id)")
        return describe(el, id: id, depth: 0)
    }

    static func setValue(_ id: String, _ text: String, appName: String?) throws -> JSON {
        let el = try resolve(id, appName: appName)
        try check(AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString), "setting value on \(id)")
        return describe(el, id: id, depth: 0)
    }
}
