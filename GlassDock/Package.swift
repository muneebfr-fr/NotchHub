// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlassDock",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "GlassDock", path: "Sources/GlassDock")
    ]
)
