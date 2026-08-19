import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: SyncEngine!
    private var panel: PanelWindow!
    private var menu: MenuBarController!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no cmd-tab

        engine = SyncEngine()
        panel = PanelWindow(size: NSSize(width: 380, height: 170),
                            root: PanelView(engine: engine))
        menu = MenuBarController(engine: engine, panel: panel)

        panel.show()
        engine.start()
    }

    func applicationWillTerminate(_ n: Notification) {
        panel?.persistFrame()
        engine?.stop()
    }
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    // Top-level code is nonisolated in Swift 5 mode; the delegate must outlive this scope.
    objc_setAssociatedObject(app, "lyricbar.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
