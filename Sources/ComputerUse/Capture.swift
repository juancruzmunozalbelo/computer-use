import ApplicationServices
import AppKit
import ScreenCaptureKit
import CoreGraphics

// MARK: - Async bridge

func runAsyncBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result!.get()
}

// MARK: - AX element indexing (element_index port)

struct IndexedElement {
    let index: Int
    let element: AXUIElement
    let role: String
    let title: String
    let frame: CGRect
    let actions: [String]

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var dict: [String: Any] {
        [
            "index": index,
            "role": role,
            "title": title,
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "w": Double(frame.size.width), "h": Double(frame.size.height),
            "actions": actions,
        ]
    }
}

final class ElementStore {
    static let shared = ElementStore()
    var elements: [IndexedElement] = []
    var pid: pid_t = 0

    func element(at index: Int) -> IndexedElement? {
        elements.first { $0.index == index }
    }
}

func axAttr<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref as? T
}

func axPoint(_ el: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &ref) == .success,
          let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(ref as! AXValue, .cgPoint, &p)
    return p
}

func axSize(_ el: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &ref) == .success,
          let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    AXValueGetValue(ref as! AXValue, .cgSize, &s)
    return s
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

private let actionableRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXMenuItem", "AXMenuBarItem",
    "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
    "AXSlider", "AXTab", "AXIncrementor", "AXSearchField", "AXMenuButton",
    "AXDisclosureTriangle", "AXSwitch",
]

func collectElements(pid: pid_t, maxDepth: Int = 14, cap: Int = 3000) -> [IndexedElement] {
    let app = AXUIElementCreateApplication(pid)
    var out: [IndexedElement] = []
    var idx = 0

    func walk(_ el: AXUIElement, _ depth: Int) {
        if depth > maxDepth || out.count >= cap { return }
        let role: String = axAttr(el, "AXRole") ?? ""
        let actions = axActions(el)
        let actionable = !actions.isEmpty || actionableRoles.contains(role)
        if actionable, let p = axPoint(el), let s = axSize(el), s.width > 0, s.height > 0 {
            let title: String = (axAttr(el, "AXTitle") as String?)
                ?? (axAttr(el, "AXDescription") as String?)
                ?? (axAttr(el, "AXValue") as String?)
                ?? (axAttr(el, "AXRoleDescription") as String?) ?? ""
            out.append(IndexedElement(
                index: idx, element: el, role: role, title: title,
                frame: CGRect(origin: p, size: s), actions: actions))
            idx += 1
        }
        if let children: [AXUIElement] = axAttr(el, "AXChildren") {
            for c in children { walk(c, depth + 1) }
        }
    }

    if let windows: [AXUIElement] = axAttr(app, "AXWindows"), !windows.isEmpty {
        for w in windows { walk(w, 0) }
    } else {
        walk(app, 0)
    }
    return out
}

// MARK: - App / window discovery

struct TargetApp {
    let pid: pid_t
    let name: String
    let bundleID: String
}

func resolveApp(params: [String: Any]) throws -> TargetApp {
    let running = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isTerminated
    }
    if let pid = params["pid"] as? Int {
        guard let app = running.first(where: { $0.processIdentifier == pid_t(pid) }) else {
            throw RPCError.badRequest("No GUI app with pid \(pid)")
        }
        return TargetApp(pid: app.processIdentifier,
                         name: app.localizedName ?? "?",
                         bundleID: app.bundleIdentifier ?? "")
    }
    let query = ((params["app"] as? String) ?? (params["bundle_id"] as? String) ?? "")
        .lowercased()
    let app: NSRunningApplication?
    if query.isEmpty || query == "frontmost" {
        app = NSWorkspace.shared.frontmostApplication
    } else {
        app = running.first {
            ($0.bundleIdentifier ?? "").lowercased() == query
                || ($0.localizedName ?? "").lowercased().contains(query)
        }
    }
    guard let app else {
        throw RPCError.badRequest("App not found: '\(query)'")
    }
    return TargetApp(pid: app.processIdentifier,
                     name: app.localizedName ?? "?",
                     bundleID: app.bundleIdentifier ?? "")
}

func listApps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        .map {
            var d: [String: Any] = [
                "pid": Int($0.processIdentifier),
                "name": $0.localizedName ?? "?",
                "bundle_id": $0.bundleIdentifier ?? "",
            ]
            if $0.isActive { d["frontmost"] = true }
            return d
        }
        .sorted { ($0["name"] as! String) < ($1["name"] as! String) }
}

func listWindows() -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { w in
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let layer = w[kCGWindowLayer as String] as? Int, layer == 0
        else { return nil }
        return [
            "window_id": w[kCGWindowNumber as String] as? Int ?? 0,
            "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
            "owner": w[kCGWindowOwnerName as String] as? String ?? "",
            "title": w[kCGWindowName as String] as? String ?? "",
            "x": b["X"] ?? 0, "y": b["Y"] ?? 0,
            "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
        ] as [String: Any]
    }
}

// MARK: - Skyshot (SCScreenshotManager + indexed AX tree)

func skyshot(params: [String: Any]) throws -> [String: Any] {
    let target = try resolveApp(params: params)
    try activateApp(target)

    let elements = collectElements(pid: target.pid)
    ElementStore.shared.elements = elements
    ElementStore.shared.pid = target.pid

    let pngPath: String? = try captureWindowPNG(pid: target.pid)

    return [
        "app": target.name,
        "bundle_id": target.bundleID,
        "pid": Int(target.pid),
        "screenshot": pngPath ?? NSNull(),
        "element_count": elements.count,
        "elements": elements.map { $0.dict },
    ]
}

func captureWindowPNG(pid: pid_t) throws -> String? {
    guard CGPreflightScreenCaptureAccess() else { return nil }
    return try runAsyncBlocking {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let win = content.windows
            .filter({ $0.owningApplication?.processID == pid })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = true
        let img = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(
            atPath: "/tmp/computer-use", withIntermediateDirectories: true)
        let path = "/tmp/computer-use/skyshot_\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }
}

func activateApp(_ target: TargetApp) throws {
    guard let app = NSRunningApplication(processIdentifier: target.pid) else {
        throw RPCError.badRequest("App \(target.pid) not running")
    }
    if !app.isActive { _ = app.activate() }
    usleep(120_000)
}

// MARK: - Settle wait (needsUISettleBeforeSkyshot port)

func elementsSignature(_ elements: [IndexedElement]) -> Int {
    var h = 5381
    for e in elements {
        h = ((h << 5) &+ h) &+ e.role.hashValue
        h = ((h << 5) &+ h) &+ Int(e.frame.origin.x) &+ Int(e.frame.origin.y)
        h = ((h << 5) &+ h) &+ Int(e.frame.size.width) &+ Int(e.frame.size.height)
    }
    return h
}

func waitSettle(pid: pid_t, timeoutMs: Int, intervalMs: Int = 180) -> [String: Any] {
    let start = Date()
    var last = elementsSignature(collectElements(pid: pid))
    var stable = 0
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        usleep(UInt32(intervalMs) * 1000)
        let sig = elementsSignature(collectElements(pid: pid))
        if sig == last {
            stable += 1
            if stable >= 2 {
                return ["settled": true,
                        "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000)]
            }
        } else {
            stable = 0
            last = sig
        }
    }
    return ["settled": false,
            "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000)]
}
