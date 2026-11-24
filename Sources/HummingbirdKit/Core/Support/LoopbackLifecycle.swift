import Foundation
import os
import NIOCore
import NIOPosix
import Synchronization
import SwiftOpenUI

/// Something a suspension can take from the app: iOS closes a suspended app's
/// listening sockets and their connections and fails its in-flight URL tasks.
/// Every loopback listener and the downloads register with
/// `LoopbackLifecycle`, which resumes them all when the app comes back.
protocol SuspendedResource: AnyObject, Sendable {
    /// After a suspension: works again. A listener rebinds the port it had;
    /// it reports a move only when that port could not be had back.
    func resumeAfterSuspension() async -> PortMove?
    /// Takes what iOS takes from a suspended app: the listening socket, every
    /// accepted connection, in-flight URL tasks (debug builds, to reproduce it).
    func reclaimAsSuspensionWould() async
}

/// A loopback listener that had to change port.
struct PortMove: Sendable, Equatable {
    let from: Int
    let to: Int
}

/// The one owner of everything a suspension can take. Listeners register as
/// they bind (`register`), so a new one cannot be left out of resuming.
/// When the app becomes active it resumes them all, once, however many
/// players ask; `resume()` waits for that and returns every port that moved
/// since the app last left the foreground.
final class LoopbackLifecycle: Sendable {
    static let shared = LoopbackLifecycle()

    private struct Registration { weak var resource: (any SuspendedResource)? }
    private struct State {
        var resources: [Registration] = []
        var resuming: Task<[PortMove], Never>?
        var moves: [PortMove] = []
        var wasInactive = false
    }
    private let state = Mutex(State())

    private init() {
        ApplicationActivity.observe { [self] active in
            if active {
                // Back in front: every resource is resumed now, before any player
                // resumes playback (players await the same resume).
                let wasInactive = state.withLock { state in
                    defer { state.wasInactive = false }
                    return state.wasInactive
                }
                if wasInactive { Task { _ = await self.resume() } }
            } else {
                state.withLock { $0.wasInactive = true; $0.moves = [] }
                #if DEBUG
                if ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_RECLAIM_ON_SUSPEND"] == "1" {
                    Task { await self.reclaimAsSuspensionWould() }
                }
                #endif
            }
        }
    }

    /// Adds `resource` to what is resumed after a suspension.
    func register(_ resource: any SuspendedResource) {
        state.withLock { state in
            state.resources.removeAll { $0.resource == nil }
            state.resources.append(Registration(resource: resource))
        }
    }

    var registeredCount: Int { state.withLock { $0.resources.filter { $0.resource != nil }.count } }

    /// Resumes every registered resource (joining a resume already under way)
    /// and returns the port moves since the app last left the foreground.
    func resume() async -> [PortMove] {
        let task: Task<[PortMove], Never> = state.withLock { state in
            if let resuming = state.resuming { return resuming }
            let resources = state.resources.compactMap(\.resource)
            let task = Task<[PortMove], Never> {
                await withTaskGroup(of: PortMove?.self) { group in
                    for resource in resources { group.addTask { await resource.resumeAfterSuspension() } }
                    var moves: [PortMove] = []
                    for await move in group { if let move { moves.append(move) } }
                    return moves
                }
            }
            state.resuming = task
            return task
        }
        let moves = await task.value
        return state.withLock { state in
            if state.resuming == task {
                state.resuming = nil
                state.moves += moves
            }
            return state.moves
        }
    }

    /// Whether a loopback connection to `port` is accepted within a second: a
    /// suspended app's socket can be dead while NIO still thinks it is open.
    static func accepts(port: Int) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(1))
                .connect(host: "127.0.0.1", port: port).get()
            try? await channel.close()
            return true
        } catch {
            return false
        }
    }

    /// What iOS does to a suspended app, applied to every registered resource.
    func reclaimAsSuspensionWould() async {
        let resources = state.withLock { $0.resources.compactMap(\.resource) }
        Logger.player.notice("suspension_reclaim resources=\(resources.count)")
        for resource in resources { await resource.reclaimAsSuspensionWould() }
    }
}

/// A listener's accepted connections, so a suspension (and its simulation)
/// can close them. A class, so a channel initializer can capture it.
final class OpenConnections: Sendable {
    private let channels = Mutex<[ObjectIdentifier: any Channel]>([:])

    /// Tracks `channel` until it closes.
    func add(_ channel: any Channel) {
        let key = ObjectIdentifier(channel)
        channels.withLock { $0[key] = channel }
        channel.closeFuture.whenComplete { [self] _ in channels.withLock { $0[key] = nil } }
    }

    /// Every open connection, forgotten here (the caller closes them).
    func takeAll() -> [any Channel] {
        channels.withLock { open in defer { open = [:] }; return Array(open.values) }
    }
}
