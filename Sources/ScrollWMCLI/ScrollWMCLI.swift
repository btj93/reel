import Foundation
import IPC

@main
struct ScrollWMCLI {
    static func main() {
        let args = CommandLine.arguments.dropFirst()

        guard let commandStr = args.first,
              let command = ScrollWMCommand(rawValue: commandStr) else {
            print("Usage: scrollwm-msg <command>")
            print("Commands: \(ScrollWMCommand.allCases.map(\.rawValue).joined(separator: ", "))")
            Foundation.exit(1)
        }

        let socketPath = scrollWMSocketPath()

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
            print("Error: ScrollWM is not running (cannot connect to \(socketPath))")
            close(fd)
            Foundation.exit(1)
        }

        // Send command
        let cmdStr = command.rawValue + "\n"
        cmdStr.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        close(fd)

        if bytesRead > 0 {
            let responseData = Data(buffer[0..<bytesRead])
            if let response = try? JSONDecoder().decode(ScrollWMResponse.self, from: responseData) {
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
