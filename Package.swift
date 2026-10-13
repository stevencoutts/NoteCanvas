// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .target(name: "CanvasKit", dependencies: ["PageModel", "Store"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store", "CanvasKit"]),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasKit"]),
    ],
    swiftLanguageModes: [.v5]
)
