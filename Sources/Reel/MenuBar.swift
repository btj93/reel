import AppKit
import Runtime
import Platform
import Foundation
import ServiceManagement

/// Status item: state, the last config error, the separate-Spaces warning, pause, reload and quit.
@MainActor
final class MenuBar: NSObject {
    private let loop: Loop
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let error = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
    private let separateSpaces = NSMenuItem(title: "⚠︎ Shared strip disabled. turn off \"Displays have separate Spaces\"",
                                            action: #selector(openDesktopSettings), keyEquivalent: "")

    init(loop: Loop) {
        self.loop = loop
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        state.isEnabled = false
        error.isEnabled = false
        let version = NSMenuItem(title: "Reel v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        login.target = self
        pause.target = self
        separateSpaces.target = self
        separateSpaces.toolTip = "System Settings → Desktop & Dock → Mission Control → Displays have separate Spaces"
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        let quit = NSMenuItem(title: "Quit Reel", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        [state, error, separateSpaces, .separator()].forEach(menu.addItem)
        let actions: [(String, HotkeyAction)] = [
            ("Focus Left", .focusLeft), ("Focus Right", .focusRight), ("Focus Up", .focusUp), ("Focus Down", .focusDown),
            ("Move Column Left", .moveColumnLeft), ("Move Column Right", .moveColumnRight), ("Cycle Width", .cycleWidthPreset),
            ("Toggle Full Width", .toggleFullWidth), ("Toggle Floating", .toggleFloating), ("Close Window", .closeWindow),
        ]
        for (title, action) in actions {
            let entry = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action
            menu.addItem(entry)
        }
        let open = NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ",")
        let recover = NSMenuItem(title: "Recover Windows", action: #selector(recover), keyEquivalent: "")
        let clear = NSMenuItem(title: "Clear Saved Positions", action: #selector(clearPositions), keyEquivalent: "")
        [open, recover, clear].forEach { $0.target = self }
        [.separator(), pause, reload, open, login, .separator(), recover, clear, quit].forEach(menu.addItem)
        item.menu = menu
        loop.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let failed = loop.configError != nil
        // The original Reel icon: paused dims it, a config error adds a warning sign beside it.
        item.button?.image = MenuBar.icon
        item.button?.imagePosition = .imageLeading
        item.button?.appearsDisabled = loop.paused
        item.button?.title = failed ? "⚠︎" : ""
        state.title = loop.paused ? "Reel: paused" : "Reel: running"
        error.isHidden = !failed
        error.title = "Config error: \(loop.configError ?? "")"
        pause.title = loop.paused ? "Resume" : "Pause"
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        separateSpaces.isHidden = !loop.world.topology.separateSpaces
    }

    /// Three window columns on a strip, the centre one taller (focused). A template image, so it follows the menu bar.
    static let icon: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let gap: CGFloat = 1.5, columnWidth: CGFloat = 4.5, sideHeight: CGFloat = 10, centreHeight: CGFloat = 14, radius: CGFloat = 1.5
            let x0 = (size.width - (columnWidth * 3 + gap * 2)) / 2
            NSColor.black.withAlphaComponent(0.45).setFill()
            let sideY = (size.height - sideHeight) / 2
            for x in [x0, x0 + (columnWidth + gap) * 2] {
                NSBezierPath(roundedRect: NSRect(x: x, y: sideY, width: columnWidth, height: sideHeight), xRadius: radius, yRadius: radius).fill()
            }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0 + columnWidth + gap, y: (size.height - centreHeight) / 2, width: columnWidth,
                                             height: centreHeight), xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { logLine("login: \(error.localizedDescription)") }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? HotkeyAction { loop.hotkey(action) }
    }
    @objc private func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: loop.paths.configFile)) }
    @objc private func recover() { loop.recover() }
    @objc private func clearPositions() {
        let outcome = loop.request(.clearPositions)
        if outcome == .accepted { loop.store.clear() }
        else { logLine("positions: clear refused \(outcome)") }
    }

    @objc private func togglePause() { loop.setPaused(!loop.paused) }
    @objc private func reloadConfig() { loop.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openDesktopSettings() {
        URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension").map { _ = NSWorkspace.shared.open($0) }
    }
}
