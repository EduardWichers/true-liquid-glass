import AppKit
import MetalKit

/// A borderless, click-through window covering one display that plays the water animation.
///
/// Safety nets:
///  - a watchdog closes the overlay no matter what after `duration + 3 s`;
///  - if the first frame never reports "presented", the minimize is triggered anyway after 0.35 s;
///  - repeated render failures abort the overlay instead of leaving a frozen screen;
///  - the overlay never takes mouse or keyboard input.
@MainActor
final class LiquidOverlay: NSObject, MTKViewDelegate {
    enum EndReason {
        case completed
        case aborted(String)
    }

    /// Called once, as soon as the first frame (showing the untouched window) is on screen.
    var onFirstFramePresented: (() -> Void)?
    /// Polled after the animation: the overlay keeps covering the screen while this returns false (max 1 s).
    var isTargetGone: () -> Bool = { true }
    /// Called exactly once when the overlay is gone.
    var onEnd: ((EndReason) -> Void)?

    let displayID: CGDirectDisplayID?
    let screenFrame: CGRect

    private let window: NSWindow
    private let view: MTKView
    private let session: LiquidRenderSession
    private let speed: Double
    private var startTime: CFTimeInterval?
    private var presentedFired = false
    private var presentHandlerInstalled = false
    private var drawingStopped = false
    private var ended = false
    private var fading = false
    private var frameFailures = 0
    private var watchdog: DispatchWorkItem?
    private var presentFallback: DispatchWorkItem?

    init(screen: NSScreen, session: LiquidRenderSession, speed: Double) {
        let frame = screen.frame
        self.session = session
        self.speed = AppSettings.clamp(speed, to: AppSettings.speedRange, fallback: 1)
        self.displayID = ScreenGeometry.displayID(of: screen)
        self.screenFrame = frame

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        // Never an opaque window: until the first frame arrives it must show what is
        // underneath instead of a black rectangle.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.title = "True Liquid Glass overlay"
        self.window = window

        let view = MTKView(frame: CGRect(origin: .zero, size: frame.size), device: session.renderer.device)
        view.colorPixelFormat = LiquidRenderer.outputFormat
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = max(60, screen.maximumFramesPerSecond)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.colorspace = WindowCapture.colorSpace
            layer.backgroundColor = CGColor.clear
        } else {
            view.layer?.isOpaque = false
        }
        window.contentView = view
        self.view = view
        super.init()
        view.delegate = self
    }

    var realDuration: Double { Double(session.scene.totalDuration) / speed }

    func start() {
        window.orderFrontRegardless()
        view.isPaused = false

        let watchdog = DispatchWorkItem { [weak self] in
            self?.abort("watchdog: animation took longer than expected")
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + realDuration + 3.0, execute: watchdog)

        let fallback = DispatchWorkItem { [weak self] in
            // Only when we did draw: without any frame the no-frames check below takes over
            // and the window keeps its normal minimize animation.
            guard let self, !self.presentedFired, !self.ended, self.startTime != nil else { return }
            logWarning("First frame not confirmed by the system; continuing anyway")
            self.firePresented()
        }
        presentFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: fallback)

        // No frame at all (locked screen, display asleep, window server busy): stop quickly
        // so the user is not left waiting for the watchdog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.ended, self.startTime == nil else { return }
            self.abort("no frames drawn (screen locked or asleep?)")
        }
    }

    /// Stops immediately (no fade). Safe to call multiple times.
    func abort(_ message: String) {
        guard !ended else { return }
        drawingStopped = true
        view.isPaused = true
        close(.aborted(message))
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !drawingStopped, !ended else { return }
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let t = Float((now - (startTime ?? now)) * speed)

        guard let drawable = view.currentDrawable,
              let commandBuffer = session.renderer.queue.makeCommandBuffer() else {
            frameFailures += 1
            if frameFailures > 20 { abort("no drawable/command buffer available") }
            return
        }
        commandBuffer.label = "liquid frame"
        do {
            try session.encode(into: commandBuffer, target: drawable.texture, time: t)
        } catch {
            abort("rendering failed: \(error.liquidDescription)")
            return
        }
        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                Task { @MainActor [weak self] in
                    logError("GPU error during animation: \(error.localizedDescription)")
                    self?.frameFailures += 1
                    if (self?.frameFailures ?? 0) > 5 { self?.abort("repeated GPU errors") }
                }
            }
        }
        if !presentHandlerInstalled {
            presentHandlerInstalled = true
            drawable.addPresentedHandler { _ in
                Task { @MainActor [weak self] in self?.firePresented() }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if t >= session.scene.totalDuration {
            drawingStopped = true
            view.isPaused = true
            waitForTargetThenFade(deadline: CACurrentMediaTime() + 1.0)
        }
    }

    // MARK: private

    private func firePresented() {
        guard !presentedFired, !ended else { return }
        presentedFired = true
        presentFallback?.cancel()
        let callback = onFirstFramePresented
        onFirstFramePresented = nil
        callback?()
    }

    /// The last frame shows the clean background; keep it up until the real window is
    /// really minimized so it can never "flash" back for a moment.
    private func waitForTargetThenFade(deadline: CFTimeInterval) {
        guard !ended else { return }
        if !presentedFired { firePresented() }
        if isTargetGone() {
            fadeOut()
        } else if CACurrentMediaTime() > deadline {
            logWarning("Window was not yet minimized after the animation")
            fadeOut()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForTargetThenFade(deadline: deadline)
            }
        }
    }

    private func fadeOut() {
        guard !ended, !fading else { return }
        fading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            self.window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.close(.completed) }
        })
        // In case the animation completion never fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.close(.completed)
        }
    }

    private func close(_ reason: EndReason) {
        guard !ended else { return }
        ended = true
        watchdog?.cancel()
        presentFallback?.cancel()
        view.isPaused = true
        view.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        onFirstFramePresented = nil
        let callback = onEnd
        onEnd = nil
        callback?(reason)
    }
}
