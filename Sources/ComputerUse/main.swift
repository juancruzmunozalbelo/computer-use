import ApplicationServices
import AppKit
import Foundation

let port: UInt16 = CommandLine.arguments.count > 1
    ? UInt16(CommandLine.arguments[1]) ?? 11260
    : 11260

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

let server = BridgeServer(port: port)

func pointParam(_ p: [String: Any], _ xKey: String, _ yKey: String) throws -> CGPoint {
    guard let x = (p[xKey] as? NSNumber)?.doubleValue ?? (p[xKey] as? Double),
          let y = (p[yKey] as? NSNumber)?.doubleValue ?? (p[yKey] as? Double)
    else { throw RPCError.badRequest("Missing \(xKey)/\(yKey)") }
    return CGPoint(x: x, y: y)
}

server.register("ping") { _ in
    ["ok": true, "version": "0.1.0",
     "pid": ProcessInfo.processInfo.processIdentifier]
}

server.register("check_permissions") { _ in
    [
        "accessibility": AXIsProcessTrusted(),
        "screen_recording": CGPreflightScreenCaptureAccess(),
    ]
}

server.register("request_permissions") { _ in
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    let ax = AXIsProcessTrustedWithOptions(opts)
    let scr = CGRequestScreenCaptureAccess()
    return ["accessibility": ax, "screen_recording": scr]
}

server.register("list_apps") { _ in listApps() }

server.register("list_windows") { _ in listWindows() }

server.register("focus_app") { p in
    let app = try resolveApp(params: p)
    try activateApp(app)
    return ["activated": app.name, "pid": Int(app.pid)]
}

server.register("skyshot") { p in try skyshot(params: p) }

server.register("ui_elements") { p in
    let app = try resolveApp(params: p)
    let elements = collectElements(pid: app.pid)
    ElementStore.shared.elements = elements
    ElementStore.shared.pid = app.pid
    return [
        "app": app.name, "pid": Int(app.pid),
        "element_count": elements.count,
        "elements": elements.map { $0.dict },
    ] as [String: Any]
}

server.register("click") { p in
    if let idx = (p["index"] as? NSNumber)?.intValue {
        guard let el = ElementStore.shared.element(at: idx) else {
            throw RPCError.badRequest("No element at index \(idx) — run skyshot or ui_elements first")
        }
        if axPerform(el.element, "AXPress") {
            return ["clicked": "AXPress", "index": idx] as [String: Any]
        }
        clickAt(el.center, button: p["button"] as? String ?? "left",
                clicks: (p["clicks"] as? NSNumber)?.intValue ?? 1)
        return ["clicked": "cgevent", "index": idx,
                "x": el.center.x, "y": el.center.y] as [String: Any]
    }
    let pt = try pointParam(p, "x", "y")
    clickAt(pt, button: p["button"] as? String ?? "left",
            clicks: (p["clicks"] as? NSNumber)?.intValue ?? 1)
    return ["clicked": "cgevent", "x": pt.x, "y": pt.y] as [String: Any]
}

server.register("move_mouse") { p in
    let pt = try pointParam(p, "x", "y")
    moveMouse(pt)
    return ["moved": true, "x": pt.x, "y": pt.y]
}

server.register("scroll") { p in
    let pt = CGPoint(x: (p["x"] as? NSNumber)?.doubleValue ?? NSScreen.main!.frame.midX,
                     y: (p["y"] as? NSNumber)?.doubleValue ?? NSScreen.main!.frame.midY)
    scrollAt(pt,
             dx: (p["dx"] as? NSNumber)?.intValue ?? 0,
             dy: (p["dy"] as? NSNumber)?.intValue ?? -120)
    return ["scrolled": true]
}

server.register("drag") { p in
    let from = try pointParam(p, "from_x", "from_y")
    let to = try pointParam(p, "to_x", "to_y")
    dragPath(from: from, to: to)
    return ["dragged": true]
}

server.register("type_text") { p in
    guard let text = p["text"] as? String else {
        throw RPCError.badRequest("Missing 'text'")
    }
    typeText(text)
    return ["typed": text.count]
}

server.register("set_text") { p in
    guard let idx = (p["index"] as? NSNumber)?.intValue,
          let text = p["text"] as? String
    else { throw RPCError.badRequest("Missing 'index'/'text'") }
    guard let el = ElementStore.shared.element(at: idx) else {
        throw RPCError.badRequest("No element at index \(idx)")
    }
    let ok = axSetValue(el.element, text as CFString)
    return ["set": ok, "index": idx] as [String: Any]
}

server.register("press_key") { p in
    guard let key = p["key"] as? String else {
        throw RPCError.badRequest("Missing 'key'")
    }
    let mods = (p["modifiers"] as? [String]) ?? []
    try pressKey(key, modifiers: mods)
    return ["pressed": key, "modifiers": mods] as [String: Any]
}

server.register("wait") { p in
    let ms = (p["ms"] as? NSNumber)?.intValue ?? 500
    usleep(UInt32(min(ms, 30_000)) * 1000)
    return ["waited_ms": ms]
}

server.register("wait_settle") { p in
    let app = try resolveApp(params: p)
    let timeout = (p["timeout_ms"] as? NSNumber)?.intValue ?? 5000
    return waitSettle(pid: app.pid, timeoutMs: timeout)
}

FileHandle.standardError.write(
    "computer-use 0.1.0 — ax=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess())\n"
        .data(using: .utf8)!)
server.run()
