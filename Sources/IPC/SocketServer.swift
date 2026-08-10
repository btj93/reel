import Foundation

/// Unix domain socket server for IPC.
/// Listens for JSON-encoded commands on the path from `reelSocketPath()`
/// (per-user temp dir by default; `REEL_SOCKET_PATH` override for tests).
public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    /// Per-connection read/write runs here, off the main thread, so a slow or
    /// stalled client can never freeze the window manager (and, with it, the
    /// CGEventTaps serviced by the main run loop). Concurrent so one slow
    /// connection does not head-of-line-block the next. Command execution still
    /// hops to `.main` (WindowManager is main-thread-only).
    private let connectionQueue = DispatchQueue(
        label: "co.reel.ipc.connection", qos: .userInitiated, attributes: .concurrent)

    /// Per-connection budget (seconds) applied to both SO_RCVTIMEO/SO_SNDTIMEO
    /// and as a wall-clock cap on the read loop, so a drip-feeding client that
    /// resets the socket timeout on every byte still cannot hold a worker past
    /// this deadline.
    private static let connectionTimeoutSeconds = 2

    /// Called when a command is received. Returns a response.
    public var onCommand: ((ReelCommand) -> ReelResponse)?

    public var onMessage: ((IPCMessage) -> ReelResponse)?

    /// Invoked after a command's response has been fully written and the client
    /// socket closed. For actions that must not race the reply — `quit` above all,
    /// since terminating from inside the command handler can kill the process with
    /// the response still unsent. Runs on `connectionQueue`, so hop to main if the
    /// action touches main-thread state.
    public var onFlushed: ((ReelCommand) -> Void)?

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
            print("[IPC] Failed to create socket")
            fflush(stdout)
            return false
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= sunPathCapacity else {
            print("[IPC] Socket path too long (\(pathBytes.count) > \(sunPathCapacity)): \(socketPath)")
            fflush(stdout)
            close(listenerFD)
            listenerFD = -1
            return false
        }
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
            fflush(stdout)
            close(listenerFD)
            // Reset so a later stop() cannot close this number again — by then the
            // descriptor has been recycled by some unrelated open (log handle, AXApp
            // kqueue, WindowServer connection), and closing it would yank that away.
            listenerFD = -1
            return false
        }

        // Restrict socket to owner only
        chmod(socketPath, 0o600)

        // Listen
        guard listen(listenerFD, 5) == 0 else {
            print("[IPC] Failed to listen")
            fflush(stdout)
            close(listenerFD)
            listenerFD = -1
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

    /// Maximum message size to prevent DoS (64KB).
    private static let maxMessageSize = 65536

    /// Runs on `.main` (the accept source's queue). Accepts the connection,
    /// verifies the peer is the same user, then hands the socket to a
    /// background worker — accept() itself is instant, but the read/write loop
    /// must never run on main.
    private func acceptConnection() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Peer-uid check (defense-in-depth). File permissions (0700 parent dir,
        // 0600 socket) already gate this, but reject any connection whose peer
        // is not the current user before doing any work on it.
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
            print("[IPC] Rejected connection from foreign uid \(euid)")
            fflush(stdout)
            close(clientFD)
            return
        }

        connectionQueue.async { [weak self] in
            self?.handleConnection(clientFD)
        }
    }

    /// Runs on `connectionQueue` (background). Reads the request, executes the
    /// command (hopping to `.main`), and writes the response — all off main.
    private func handleConnection(_ clientFD: Int32) {
        // Post-flush action, run after the response is written AND the socket is
        // closed. `quit` used to call NSApp.terminate from inside the command
        // handler, but the write happens after that handler returns, so the process
        // could die with the reply unsent — which is why the CLI had to treat an
        // empty response as success. Registered BEFORE the close defer so LIFO
        // ordering runs it last.
        var flushedCommand: ReelCommand?
        defer { if let flushedCommand { onFlushed?(flushedCommand) } }
        defer { close(clientFD) }

        // Bound both directions in time. SO_RCVTIMEO caps an idle read; the
        // wall-clock deadline below caps total read time so drip-feeding cannot
        // extend the budget. SO_SNDTIMEO caps a write into a full socket buffer
        // (a client that requests a large payload then stops reading).
        var tv = timeval(tv_sec: Self.connectionTimeoutSeconds, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // SO_NOSIGPIPE: a write to a peer that has already closed returns EPIPE
        // instead of raising SIGPIPE, which would otherwise kill the whole
        // window manager, bypassing graceful shutdown.
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Read command — loop until EOF, cap at maxMessageSize and at the
        // wall-clock deadline.
        let deadline = Date().addingTimeInterval(Double(Self.connectionTimeoutSeconds))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < Self.maxMessageSize {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
            if Date() >= deadline { break }
        }

        guard !data.isEmpty else { return }

        let (response, command) = computeResponse(from: data)
        flushedCommand = command

        // Send response — loop write until all bytes are flushed (a single
        // write() may return short, especially for large JSON payloads).
        guard let responseData = try? JSONEncoder().encode(response),
              let responseStr = String(data: responseData, encoding: .utf8) else { return }
        (responseStr + "\n").withCString { base in
            let total = strlen(base)
            var offset = 0
            while offset < total {
                let n = write(clientFD, base.advanced(by: offset), total - offset)
                if n < 0 {
                    let err = errno
                    // EPIPE = peer gone (normal disconnect), EAGAIN/EWOULDBLOCK
                    // = SO_SNDTIMEO fired on a non-reading client. Neither is
                    // worth logging as an error.
                    if err != EPIPE && err != EAGAIN && err != EWOULDBLOCK {
                        print("[IPC] Write failed: \(String(cString: strerror(err)))")
                        fflush(stdout)
                    }
                    break
                }
                if n == 0 { break }
                offset += n
            }
        }
    }

    /// Decode the request (pure, safe off-main) and invoke the command handler
    /// on `.main` — WindowManager is main-thread-only.
    /// Returns the response plus the resolved command, so `handleConnection` can
    /// run post-flush actions (see `onFlushed`) without the command handlers having
    /// to thread a closure back out.
    private func computeResponse(from data: Data) -> (ReelResponse, ReelCommand?) {
        guard let rawStr = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (ReelResponse(success: false, message: "Invalid data"), nil)
        }

        // Try JSON protocol first
        if let jsonData = rawStr.data(using: .utf8),
           let message = try? JSONDecoder().decode(IPCMessage.self, from: jsonData) {
            let resolved = ReelCommand(rawValue: message.command)
            let response = executeOnMain {
                self.onMessage?(message) ?? self.onCommand.flatMap { handler in
                    resolved.map { handler($0) }
                } ?? ReelResponse(success: false, message: "No handler")
            }
            return (response, resolved)
        }
        // Fall back to raw string for backward compatibility
        if let command = ReelCommand(rawValue: rawStr) {
            let response = executeOnMain {
                self.onCommand?(command) ?? ReelResponse(success: false, message: "No handler")
            }
            return (response, command)
        }
        return (ReelResponse(success: false, message: "Unknown command: \(rawStr)"), nil)
    }

    /// Synchronously run `work` on the main thread and return its result.
    private func executeOnMain(_ work: () -> ReelResponse) -> ReelResponse {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
