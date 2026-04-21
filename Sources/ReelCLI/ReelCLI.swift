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

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
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

        // Send command
        let cmdStr = payload + "\n"
        cmdStr.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
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

        if !responseData.isEmpty {
            if let response = try? JSONDecoder().decode(ReelResponse.self, from: responseData) {
                if let data = response.data {
                    print(data)
                } else if let message = response.message {
                    print(message)
                } else {
                    print(response.success ? "OK" : "Failed")
                }
            } else if let str = String(data: responseData, encoding: .utf8) {
                print(str)
            }
        }
    }
}
