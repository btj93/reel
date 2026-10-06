import Foundation

private let logLimit: UInt64 = 1_000_000

private func rotateLogFile(at path: String) throws {
    let manager = FileManager.default
    if let size = try? manager.attributesOfItem(atPath: path)[.size] as? UInt64, size > logLimit {
        let backup = path + ".1"
        if manager.fileExists(atPath: backup) { try manager.removeItem(atPath: backup) }
        try manager.moveItem(atPath: path, toPath: backup)
    }
}

public func prepareLogFile(at path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try rotateLogFile(at: path)
    sessionLog.configure(path)
}

/// Serializes runtime output with descriptor rotation. A bare binary's terminal is never redirected.
private final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?

    func configure(_ path: String) { lock.withLock { self.path = path } }

    func write(_ line: String) {
        lock.withLock {
            if let path {
                fflush(stdout)
                var output = stat(), file = stat()
                if fstat(STDOUT_FILENO, &output) == 0, stat(path, &file) == 0,
                   output.st_dev == file.st_dev, output.st_ino == file.st_ino, output.st_size > logLimit {
                    fflush(stderr)
                    do {
                        try rotateLogFile(at: path)
                        freopen(path, "a", stdout)
                        freopen(path, "a", stderr)
                    } catch { /* Keep the open descriptors; the next line retries rotation. */ }
                }
            }
            print(line)
        }
    }
}

private let sessionLog = SessionLog()

func writeRuntimeLog(_ line: String) { sessionLog.write(line) }

package struct LogLimiter {
    private var last: [String: Double] = [:]

    package init() {}

    package mutating func allows(_ line: String, at now: Double) -> Bool {
        let key: String
        if line.contains("focus dropped ") {
            key = line.split(separator: " ").filter { $0.hasPrefix("source=") || $0.hasPrefix("reason=") }.joined(separator: " ")
        } else if line.contains("adoption held") { key = "adoption-held" }
        else { return true }
        if let previous = last[key], now - previous < 2 { return false }
        if last.count >= 64, let oldest = last.min(by: { $0.value < $1.value })?.key { last[oldest] = nil }
        last[key] = now
        return true
    }
}
