import Foundation
import PluginEngine

// The plugin host process for tests and development builds (the app itself uses its XPC service on
// macOS and re-runs its own binary with --plugin-host on Linux): JavaScript contexts and nothing
// else, spoken to over stdin/stdout, killed by the app when a plugin overruns a deadline.

guard CommandLine.arguments.dropFirst().first == "--plugin-host" else {
    FileHandle.standardError.write(Data("hummingbird-plugin-host is started by Hummingbird.\n".utf8))
    exit(64)
}
PluginHostServer.runAsProcess()
