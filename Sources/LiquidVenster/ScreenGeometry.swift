import AppKit
import CoreGraphics

/// Coordinate helpers.
///
/// Three coordinate systems are involved:
///  - Quartz / Accessibility / ScreenCaptureKit: global, origin top-left of the primary display, y down.
///  - Cocoa (NSScreen / NSWindow): global, origin bottom-left of the primary display, y up.
///  - Overlay-local ("TL"): points relative to the top-left of one screen, y down. The renderer uses this.
enum ScreenGeometry {
    /// Height of the primary display (the one whose Cocoa frame has origin 0,0).
    static func primaryHeight(_ screens: [NSScreen] = NSScreen.screens) -> CGFloat? {
        if let primary = screens.first(where: { $0.frame.origin == .zero }) { return primary.frame.height }
        return screens.first?.frame.height
    }

    static func cocoaPoint(fromQuartz p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    static func quartzPoint(fromCocoa p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    /// The conversion is its own inverse (mirror around y = h/2).
    static func cocoaRect(fromQuartz r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func quartzRect(fromCocoa r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        cocoaRect(fromQuartz: r, primaryHeight: h)
    }

    /// Quartz rect -> overlay-local TL rect for a screen with the given Cocoa frame.
    static func localRect(fromQuartz r: CGRect, screenFrame s: CGRect, primaryHeight h: CGFloat) -> CGRect {
        let screenTop = h - s.maxY
        return CGRect(x: r.minX - s.minX, y: r.minY - screenTop, width: r.width, height: r.height)
    }

    static func localPoint(fromQuartz p: CGPoint, screenFrame s: CGRect, primaryHeight h: CGFloat) -> CGPoint {
        let screenTop = h - s.maxY
        return CGPoint(x: p.x - s.minX, y: p.y - screenTop)
    }

    /// Index of the frame with the largest overlap and the fraction of `rect` that lies on it.
    /// `spansMultiple` is true when a meaningful part (> 3%) of the visible area is on other frames.
    static func bestFrame(for rect: CGRect, in frames: [CGRect]) -> (index: Int, fraction: CGFloat, spansMultiple: Bool)? {
        guard rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        let area = rect.width * rect.height
        var bestIndex = -1
        var bestArea: CGFloat = 0
        var visibleArea: CGFloat = 0
        for (i, frame) in frames.enumerated() {
            let inter = rect.intersection(frame)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let a = inter.width * inter.height
            visibleArea += a
            if a > bestArea { bestArea = a; bestIndex = i }
        }
        guard bestIndex >= 0 else { return nil }
        return (bestIndex, bestArea / area, bestArea < visibleArea * 0.97)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Clamp a point into a rect, keeping `inset` points distance from the edges.
    static func clamp(_ p: CGPoint, into r: CGRect, inset: CGFloat) -> CGPoint {
        let i = min(inset, r.width / 2, r.height / 2)
        let x = p.x.isFinite ? p.x : r.midX
        let y = p.y.isFinite ? p.y : r.midY
        return CGPoint(x: min(max(x, r.minX + i), r.maxX - i),
                       y: min(max(y, r.minY + i), r.maxY - i))
    }

    /// True when the login window / lock screen is up: nothing we draw would be shown then.
    static func isSessionLocked() -> Bool {
        // Test hook: lets the self-test/demo exercise the overlay safety nets on a locked machine.
        if ProcessInfo.processInfo.environment["LIQUID_IGNORE_LOCK"] == "1" { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber, locked.boolValue { return true }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? NSNumber, !onConsole.boolValue { return true }
        return false
    }

    static func isDisplayAsleep(_ id: CGDirectDisplayID) -> Bool {
        if ProcessInfo.processInfo.environment["LIQUID_IGNORE_LOCK"] == "1" { return false }
        return CGDisplayIsAsleep(id) != 0
    }

    static func isValid(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0
    }
}
