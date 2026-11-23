import Foundation
import XPC
import PluginEngine

// The macOS plugin host: an XPC service with its own sandbox and no entitlements beyond it (no
// network, no files outside its own container), so plugin JavaScript here can reach nothing but
// the app. Info.plist asks launchd for one instance per connection: each plugin's connection gets a
// process of its own, which the app kills when that plugin overruns a deadline.
//
// The app sends one message carrying one end of a socket pair; everything after that is the
// plugin host protocol on that socket (PluginHostChannel), as for the Linux child process.

xpc_main { connection in
    xpc_connection_set_event_handler(connection) { event in
        if xpc_get_type(event) == XPC_TYPE_ERROR { exit(0) }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
        let fd = xpc_dictionary_dup_fd(event, "channel")
        guard fd >= 0 else { return }
        let thread = Thread {
            PluginHostServer(channel: PluginHostChannel(readFD: fd, writeFD: fd), engine: JSEngines.makeInProcess()).run()
            exit(0)
        }
        thread.stackSize = 8 << 20
        thread.start()
    }
    xpc_connection_resume(connection)
}
