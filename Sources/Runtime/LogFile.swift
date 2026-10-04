import Foundation

public func prepareLogFile(at path: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let size = try? manager.attributesOfItem(atPath: path)[.size] as? UInt64, size > 1_000_000 {
        let backup = path + ".1"
        if manager.fileExists(atPath: backup) { try manager.removeItem(atPath: backup) }
        try manager.moveItem(atPath: path, toPath: backup)
    }
}
