import Cocoa

// Explicit, nib-free entry point. @NSApplicationMain relied entirely on
// MainMenu.xib's File's Owner -> delegate outlet to wire up AppDelegate;
// now that the xib is gone, we set the delegate here instead.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.activate(ignoringOtherApps: true)
app.run()

