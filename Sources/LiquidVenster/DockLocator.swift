import AppKit
import ApplicationServices

/// Where a minimized window ends up in the Dock.
struct DockTarget {
    /// Global Quartz coordinates (top-left origin).
    var pointQuartz: CGPoint
    var edge: DockEdge
    var iconSize: CGFloat
    /// Human readable explanation for the log.
    var source: String
}

/// Finds the Dock icon a window minimizes into, using the Dock's accessibility tree.
/// Falls back to an estimate based on the Dock preferences and the screen's visible frame.
enum DockLocator {
    struct Preferences {
        var edge: DockEdge
        var minimizeToApplication: Bool
        var autohide: Bool
    }

    struct Item {
        let subrole: String?
        let title: String?
        let url: URL?
        let frame: CGRect
    }

    static func preferences() -> Preferences {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let minimize = (CFPreferencesCopyAppValue("minimize-to-application" as CFString, domain) as? NSNumber)?.boolValue ?? false
        let autohide = (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue ?? false
        return Preferences(edge: .fromOrientation(orientation), minimizeToApplication: minimize, autohide: autohide)
    }

    /// Reads the Dock items. Needs Accessibility permission; returns nil otherwise.
    static func items() -> (listFrame: CGRect?, items: [Item])? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            logWarning("Dock process not found")
            return nil
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AX.setTimeout(app, seconds: 0.3)
        guard let list = AX.children(app).first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }) else {
            logWarning("Dock list not found via Accessibility")
            return nil
        }
        let items = AX.children(list).compactMap { element -> Item? in
            guard let frame = AX.frame(element) else { return nil }
            return Item(subrole: AX.string(element, kAXSubroleAttribute),
                        title: AX.string(element, kAXTitleAttribute),
                        url: AX.url(element),
                        frame: frame)
        }
        return (AX.frame(list), items)
    }

    static func locate(pid: pid_t) -> DockTarget {
        let prefs = preferences()
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "pid \(pid)"

        if let dock = items(), !dock.items.isEmpty {
            let appItem = dock.items.first { $0.subrole == "AXApplicationDockItem" && matches($0, app) }
            let trash = dock.items.first { $0.subrole == "AXTrashDockItem" }
            let iconSize = appItem?.frame.width ?? trash?.frame.width ?? dock.items[0].frame.width

            if prefs.minimizeToApplication, let appItem {
                return DockTarget(pointQuartz: center(appItem.frame), edge: prefs.edge, iconSize: iconSize,
                                  source: "Dock icon of \(appName)")
            }
            if let trash {
                // New minimized windows are inserted right before the Trash.
                return DockTarget(pointQuartz: center(trash.frame), edge: prefs.edge, iconSize: iconSize,
                                  source: "right part of the Dock (next to the Trash)")
            }
            if let appItem {
                return DockTarget(pointQuartz: center(appItem.frame), edge: prefs.edge, iconSize: iconSize,
                                  source: "Dock icon of \(appName) (no Trash found)")
            }
            if let listFrame = dock.listFrame {
                return DockTarget(pointQuartz: center(listFrame), edge: prefs.edge, iconSize: iconSize,
                                  source: "middle of the Dock")
            }
        }
        return estimate(edge: prefs.edge)
    }

    static func matches(_ item: Item, _ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if let itemURL = item.url, let bundleURL = app.bundleURL, normalized(itemURL) == normalized(bundleURL) {
            return true
        }
        if let title = item.title, let name = app.localizedName, !title.isEmpty, title == name { return true }
        return false
    }

    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Without Dock information: the middle of the Dock edge of the screen that has the Dock
    /// (recognisable by a smaller visible frame), or of the main screen.
    static func estimate(edge: DockEdge) -> DockTarget {
        let screens = NSScreen.screens
        guard let h = ScreenGeometry.primaryHeight(screens), !screens.isEmpty else {
            return DockTarget(pointQuartz: .zero, edge: edge, iconSize: 48, source: "fallback position (no screens)")
        }
        func dockThickness(_ s: NSScreen) -> CGFloat {
            let f = s.frame, v = s.visibleFrame
            switch edge {
            case .bottom: return v.minY - f.minY
            case .left: return v.minX - f.minX
            case .right: return f.maxX - v.maxX
            }
        }
        let screen = screens.max(by: { dockThickness($0) < dockThickness($1) }) ?? screens[0]
        let f = screen.frame
        let thickness = max(dockThickness(screen), 8)
        let cocoa: CGPoint
        switch edge {
        case .bottom: cocoa = CGPoint(x: f.midX, y: f.minY + thickness / 2)
        case .left: cocoa = CGPoint(x: f.minX + thickness / 2, y: f.midY)
        case .right: cocoa = CGPoint(x: f.maxX - thickness / 2, y: f.midY)
        }
        return DockTarget(pointQuartz: ScreenGeometry.quartzPoint(fromCocoa: cocoa, primaryHeight: h),
                          edge: edge, iconSize: 48, source: "estimate (Dock \(edge))")
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
}
