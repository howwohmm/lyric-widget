import AppKit
import SwiftUI

/// Desktop-level widget window. Level and collectionBehavior are the exact
/// combination measured in the spike — see docs/SPIKES.md for the full layer stack.
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// kCGDesktopIconWindowLevel + 1 == -2147483602. Above the wallpaper and the Finder
    /// desktop-icon window, below every ordinary window. +1 not +2: at +2 it starts
    /// showing up in window pickers and screen-share lists.
    static let desktopWidgetLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private static let frameKey = "quest.ohm.lyricbar.frame"

    convenience init<Content: View>(size: NSSize, root: Content) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless], backing: .buffered, defer: false)

        level = Self.desktopWidgetLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none

        contentView = NSHostingView(rootView: root)
        restoreFrame(defaultSize: size)
    }

    /// Clamp into a visible screen so a disconnected display never strands the panel.
    func restoreFrame(defaultSize: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.minX + 48, y: screen.maxY - defaultSize.height - 48)
        if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
            let saved = NSRectFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                origin = saved.origin
            }
        }
        setFrame(NSRect(origin: origin, size: defaultSize), display: true)
    }

    func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    func setClickThrough(_ on: Bool) { ignoresMouseEvents = on }

    func show() { orderFrontRegardless() }
}
