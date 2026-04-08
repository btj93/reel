import Foundation

/// Unix domain socket server for IPC.
/// Listens on /tmp/reel_{uid}.sock for JSON-encoded commands.
public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    private static let jsonDecoder = JSONDecoder()
    private static let jsonEncoder = JSONEncoder()

    /// Called when a command is received. Returns a response.
    public var onCommand: ((ReelCommand) -> ReelResponse)?

    public var onMessage: ((IPCMessage) -> ReelResponse)?

    public init() {
        self.socketPath = reelSocketPath()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() -> Bool {
        // Remove stale socket
        unlink(socketPath)

        // Create socket
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            #if DEBUG
            print("[IPC] Failed to create socket")
            fflush(stdout)
            #endif
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
            #if DEBUG
            print("[IPC] Failed to bind to \(socketPath): \(String(cString: strerror(errno)))")
            fflush(stdout)
            #endif
            close(listenerFD)
            return false
        }

        // Restrict socket to owner only
        chmod(socketPath, 0o600)

        // Listen
        guard listen(listenerFD, 5) == 0 else {
            #if DEBUG
            print("[IPC] Failed to listen")
            fflush(stdout)
            #endif
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

        #if DEBUG
        print("[IPC] Listening on \(socketPath)")
        fflush(stdout)
        #endif
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

    /// Maximum message size to prevent DoS (64KB).
    private static let maxMessageSize = 65536

    private func acceptConnection() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Set read timeout to prevent hung clients
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read command — loop until EOF, cap at maxMessageSize
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Self.maxMessageSize {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
        }

        guard !data.isEmpty else {
            close(clientFD)
            return
        }

        // Parse command
        let response: ReelResponse
        if let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Try JSON protocol first
            if let jsonData = rawStr.data(using: .utf8),
               let message = try? Self.jsonDecoder.decode(IPCMessage.self, from: jsonData) {
                response = onMessage?(message) ?? onCommand.flatMap { handler in
                    ReelCommand(rawValue: message.command).map { handler($0) }
                } ?? ReelResponse(success: false, message: "No handler")
            }
            // Fall back to raw string for backward compatibility
            else if let command = ReelCommand(rawValue: rawStr) {
                response = onCommand?(command) ?? ReelResponse(success: false, message: "No handler")
            } else {
                response = ReelResponse(success: false, message: "Unknown command: \(rawStr)")
            }
        } else {
            response = ReelResponse(success: false, message: "Invalid data")
        }

        // Send response
        if let responseData = try? Self.jsonEncoder.encode(response) {
            let responseStr = String(data: responseData, encoding: .utf8)! + "\n"
            responseStr.withCString { ptr in
                let len = strlen(ptr)
                let written = write(clientFD, ptr, len)
                #if DEBUG
                if written < 0 {
                    print("[IPC] Write failed: \(String(cString: strerror(errno)))")
                    fflush(stdout)
                }
                #endif
            }
        }

        close(clientFD)
    }
}
