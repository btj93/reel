import AppKit
@preconcurrency import ApplicationServices
import Runtime

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var loop: Loop?
    private var ipc: IPCBridge?
    private var menu: MenuBar?
    private var waitingItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        redirectLogsToFile()
        // kill and Ctrl-C quit through applicationShouldTerminate, so off-screen windows are released first.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Reel window management")
        guard AXIsProcessTrusted() else {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Reel?"
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Waiting for Accessibility permission", action: nil, keyEquivalent: ""))
            let settings = NSMenuItem(title: "Open System Settings", action: #selector(openAccessibility), keyEquivalent: "")
            let quit = NSMenuItem(title: "Quit Reel", action: #selector(quit), keyEquivalent: "q")
            settings.target = self
            quit.target = self
            menu.addItem(settings)
            menu.addItem(quit)
            item.menu = menu
            waitingItem = item
            logLine("reel: waiting for Accessibility permission")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.launch()
                }
            }
            return
        }
        launch()
    }

    private func redirectLogsToFile() {
        let override = ProcessInfo.processInfo.environment["REEL_LOG_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        guard override != nil || Bundle.main.bundleIdentifier != nil else { return }
        let logPath = override ?? NSHomeDirectory() + "/Library/Logs/Reel/reel.log"
        do { try prepareLogFile(at: logPath) }
        catch { logLine("log: cannot prepare file \(error.localizedDescription)"); return }
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func launch() {
        if let waitingItem { NSStatusBar.system.removeStatusItem(waitingItem) }
        waitingItem = nil
        let loop = Loop()
        let ipc = IPCBridge(loop: loop)
        if !ipc.start() { logLine("reel: IPC socket failed to start") }
        menu = MenuBar(loop: loop)
        loop.start()
        self.loop = loop
        self.ipc = ipc
        // Accessibility switched off while running leaves this process's event taps in the input path, and macOS can
        // stall the whole system's input until it exits. Without AX no window can be moved back either, so just exit.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !AXIsProcessTrusted() else { return }
                logLine("reel: Accessibility permission was revoked; exiting so keyboard and mouse input are not blocked")
                exit(0)
            }
        }
    }

    /// Later, not cancel: a cancel would also cancel a logout or restart that asked this app to quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let loop else { return .terminateNow }
        ipc?.stop()
        loop.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
