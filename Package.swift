// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NoteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageModel"),
        .executableTarget(name: "Checks", dependencies: ["PageModel"]),
    ],
    swiftLanguageModes: [.v5]
)
