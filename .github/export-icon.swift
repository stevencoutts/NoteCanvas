import AppKit
import Foundation

@main
enum ExportIcon {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: export-icon <png>\n", stderr)
            exit(2)
        }
        let image = AppIcon.image()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fputs("could not draw the app icon\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        } catch {
            fputs("could not write the app icon\n", stderr)
            exit(1)
        }
    }
}
