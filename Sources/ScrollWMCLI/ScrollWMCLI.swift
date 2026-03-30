import Foundation
import IPC

@main
struct ScrollWMCLI {
    static func main() {
        let args = CommandLine.arguments.dropFirst()

        guard let commandStr = args.first,
              let command = ScrollWMCommand(rawValue: commandStr) else {
            print("Usage: scrollwm <command>")
            print("Commands: \(ScrollWMCommand.allCases.map(\.rawValue).joined(separator: ", "))")
            Foundation.exit(1)
        }

        let socketPath = scrollWMSocketPath()
        print("Would send '\(command.rawValue)' to \(socketPath)")
        print("(IPC not yet implemented)")
    }
}
