import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusItem.self
    private var statusItem: NSStatusItem!
    private let engine: SyncEngine
    private let panel: PanelWindow
    private var panelVisible = true

    init(engine: SyncEngine, panel: PanelWindow) {
        self.engine = engine
        self.panel = panel
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "quote.bubble",
                                          accessibilityDescription: "LyricBar")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let offsetMs = Int((engine.offset * 1000).rounded())
        menu.addItem(withTitle: "Sync offset: \(offsetMs > 0 ? "+" : "")\(offsetMs) ms",
                     action: nil, keyEquivalent: "")
        menu.addItem(item("Lyrics earlier  (−100 ms)", #selector(earlier)))
        menu.addItem(item("Lyrics later  (+100 ms)", #selector(later)))
        menu.addItem(item("Reset offset", #selector(resetOffset)))
        menu.addItem(.separator())
        menu.addItem(item(panelVisible ? "Hide panel" : "Show panel", #selector(togglePanel)))
        menu.addItem(.separator())
        menu.addItem(item("Quit LyricBar", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func earlier() { engine.nudge(-0.1) }
    @objc private func later()   { engine.nudge(0.1) }
    @objc private func resetOffset() { engine.offset = 0 }
    @objc private func togglePanel() {
        panelVisible.toggle()
        panelVisible ? panel.show() : panel.orderOut(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
