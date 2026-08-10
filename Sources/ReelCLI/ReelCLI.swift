import Foundation
import IPC

@main
struct ReelCLI {
    static func printUsage() {
        let commands = ReelCommand.allCases.map(\.rawValue) + ["clear-positions-app <bundle-id>"]
        print("Usage: reel-msg <command>")
        print("Commands: \(commands.joined(separator: ", "))")
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let commandStr = args.first else {
            printUsage()
            Foundation.exit(1)
        }

        // Build the payload to send
        let payload: String
        if commandStr == "clear-positions-app" {
            guard args.count >= 2 else {
                print("Usage: reel-msg clear-positions-app <bundle-id>")
                Foundation.exit(1)
            }
            let message = IPCMessage(command: commandStr, appID: args[1])
            let data = try! JSONEncoder().encode(message)
            payload = String(data: data, encoding: .utf8)!
        } else {
            guard ReelCommand(rawValue: commandStr) != nil else {
                printUsage()
                Foundation.exit(1)
            }
            payload = commandStr
        }

        let socketPath = reelSocketPath()

        // Connect to the Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Error: cannot create socket")
            Foundation.exit(1)
        }

        // Never let a write to a server that closed the connection mid-response
        // raise SIGPIPE and kill reel-msg outright — surface it as a normal
        // write error instead (#28 hardening).
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size))

        // Bounds-checked. Copying an unchecked path into sun_path — a fixed
        // 104-byte array that is the struct's last member — corrupted the stack for
        // a long REEL_SOCKET_PATH or inherited TMPDIR. Shares the server's guard.
        guard var addr = makeUnixSockaddr(path: socketPath) else {
            FileHandle.standardError.write(
                Data("Error: socket path too long: \(socketPath)\n".utf8))
            close(fd)
            Foundation.exit(1)
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            print("Error: Reel is not running (cannot connect to \(socketPath))")
            close(fd)
            Foundation.exit(1)
        }

        // Send command — loop until every byte is out. A short positive write() is
        // partial delivery, not success: the server would then parse a truncated
        // command. Mirrors the server's own write loop; retries on EINTR.
        let sendOk = (payload + "\n").withCString { base -> Bool in
            let total = strlen(base)
            var offset = 0
            while offset < total {
                let n = write(fd, base.advanced(by: offset), total - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard sendOk else {
            FileHandle.standardError.write(Data("Error: failed to send command\n".utf8))
            close(fd)
            Foundation.exit(1)
        }
        // Signal EOF so the server's read loop terminates immediately,
        // while keeping the read side open for the response.
        shutdown(fd, SHUT_WR)

        // Read response — loop until EOF so large payloads (e.g. get-layout
        // with many columns) don't get truncated at 4KB.
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }
        close(fd)

        // Exit status must reflect the daemon's verdict. Previously always 0, so a
        // wrapper doing `reel-msg X || notify` treated "Unknown command" or
        // "Reorder in progress" as success and consumed the error text as data.
        // stdout shape is kept byte-identical so smoke-harness jq pipelines are
        // unaffected; diagnostics go to stderr.
        var decoded: ReelResponse?
        if !responseData.isEmpty {
            if let response = try? JSONDecoder().decode(ReelResponse.self, from: responseData) {
                decoded = response
                if let data = response.data {
                    print(data)
                } else if let message = response.message {
                    print(message)
                } else {
                    print(response.success ? "OK" : "Failed")
                }
            } else if let str = String(data: responseData, encoding: .utf8) {
                print(str)
                FileHandle.standardError.write(
                    Data("Error: undecodable response from Reel\n".utf8))
            }
        } else {
            FileHandle.standardError.write(
                Data("Error: no response from Reel (daemon may have exited)\n".utf8))
        }
        Foundation.exit(reelExitCode(for: decoded))
    }
}
