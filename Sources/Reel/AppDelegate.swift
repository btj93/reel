import AppKit
import Config
import Core
import Platform
import ServiceManagement
import WindowManager

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        redirectLogsToFile()
        #if DEBUG
        print("[Reel] applicationDidFinishLaunching")
        fflush(stdout)
        #endif

        // Hide from Dock (works without Info.plist LSUIElement, so we can run
        // the bare debug binary without a .app bundle)
        NSApp.setActivationPolicy(.accessory)

        // Prevent App Nap from throttling us
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "Reel window management"
        )

        // Check Accessibility permission
        let trusted = AXIsProcessTrusted()
        #if DEBUG
        print("[Reel] AXIsProcessTrusted = \(trusted)")
        fflush(stdout)
        #endif

        if !trusted {
            promptForAccessibility()
            return
        }

        startWindowManager()
        setupMenuBar()
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
            button.image = makeMenuBarIcon()
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
            menu.addItem(NSMenuItem(title: "Reel v0.2.2", action: nil, keyEquivalent: "")) // x-release-please-version
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
            menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ","))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Recover Windows", action: #selector(recoverWindows), keyEquivalent: ""))
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
        #if DEBUG
        print("[Reel] Ready")
        fflush(stdout)
        #endif
    }

    private func applyLoginItem(enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else {
            if enabled {
                #if DEBUG
                print("[Reel] start_at_login requires running as .app bundle — ignoring")
                fflush(stdout)
                #endif
            }
            return
        }
        let service = SMAppService.mainApp
        do {
            if enabled && service.status != .enabled {
                try service.register()
                #if DEBUG
                print("[Reel] Registered as login item")
                fflush(stdout)
                #endif
            } else if !enabled && service.status == .enabled {
                try service.unregister()
                #if DEBUG
                print("[Reel] Unregistered login item")
                fflush(stdout)
                #endif
            }
        } catch {
            #if DEBUG
            print("[Reel] Login item error: \(error)")
            fflush(stdout)
            #endif
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

    @objc private func openConfig() {
        let path = ReelConfig.configPath
        if !FileManager.default.fileExists(atPath: path) {
            ReelConfig.createDefaultConfig()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func recoverWindows() {
        windowManager?.recoverWindows()
    }

    @objc private func clearPositions() {
        windowManager?.snapshotStore?.clearAll()
        windowManager?.snapshotStore?.persistToDisk()
        #if DEBUG
        print("[Reel] Cleared all saved positions")
        fflush(stdout)
        #endif
    }

    @objc private func quit() {
        windowManager?.shutdown()
        NSApp.terminate(nil)
    }

    // MARK: - Log File Redirect

    /// When running as .app bundle, redirect stdout/stderr to ~/Library/Logs/Reel/reel.log.
    /// Keeps one rotated backup (reel.log.1) at 1 MB.
    private func redirectLogsToFile() {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let fm = FileManager.default
        let logDir = NSHomeDirectory() + "/Library/Logs/Reel"
        let logPath = logDir + "/reel.log"
        let backupPath = logDir + "/reel.log.1"

        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // Rotate if over 1 MB
        if let attrs = try? fm.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            try? fm.removeItem(atPath: backupPath)
            try? fm.moveItem(atPath: logPath, toPath: backupPath)
        }

        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
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

    // MARK: - Menu Bar Icon

    /// Draw a menu bar template icon: three window columns on a strip.
    /// Center column is taller (focused). Thin horizontal rails connect them.
    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let color = NSColor.black

            // Three columns: left, center (focused/taller), right
            // Heights: side columns shorter, center taller
            let gap: CGFloat = 1.5
            let colW: CGFloat = 4.5
            let sideH: CGFloat = 10
            let centerH: CGFloat = 14
            let r: CGFloat = 1.5

            let totalW = colW * 3 + gap * 2  // 16.5
            let x0 = (size.width - totalW) / 2

            // Side columns — slightly transparent
            color.withAlphaComponent(0.45).setFill()
            let sideY = (size.height - sideH) / 2
            NSBezierPath(roundedRect: NSRect(x: x0, y: sideY, width: colW, height: sideH), xRadius: r, yRadius: r).fill()
            NSBezierPath(roundedRect: NSRect(x: x0 + colW * 2 + gap * 2, y: sideY, width: colW, height: sideH), xRadius: r, yRadius: r).fill()

            // Center column — full opacity, taller
            color.setFill()
            let centerY = (size.height - centerH) / 2
            NSBezierPath(roundedRect: NSRect(x: x0 + colW + gap, y: centerY, width: colW, height: centerH), xRadius: r, yRadius: r).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
