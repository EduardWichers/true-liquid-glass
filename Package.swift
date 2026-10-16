// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiquidVenster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LiquidVenster",
            path: "Sources/LiquidVenster",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
