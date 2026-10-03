import AppKit
@preconcurrency import ApplicationServices
import Runtime

/// ReelNext: the rewrite's runtime on one display. It runs beside the shipped Reel until the cutover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var loop: Loop?
    private var ipc: IPCBridge?
    private var menu: MenuBar?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            logLine("reelnext: waiting for Accessibility permission")
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

    private func launch() {
        let loop = Loop()
        let ipc = IPCBridge(loop: loop)
        if !ipc.start() { logLine("reelnext: IPC socket failed to start") }
        menu = MenuBar(loop: loop)
        loop.start()
        self.loop = loop
        self.ipc = ipc
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ipc?.stop()
        loop?.quit()
        return loop == nil ? .terminateNow : .terminateCancel
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
