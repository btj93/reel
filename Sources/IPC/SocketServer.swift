import Foundation

/// Unix domain socket server for IPC.
/// Listens on /tmp/scrollwm_{uid}.sock for JSON-encoded commands.
public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    /// Called when a command is received. Returns a response.
    public var onCommand: ((ScrollWMCommand) -> ScrollWMResponse)?

    public var onMessage: ((IPCMessage) -> ScrollWMResponse)?

    public init() {
        self.socketPath = scrollWMSocketPath()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() -> Bool {
        // Remove stale socket
        unlink(socketPath)

        // Create socket
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            print("[IPC] Failed to create socket")
            return false
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenerFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("[IPC] Failed to bind to \(socketPath): \(String(cString: strerror(errno)))")
            close(listenerFD)
            return false
        }

        // Listen
        guard listen(listenerFD, 5) == 0 else {
            print("[IPC] Failed to listen")
            close(listenerFD)
            return false
        }

        // Non-blocking accept via GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenerFD, fd >= 0 {
                close(fd)
                self?.listenerFD = -1
            }
        }
        source.resume()
        acceptSource = source
        isRunning = true

        print("[IPC] Listening on \(socketPath)")
        fflush(stdout)
        return true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        unlink(socketPath)
        isRunning = false
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Read command (max 4KB)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &buffer, buffer.count)

        guard bytesRead > 0 else {
            close(clientFD)
            return
        }

        let data = Data(buffer[0..<bytesRead])

        // Parse command
        let response: ScrollWMResponse
        if let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Try JSON protocol first
            if let jsonData = rawStr.data(using: .utf8),
               let message = try? JSONDecoder().decode(IPCMessage.self, from: jsonData) {
                response = onMessage?(message) ?? onCommand.flatMap { handler in
                    ScrollWMCommand(rawValue: message.command).map { handler($0) }
                } ?? ScrollWMResponse(success: false, message: "No handler")
            }
            // Fall back to raw string for backward compatibility
            else if let command = ScrollWMCommand(rawValue: rawStr) {
                response = onCommand?(command) ?? ScrollWMResponse(success: false, message: "No handler")
            } else {
                response = ScrollWMResponse(success: false, message: "Unknown command: \(rawStr)")
            }
        } else {
            response = ScrollWMResponse(success: false, message: "Invalid data")
        }

        // Send response
        if let responseData = try? JSONEncoder().encode(response) {
            let responseStr = String(data: responseData, encoding: .utf8)! + "\n"
            responseStr.withCString { ptr in
                _ = write(clientFD, ptr, strlen(ptr))
            }
        }

        close(clientFD)
    }
}
