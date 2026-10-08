#if os(Linux)
import Foundation
import XCTest

/// A test-owned X server for every GTK test. GTK chooses its display backend at
/// `gtk_init()` time, so this must run before a test calls that function rather
/// than relying on the developer's Wayland/X11 session or an `xvfb-run` wrapper.
enum TestDisplaySession {
    private static let lock = NSLock()
    private static var display: Process?

    static func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard display == nil else { return }

        for number in 91...190 {
            let socket = "/tmp/.X11-unix/X\(number)"
            guard !FileManager.default.fileExists(atPath: socket) else { continue }
            let xvfb = Process()
            xvfb.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            xvfb.arguments = ["Xvfb", ":\(number)", "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-terminate"]
            xvfb.standardOutput = FileHandle.nullDevice
            xvfb.standardError = FileHandle.nullDevice
            try xvfb.run()
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: socket) {
                    setenv("DISPLAY", ":\(number)", 1)
                    setenv("GDK_BACKEND", "x11", 1)
                    setenv("XDG_SESSION_TYPE", "x11", 1)
                    unsetenv("WAYLAND_DISPLAY")
                    unsetenv("WAYLAND_SOCKET")
                    display = xvfb
                    return
                }
                guard xvfb.isRunning else { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            ProcessTermination.terminateAndWait(xvfb)
        }
        throw XCTSkip("could not start a private Xvfb display for GTK tests")
    }
}
#else
enum TestDisplaySession {
    static func start() throws {}
}
#endif
