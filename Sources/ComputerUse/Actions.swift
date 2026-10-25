import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - Mouse synthesis (CGEvent, CGHIDEventTap)

private func hidSource() -> CGEventSource? {
    CGEventSource(stateID: .hidSystemState)
}

func clickAt(_ p: CGPoint, button: String = "left", clicks: Int = 1) {
    let btn: CGMouseButton = button == "right" ? .right : (button == "middle" ? .center : .left)
    let downT: CGEventType = btn == .left ? .leftMouseDown : (btn == .right ? .rightMouseDown : .otherMouseDown)
    let upT: CGEventType = btn == .left ? .leftMouseUp : (btn == .right ? .rightMouseUp : .otherMouseUp)
    CGEvent(mouseEventSource: hidSource(), mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
    usleep(40_000)
    for _ in 0..<max(1, clicks) {
        CGEvent(mouseEventSource: hidSource(), mouseType: downT,
                mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        usleep(35_000)
        CGEvent(mouseEventSource: hidSource(), mouseType: upT,
                mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
}

func moveMouse(_ p: CGPoint) {
    CGEvent(mouseEventSource: hidSource(), mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func scrollAt(_ p: CGPoint, dx: Int, dy: Int) {
    moveMouse(p)
    usleep(30_000)
    CGEvent(scrollWheelEvent2Source: hidSource(), units: .pixel,
            wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(dx), wheel3: 0)?
        .post(tap: .cghidEventTap)
}

func dragPath(from: CGPoint, to: CGPoint, steps: Int = 24) {
    let src = hidSource()
    moveMouse(from)
    usleep(50_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    for i in 1...max(1, steps) {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t,
                        y: from.y + (to.y - from.y) * t)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// MARK: - Keyboard

private let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
    "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
    "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
    "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
    "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "minus": 27, "equals": 24, "leftbracket": 33, "rightbracket": 30,
    "backslash": 42, "semicolon": 41, "quote": 39, "comma": 43,
    "period": 47, "slash": 44, "grave": 50,
]

private func flagsFor(_ modifiers: [String]) -> CGEventFlags {
    var f = CGEventFlags()
    for m in modifiers {
        switch m.lowercased() {
        case "cmd", "command", "meta": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "ctrl", "control": f.insert(.maskControl)
        case "opt", "option", "alt": f.insert(.maskAlternate)
        case "fn": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return f
}

func pressKey(_ key: String, modifiers: [String]) throws {
    guard let code = keyCodes[key.lowercased()] else {
        throw RPCError.badRequest("Unknown key '\(key)'. Known: \(keyCodes.keys.sorted().joined(separator: ", "))")
    }
    let flags = flagsFor(modifiers)
    let src = hidSource()
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(35_000)
    up?.post(tap: .cghidEventTap)
    usleep(20_000)
}

// Type via pasteboard + Cmd+V: reliable for arbitrary unicode.
func typeText(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(60_000)
    try? pressKey("v", modifiers: ["cmd"])
    usleep(80_000)
}

// MARK: - AX semantic actions

func axPerform(_ el: AXUIElement, _ action: String) -> Bool {
    AXUIElementPerformAction(el, action as CFString) == .success
}

func axSetValue(_ el: AXUIElement, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(el, "AXValue" as CFString, value) == .success
}

func axFocused(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    return axAttr(app, "AXFocusedUIElement")
}

// MARK: - App activation / window focus

func focusApp(bundleOrName: String) throws -> [String: Any] {
    let target = try resolveApp(params: ["app": bundleOrName])
    try activateApp(target)
    return ["activated": target.name, "pid": Int(target.pid)]
}
