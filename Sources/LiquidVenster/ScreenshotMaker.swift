import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// `--make-screenshots <folder> [--language xx]`: creates the images for the README.
///
/// - `settings.png`, `troubleshooting.png`: the real settings window (captured with
///   ScreenCaptureKit, only our own window, with its shadow).
/// - `water.gif`, `steam.gif`: the real renderer, with a real test window as source, over a
///   synthetic desktop, so nothing from the user's own screen ends up in the images.
@MainActor
enum ScreenshotMaker {
    static func run(outputDirectory: URL, delegate: AppDelegate) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            AppLog.shared.clear()

            // Settings window, both tabs.
            delegate.presentSettings(tab: .settings)
            guard let window = delegate.settingsWindow else { throw CaptureError.snapshotFailed("no settings window") }
            window.setContentSize(NSSize(width: 560, height: 860))
            window.center()
            try await pause(1.5)
            try save(try await capture(window, shadow: true), to: outputDirectory.appendingPathComponent("settings.png"))
            delegate.status.selectedTab = .troubleshooting
            try await pause(2.0)
            try save(try await capture(window, shadow: true), to: outputDirectory.appendingPathComponent("troubleshooting.png"))
            delegate.status.selectedTab = .settings
            window.orderOut(nil)

            // A real test window as the source for the animations.
            let demo = DemoWindows.open()
            demo.setContentSize(NSSize(width: 400, height: 270))
            try await pause(1.0)
            let demoImage = try await capture(demo, shadow: false)
            demo.close()

            try renderGIF(effect: .water, windowImage: demoImage, to: outputDirectory.appendingPathComponent("water.gif"))
            try renderGIF(effect: .steam, windowImage: demoImage, to: outputDirectory.appendingPathComponent("steam.gif"))
            logInfo("Screenshots written to \(outputDirectory.path)")
            return true
        } catch {
            logError("Screenshots failed: \(error.liquidDescription)")
            return false
        }
    }

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Captures one of our own windows (needs Screen Recording permission).
    private static func capture(_ window: NSWindow, shadow: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.windowNotFound("own window \(window.windowNumber)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 2)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = WindowCapture.colorSpaceName
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.snapshotFailed("cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.snapshotFailed("cannot write \(url.lastPathComponent)") }
    }

    /// Renders the effect over a synthetic desktop and writes an animated GIF.
    private static func renderGIF(effect: LiquidEffect, windowImage: CGImage, to url: URL) throws {
        let renderer = try LiquidRenderer.shared().get()
        let view = CGSize(width: 720, height: 460)
        let windowRect = CGRect(x: 160, y: 36, width: 400, height: 270)
        let target = SelfTest.syntheticDockIcon(4, viewSize: view)   // fifth icon of the synthetic Dock
        guard let desktop = SelfTest.syntheticDesktop(width: Int(view.width), height: Int(view.height),
                                                      scale: 1, dockIcon: target) else {
            throw CaptureError.snapshotFailed("desktop")
        }
        let (windowTexture, pixels) = try renderer.makeTexture(from: windowImage, colorSpace: WindowCapture.colorSpace,
                                                               keepPixels: true)
        let (backgroundTexture, _) = try renderer.makeTexture(from: desktop, colorSpace: WindowCapture.colorSpace,
                                                              keepPixels: false)
        guard let pixels else { throw RenderError.texture("no pixel data") }
        var input = LiquidSceneInput(viewSize: view, windowRect: windowRect, target: target,
                                     rippleOrigin: CGPoint(x: windowRect.minX + (effect == .water ? 40 : 20), y: windowRect.minY + 14),
                                     edge: .bottom, drainRadius: 10, floorY: target.y - 26, opaqueBackground: true,
                                     waterColor: MinimizeCoordinator.shaderColor(AppSettings.shared.waterColor),
                                     colorStrength: Float(AppSettings.shared.colorStrength), cornerRadius: 12,
                                     effect: effect, alphaAt: { u, v in pixels.alpha(u: u, v: v) })
        input.seed = 2026
        let scene = try LiquidScene.build(input)
        let session = try LiquidRenderSession(renderer: renderer, scene: scene, windowTexture: windowTexture,
                                              backgroundTexture: backgroundTexture)

        let fps: Float = 20
        let frameCount = Int((scene.totalDuration * fps).rounded(.up)) + 1
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                frameCount + 1, nil) else {
            throw CaptureError.snapshotFailed("cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        for index in 0..<frameCount {
            let t = Float(index) / fps
            let frame = try session.renderOffscreen(time: t, pixelWidth: Int(view.width), pixelHeight: Int(view.height))
            guard let image = SelfTest.image(from: frame) else { throw CaptureError.snapshotFailed("frame \(index)") }
            // Hold the first frame (the untouched window) so the start is visible.
            let delay = index == 0 ? 1.0 : Double(1 / fps)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay,
                                                          kCGImagePropertyGIFUnclampedDelayTime as String: delay],
            ] as CFDictionary)
        }
        // Empty desktop for a moment before the loop starts again.
        let last = try session.renderOffscreen(time: scene.totalDuration, pixelWidth: Int(view.width), pixelHeight: Int(view.height))
        if let image = SelfTest.image(from: last) {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.8,
                                                          kCGImagePropertyGIFUnclampedDelayTime as String: 0.8],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.snapshotFailed("cannot write \(url.lastPathComponent)") }
    }
}
