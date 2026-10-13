import AppKit
import CanvasKit

let app = NSApplication.shared
let shell = AppShell()
app.delegate = shell
app.setActivationPolicy(.regular)
app.run()
