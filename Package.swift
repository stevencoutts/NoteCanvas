// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .target(name: "Store", dependencies: ["PageModel"]),
        .executableTarget(name: "Checks", dependencies: ["PageModel", "Store"]),
    ],
    swiftLanguageModes: [.v5]
)
