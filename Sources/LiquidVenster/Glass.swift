import AppKit
import SwiftUI

extension View {
    /// Apple's Liquid Glass (macOS 26+); a translucent material on older systems.
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background((tint ?? .clear).opacity(0.25),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
    }
}

/// Borderless, transparent floating panel that hosts SwiftUI content drawn with Liquid Glass.
/// It never activates the app; panels that need typing can still become key.
final class GlassPanel: NSPanel {
    private let allowsKey: Bool
    private var fadeGeneration = 0

    init(size: NSSize, canBecomeKey: Bool, level: NSWindow.Level = .floating) {
        allowsKey = canBecomeKey
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        self.level = level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    /// The screen that contains the mouse pointer (where panels should appear).
    static var screenWithMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func fadeIn() {
        fadeGeneration += 1
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    /// Fades out, then orders out. A timer finishes the job instead of the animation's completion
    /// handler (which can arrive seconds late in a background app), and a newer fadeIn cancels it.
    func fadeOut(completion: (() -> Void)? = nil) {
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                completion?()
            }
        }
    }
}
