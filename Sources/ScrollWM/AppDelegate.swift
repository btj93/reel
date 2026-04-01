import AppKit
import Core
import Platform
import ServiceManagement
import WindowManager

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[ScrollWM] applicationDidFinishLaunching")
        fflush(stdout)

        // Hide from Dock (works without Info.plist LSUIElement, so we can run
        // the bare debug binary without a .app bundle)
        NSApp.setActivationPolicy(.accessory)

        // Prevent App Nap from throttling us
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "ScrollWM window management"
        )

        // Check Accessibility permission
        let trusted = AXIsProcessTrusted()
        print("[ScrollWM] AXIsProcessTrusted = \(trusted)")
        fflush(stdout)

        if !trusted {
            promptForAccessibility()
            return
        }

        setupMenuBar()
        startWindowManager()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.shutdown()
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Poll until granted
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.permissionTimer?.invalidate()
                self?.permissionTimer = nil
                self?.setupMenuBar()
                self?.startWindowManager()
            }
        }

        setupMenuBar(waiting: true)
    }

    private func setupMenuBar(waiting: Bool = false) {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }

        if let button = statusItem.button {
            button.title = "⊞"
            button.font = NSFont.systemFont(ofSize: 14)
        }

        let menu = NSMenu()

        if waiting {
            menu.addItem(NSMenuItem(title: "Waiting for Accessibility permission...", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Open System Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        } else {
            let isPaused = windowManager?.isPaused ?? false
            menu.addItem(NSMenuItem(title: "ScrollWM v0.1.0", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())

            // Keybinding actions
            let keybindings = windowManager?.config.keybindings ?? [:]
            let actions: [(action: String, title: String, tag: Int)] = [
                ("focus_left",       "Focus Left",        1),
                ("focus_right",      "Focus Right",       2),
                ("move_left",        "Move Left",         3),
                ("move_right",       "Move Right",        4),
                ("cycle_width",      "Cycle Width",       5),
                ("toggle_full_width","Toggle Full Width",  6),
                ("toggle_floating",  "Toggle Floating",   7),
                ("close_window",     "Close Window",      8),
            ]
            for entry in actions {
                let keyString = keybindings[entry.action] ?? ""
                let parsed = AppDelegate.parseKeyEquivalent(keyString)
                let item = NSMenuItem(title: entry.title, action: #selector(handleMenuAction(_:)), keyEquivalent: parsed.key)
                item.keyEquivalentModifierMask = parsed.modifiers
                item.tag = entry.tag
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())

            let pauseItem = NSMenuItem(
                title: isPaused ? "Resume" : "Pause",
                action: #selector(togglePause),
                keyEquivalent: "p"
            )
            menu.addItem(pauseItem)
            menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Clear Saved Positions", action: #selector(clearPositions), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        }

        statusItem.menu = menu
    }

    private func startWindowManager() {
        let wm = WindowManager()
        wm.start()
        windowManager = wm
        applyLoginItem(enabled: wm.config.startAtLogin)
        print("[ScrollWM] Ready")
        fflush(stdout)
    }

    private func applyLoginItem(enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else {
            if enabled {
                print("[ScrollWM] start_at_login requires running as .app bundle — ignoring")
                fflush(stdout)
            }
            return
        }
        let service = SMAppService.mainApp
        do {
            if enabled && service.status != .enabled {
                try service.register()
                print("[ScrollWM] Registered as login item")
                fflush(stdout)
            } else if !enabled && service.status == .enabled {
                try service.unregister()
                print("[ScrollWM] Unregistered login item")
                fflush(stdout)
            }
        } catch {
            print("[ScrollWM] Login item error: \(error)")
            fflush(stdout)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        let actionMap: [Int: HotkeyAction] = [
            1: .focusLeft,
            2: .focusRight,
            3: .moveColumnLeft,
            4: .moveColumnRight,
            5: .cycleWidthPreset,
            6: .toggleFullWidth,
            7: .toggleFloating,
            8: .closeWindow,
        ]
        if let action = actionMap[sender.tag] {
            windowManager?.performAction(action)
        }
    }

    @objc private func togglePause() {
        windowManager?.togglePause()
        setupMenuBar()
    }

    @objc private func reloadConfig() {
        windowManager?.reloadConfig()
        if let config = windowManager?.config {
            applyLoginItem(enabled: config.startAtLogin)
        }
        setupMenuBar()
    }

    @objc private func clearPositions() {
        windowManager?.positionMemory?.clearAll()
        windowManager?.positionMemory?.persistToDisk()
        print("[ScrollWM] Cleared all saved positions")
        fflush(stdout)
    }

    @objc private func quit() {
        windowManager?.shutdown()
        NSApp.terminate(nil)
    }

    // MARK: - Key String → NSMenuItem Key Equivalent

    /// Convert a key string like "hyper-h" into an NSMenuItem keyEquivalent + modifierMask.
    private static func parseKeyEquivalent(_ str: String) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard !str.isEmpty else { return ("", []) }
        let parts = str.lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return ("", []) }

        var modifiers: NSEvent.ModifierFlags = []
        let keyName = parts.last!

        for part in parts.dropLast() {
            switch part {
            case "hyper":
                modifiers.insert(.control)
                modifiers.insert(.shift)
                modifiers.insert(.command)
                modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command": modifiers.insert(.command)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "fn": modifiers.insert(.function)
            default: break
            }
        }

        let key: String
        switch keyName {
        case "space": key = " "
        case "return": key = "\r"
        case "tab": key = "\t"
        case "escape": key = "\u{1b}"
        case "delete": key = "\u{08}"
        case "left": key = "\u{F702}"
        case "right": key = "\u{F703}"
        case "up": key = "\u{F700}"
        case "down": key = "\u{F701}"
        default: key = keyName
        }

        return (key, modifiers)
    }
}
