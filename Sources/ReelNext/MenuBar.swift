import AppKit
import Runtime

/// Status item: state, the last config error, the separate-Spaces warning, pause, reload and quit.
@MainActor
final class MenuBar: NSObject {
    private let loop: Loop
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let error = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let separateSpaces = NSMenuItem(title: "⚠︎ Shared strip disabled — turn off \"Displays have separate Spaces\"",
                                            action: #selector(openDesktopSettings), keyEquivalent: "")

    init(loop: Loop) {
        self.loop = loop
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        state.isEnabled = false
        error.isEnabled = false
        pause.target = self
        separateSpaces.target = self
        separateSpaces.toolTip = "System Settings → Desktop & Dock → Mission Control → Displays have separate Spaces"
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        let quit = NSMenuItem(title: "Quit ReelNext", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        [state, error, separateSpaces, .separator(), pause, reload, .separator(), quit].forEach(menu.addItem)
        item.menu = menu
        loop.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let failed = loop.configError != nil
        item.button?.title = failed ? "Reel⚠︎" : loop.paused ? "Reel‖" : "Reel"
        state.title = loop.paused ? "ReelNext: paused" : "ReelNext: running"
        error.isHidden = !failed
        error.title = "Config error: \(loop.configError ?? "")"
        pause.title = loop.paused ? "Resume" : "Pause"
        separateSpaces.isHidden = !loop.world.topology.separateSpaces
    }

    @objc private func togglePause() { loop.setPaused(!loop.paused) }
    @objc private func reloadConfig() { loop.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openDesktopSettings() {
        URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension").map { _ = NSWorkspace.shared.open($0) }
    }
}
