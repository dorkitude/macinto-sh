import CoreGraphics
import Foundation

/// Synthesized mouse and keyboard input via CGEvent. Coordinates are global points,
/// origin at the top-left of the main display.
enum Input {
    struct Failure: Error { let message: String }

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    private static func post(_ e: CGEvent?) throws {
        guard let e else { throw Failure(message: "could not create input event") }
        e.post(tap: .cghidEventTap)
    }

    private static func pause(_ ms: UInt32 = 8) { usleep(ms * 1000) }

    static var mouseLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to p: CGPoint) throws {
        try post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        pause()
    }

    static func click(at p: CGPoint, right: Bool, count: Int) throws {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        try move(to: p)
        for n in 1...max(1, count) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                try post(e)
                pause(type == down ? 15 : 30)
            }
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint) throws {
        try move(to: a)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        pause(50)
        let steps = max(10, Int(hypot(b.x - a.x, b.y - a.y) / 20))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            pause(10)
        }
        pause(50)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
    }

    /// Scroll by lines. Positive dy scrolls content down (like moving a wheel toward you is negative).
    static func scroll(dx: Int32, dy: Int32) throws {
        try post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    /// Type arbitrary Unicode text. Newlines and tabs are sent as Return/Tab key presses.
    static func type(_ text: String) throws {
        var chunk = ""
        func flush() throws {
            guard !chunk.isEmpty else { return }
            let utf16 = Array(chunk.utf16)
            for keyDown in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                e?.flags = []
                utf16.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                try post(e)
                pause(5)
            }
            chunk = ""
            pause(10)
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                try flush(); try key(code: Keys.returnKey, flags: [])
            } else if ch == "\t" {
                try flush(); try key(code: Keys.tab, flags: [])
            } else {
                // CGEvent carries at most 20 UTF-16 units; keep whole characters together.
                if chunk.utf16.count + String(ch).utf16.count > 16 { try flush() }
                chunk.append(ch)
            }
        }
        try flush()
    }

    static func key(code: CGKeyCode, flags: CGEventFlags) throws {
        for keyDown in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown)
            e?.flags = flags
            try post(e)
            pause(12)
        }
    }

    /// Parse "cmd+shift+g", "return", "f5", "left" into a key code and modifier flags.
    static func parseCombo(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
        let parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // Allow "cmd++" for the plus key.
        var tokens = parts
        if combo.hasSuffix("++") { tokens = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = tokens.last, !keyName.isEmpty else {
            throw Failure(message: "usage: key COMBO, e.g. cmd+shift+g, return, escape, f5, left")
        }
        var flags: CGEventFlags = []
        for m in tokens.dropLast() {
            switch m {
            case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw Failure(message: "unknown modifier '\(m)' (use cmd, shift, opt, ctrl, fn)")
            }
        }
        guard let (code, extra) = Keys.lookup(keyName) else {
            throw Failure(message: "unknown key '\(keyName)'. Run 'macinto.sh keys' for the list")
        }
        return (code, flags.union(extra))
    }
}

enum Keys {
    static let returnKey: CGKeyCode = 0x24
    static let tab: CGKeyCode = 0x30

    /// US ANSI layout virtual key codes.
    static let table: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "equal": 0x18, "minus": 0x1B, "rightbracket": 0x1E, "leftbracket": 0x21, "quote": 0x27,
        "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C, "period": 0x2F, "grave": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "forwarddelete": 0x75, "del": 0x75,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "help": 0x72,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
        "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "keypadenter": 0x4C, "capslock": 0x39,
    ]

    static func lookup(_ name: String) -> (CGKeyCode, CGEventFlags)? {
        let aliases = ["+": "=", "plus": "=", "esc": "escape", "arrowleft": "left", "arrowright": "right",
                       "arrowup": "up", "arrowdown": "down", "pgup": "pageup", "pgdn": "pagedown"]
        let n = aliases[name] ?? name
        guard let code = table[n] else { return nil }
        var flags: CGEventFlags = []
        if name == "+" || name == "plus" { flags.insert(.maskShift) }
        if ["left", "right", "up", "down"].contains(n) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        if n.hasPrefix("f"), n.count > 1, Int(n.dropFirst()) != nil { flags.insert(.maskSecondaryFn) }
        if ["home", "end", "pageup", "pagedown", "forwarddelete", "help"].contains(n) { flags.insert(.maskSecondaryFn) }
        return (code, flags)
    }

    static var names: [String] { table.keys.sorted() }
}
