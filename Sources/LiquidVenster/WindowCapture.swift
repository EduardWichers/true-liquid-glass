import AppKit
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case windowNotFound(String)
    case displayNotFound(CGDirectDisplayID)
    case timeout(String)
    case invalidImage(String)
    case snapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "No permission for Screen Recording"
        case .windowNotFound(let m): return "Window not found for screen capture (\(m))"
        case .displayNotFound(let id): return "Display \(id) not found for screen capture"
        case .timeout(let m): return "Timeout: \(m)"
        case .invalidImage(let m): return "Invalid capture: \(m)"
        case .snapshotFailed(let m): return "Snapshot failed: \(m)"
        }
    }
}

struct CaptureResult {
    /// The window itself, without shadow, with transparent rounded corners.
    let window: CGImage
    /// The whole display without the window (and without our own overlays).
    let background: CGImage
    /// Frame of the captured window as ScreenCaptureKit saw it (Quartz coordinates).
    let windowFrameQuartz: CGRect
}

/// Runs `operation` but gives up after `seconds`. The late result (if any) is discarded.
func withTimeout<T>(seconds: Double, label: String, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.01) * 1_000_000_000))
            throw CaptureError.timeout(label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CaptureError.timeout(label) }
        return first
    }
}

enum WindowCapture {
    /// Everything (captures, textures, the overlay layer) uses one colour space so colours match exactly.
    static let colorSpaceName: CFString = CGColorSpace.displayP3
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Captures the window and a "clean plate" of its display without the window.
    static func capture(windowID: CGWindowID?, pid: pid_t, frameQuartz: CGRect,
                        displayID: CGDirectDisplayID) async throws -> CaptureResult {
        guard Permissions.screenCaptureGranted else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = findWindow(in: content.windows, id: windowID, pid: pid, frame: frameQuartz) else {
            throw CaptureError.windowNotFound("id \(windowID.map(String.init) ?? "?"), pid \(pid), frame \(frameQuartz)")
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        // Hide the window itself and any overlay of ours that might still be fading out.
        let me = getpid()
        let overlayLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        let excluded = [window] + content.windows.filter {
            $0.owningApplication?.processID == me && $0.windowID != window.windowID && $0.windowLayer >= overlayLevel
        }

        async let windowImage = captureWindow(window)
        async let backgroundImage = captureDisplay(display, excluding: excluded)
        let (image, background) = try await (windowImage, backgroundImage)

        try validate(image, expected: window.frame.size, label: "window")
        try validate(background, expected: display.frame.size, label: "background")
        return CaptureResult(window: image, background: background, windowFrameQuartz: window.frame)
    }

    static func findWindow(in windows: [SCWindow], id: CGWindowID?, pid: pid_t, frame: CGRect) -> SCWindow? {
        if let id, let match = windows.first(where: { $0.windowID == id }) {
            if match.owningApplication?.processID == pid { return match }
            logWarning("Window ID \(id) belongs to another app; matching by position")
        }
        let candidates = windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && framesClose($0.frame, frame)
        }
        if candidates.count > 1 { logDebug("\(candidates.count) windows with the same frame; taking the frontmost") }
        return candidates.first
    }

    private static func pixelSize(_ rect: CGRect, scale: Float) -> (Int, Int) {
        let s = CGFloat(scale > 0 && scale.isFinite ? scale : 2)
        return (max(1, Int((rect.width * s).rounded())), max(1, Int((rect.height * s).rounded())))
    }

    static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect.isEmpty ? CGRect(origin: .zero, size: window.frame.size) : filter.contentRect
        let (w, h) = pixelSize(rect, scale: filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.capturesShadowsOnly = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = colorSpaceName
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureDisplay(_ display: SCDisplay, excluding: [SCWindow]) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        let rect = filter.contentRect.isEmpty ? CGRect(origin: .zero, size: display.frame.size) : filter.contentRect
        let (w, h) = pixelSize(rect, scale: filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = colorSpaceName
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Rejects empty images and images whose aspect ratio does not match the frame
    /// (that would make the overlay visibly misaligned with the real window).
    static func validate(_ image: CGImage, expected: CGSize, label: String) throws {
        guard image.width > 0, image.height > 0 else { throw CaptureError.invalidImage("\(label) is empty") }
        guard expected.width > 0, expected.height > 0 else { return }
        let imageAspect = Double(image.width) / Double(image.height)
        let frameAspect = Double(expected.width) / Double(expected.height)
        let deviation = abs(imageAspect - frameAspect) / frameAspect
        if deviation > 0.04 {
            throw CaptureError.invalidImage("\(label) \(image.width)x\(image.height) does not match \(expected)")
        }
    }

    /// Snapshot of one of our own windows without Screen Recording permission.
    /// Renders the window's frame view (title bar + content) into a bitmap.
    @MainActor
    static func snapshotOwnWindow(_ window: NSWindow) throws -> CGImage {
        guard let view = window.contentView?.superview ?? window.contentView else {
            throw CaptureError.snapshotFailed("window has no view")
        }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { throw CaptureError.snapshotFailed("empty view") }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CaptureError.snapshotFailed("no bitmap for \(bounds.size)")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureError.snapshotFailed("no CGImage") }
        try validate(image, expected: window.frame.size, label: "own window")
        return image
    }
}
