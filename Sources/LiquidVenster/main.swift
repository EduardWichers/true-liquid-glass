import AppKit

let arguments = CommandLine.arguments

// `LiquidVenster --selftest [--output <map>]` checks the geometry, the animation model
// and renders real frames on the GPU without any UI or permissions.
if arguments.contains("--selftest") {
    var output: String?
    if let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count {
        output = arguments[index + 1]
    }
    exit(SelfTest.run(outputDirectory: output) ? 0 : 1)
}

// `--installer-pages <folder>` writes the installer's welcome/conclusion pages (10 languages).
if let index = arguments.firstIndex(of: "--installer-pages") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: --installer-pages <folder>\n".utf8))
        exit(64)
    }
    do {
        try InstallerPages.write(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("installer pages failed: \(error.liquidDescription)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate(arguments: arguments)
    application.delegate = appDelegate
    // A background service: no Dock icon, only the water drop in the menu bar.
    application.setActivationPolicy(.accessory)
    // `run()` never returns, so `appDelegate` (NSApplication only keeps a weak reference) stays alive.
    withExtendedLifetime(appDelegate) {
        application.run()
    }
}
