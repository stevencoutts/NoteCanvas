// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .target(name: "OneStore"),
        .target(name: "OneImport", dependencies: ["PageModel", "OneStore"]),
        .target(name: "CanvasKit", dependencies: ["PageModel", "Store", "OneStore", "OneImport"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store", "OneStore", "OneImport", "CanvasKit"]),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasKit"]),
        .executableTarget(name: "DemoNotebook", dependencies: ["PageModel", "Store"]),
    ],
    swiftLanguageModes: [.v5]
)
