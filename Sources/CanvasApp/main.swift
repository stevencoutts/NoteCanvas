import AppKit
import CanvasKit

let app = NSApplication.shared
let shell = AppShell()
app.delegate = shell
app.setActivationPolicy(.regular)
let icon = AppIcon.image()
app.applicationIconImage = icon
let iconObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main
) { _ in app.applicationIconImage = icon }
withExtendedLifetime(iconObserver) { app.run() }
