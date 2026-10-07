import Darwin
import Foundation
import IPC

private final class TransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Data?

    func store(_ data: Data) { lock.lock(); result = data; lock.unlock() }
    func load() -> Data? { lock.lock(); defer { lock.unlock() }; return result }
}

private func sendTestRequest(path: String, payload: Data) -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return Data() }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard var address = makeUnixSockaddr(path: path) else { return Data() }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return Data() }
    let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    guard sent == payload.count else { return Data() }
    shutdown(fd, SHUT_WR)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

@MainActor
func runIPCTransportTests() {
    section("R7: async IPC preserves app-scoped request parameters without blocking main")
    let path = "/tmp/reel-ipc-test-\(UUID().uuidString).sock"
    let server = SocketServer(socketPath: path)
    server.onAsyncMessage = { message, reply in
        DispatchQueue.main.async {
            reply(ReelResponse(success: Thread.isMainThread, message: message.command, data: message.appID))
        }
    }
    guard server.start() else { check(false, "temporary socket starts"); return }
    defer { server.stop() }
    let result = TransportResult()
    let payload = try! JSONEncoder().encode(IPCMessage(command: "clear-positions-app", appID: "test.bundle"))
    DispatchQueue.global().async { result.store(sendTestRequest(path: path, payload: payload)) }
    let end = Date(timeIntervalSinceNow: 3)
    while result.load() == nil && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    let response = result.load().flatMap { try? JSONDecoder().decode(ReelResponse.self, from: $0) }
    check(response?.success == true && response?.message == "clear-positions-app", "command completes asynchronously on main")
    check(response?.data == "test.bundle", "app ID survives real socket transport")
}
