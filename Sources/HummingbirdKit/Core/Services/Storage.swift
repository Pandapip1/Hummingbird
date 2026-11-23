import ATAppSync
import CSQLite
import Foundation
import os

/// App persistence backed by one SQLite database (`storage.sqlite3`) in a
/// data directory. Existing JSON stores are imported lazily, so upgrades
/// retain user data without a separate migration.
///
/// Writes are encoded and committed in submission order on a background
/// queue, so the main actor never waits for JSON or SQLite.
///
/// The database and legacy files are protected `complete`: unreadable while
/// the device is locked. A write that can't reach them then (or that fails)
/// goes to ATAppSync's `PendingWriteQueue` (`pending-writes.queue`, kept open,
/// `completeUnlessOpen`), never nowhere; reads see queued values first; the
/// queue is applied, in order and once, at launch and when protected data
/// becomes available again.
final class Storage: Sendable {
    private let backend: StorageBackend
    private let writer = DispatchQueue(label: "app.hummingbird.storage", qos: .utility)
    /// Writes waiting for protected data; also where crash-safe progress is
    /// kept (`ProgressRecovery`). Nil for an in-memory database.
    let pendingWrites: PendingWriteQueue?

    init(directory: URL, protectedData: any ProtectedDataAvailability) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = PendingWriteQueue(fileURL: directory.appendingPathComponent("pending-writes.queue"),
                                      availability: protectedData)
        pendingWrites = queue
        backend = StorageBackend(directory: directory, queue: queue, protectedData: protectedData)
        // Whatever a locked device or a killed process left queued lands now,
        // and again whenever the device unlocks.
        let backend = backend
        let writer = writer
        writer.async { backend.applyPendingWrites() }
        protectedData.observeProtectedDataAvailability { available in
            guard available else { return }
            writer.async { backend.applyPendingWrites() }
        }
    }

    private init(backend: StorageBackend) {
        self.backend = backend
        pendingWrites = nil
    }

    /// A private in-memory database with no files at all, for tests.
    static func inMemory() -> Storage {
        Storage(backend: StorageBackend(directory: nil, queue: nil, protectedData: UnprotectedDataAvailability()))
    }

    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        backend.load(type, name: name)
    }

    func save<T: Encodable & Sendable>(_ value: T, name: String) {
        writer.async { [backend] in backend.save(value, name: name) }
    }

    /// Applies queued writes now, if protected data is available.
    func applyPendingWrites() async {
        await withCheckedContinuation { continuation in
            writer.async { [backend] in
                backend.applyPendingWrites()
                continuation.resume()
            }
        }
    }

    /// Waits for every write submitted so far.
    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }

    /// Waits for every write submitted so far, but never past `deadline`: only
    /// for the moment the application exits. True if everything was written.
    @discardableResult
    func flushBeforeTermination(until deadline: ExitDeadline) -> Bool { deadline.drain(writer) }
}

/// Serializes migration and ordinary reads/writes as one operation. A legacy
/// file is authoritative while present: it either predates first import or is
/// the durable fallback from a failed SQLite write.
final class StorageBackend: @unchecked Sendable {
    private let lock = NSLock()
    /// Nil for an in-memory database, which has no legacy files.
    private let directory: URL?
    private let database: StorageDatabase
    private let queue: PendingWriteQueue?
    private let protectedData: any ProtectedDataAvailability
    private static let queuePrefix = "storage/"

    init(directory: URL?, queue: PendingWriteQueue?, protectedData: any ProtectedDataAvailability) {
        self.directory = directory
        self.queue = queue
        self.protectedData = protectedData
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = StorageDatabase(url: directory.appendingPathComponent("storage.sqlite3"),
                                       protectedData: protectedData)
        } else {
            database = StorageDatabase(path: ":memory:")
        }
    }

    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        // A queued write is newer than anything stored, and is all there is
        // to read while the device is locked.
        if let queued = queue?.latest(key: Self.queuePrefix + name) {
            return try? JSONDecoder().decode(T.self, from: queued.payload)
        }
        guard let directory else {
            return database.load(name: name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        let legacyURL = directory.appendingPathComponent(name + ".json")
        if let data = try? Data(contentsOf: legacyURL),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            if database.save(data, name: name) { try? FileManager.default.removeItem(at: legacyURL) }
            return value
        }
        guard let data = database.load(name: name) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let directory else {
            database.save(data, name: name)
            return
        }
        // Locked: the database can't be opened for writing; queue instead.
        guard protectedData.isProtectedDataAvailable else {
            enqueue(data, name: name, reason: "protected_data_unavailable")
            return
        }
        let legacyURL = directory.appendingPathComponent(name + ".json")
        if database.save(data, name: name) {
            do { try FileManager.default.removeItem(at: legacyURL) }
            catch where (error as NSError).code == NSFileNoSuchFileError { }
            catch {
                if !saveLegacy(data, to: legacyURL) {
                    enqueue(data, name: name, reason: "legacy_cleanup_failed")
                    return
                }
            }
        } else if !saveLegacy(data, to: legacyURL) {
            enqueue(data, name: name, reason: "database_and_legacy_write_failed")
            return
        }
        // Stored: anything still queued for this name is older (it was
        // queued before this save), so it must neither shadow this value on
        // read nor overwrite it when the queue is applied.
        discardQueued(name: name)
    }

    private func discardQueued(name: String) {
        guard let queue, let queued = queue.latest(key: Self.queuePrefix + name) else { return }
        do { try queue.clear(key: Self.queuePrefix + name, through: queued.sequence) }
        catch {
            Logger.performance.error("storage_queue_clear_failed name=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Writes queued values into the database, oldest first; each leaves the
    /// queue once it is stored.
    func applyPendingWrites() {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }
        let landed = queue.apply(keyPrefix: Self.queuePrefix) { write in
            guard let payload = write.payload else { return true }
            return database.save(payload, name: String(write.key.dropFirst(Self.queuePrefix.count)))
        }
        if landed > 0 { Logger.performance.notice("storage_pending_applied count=\(landed)") }
    }

    private func enqueue(_ data: Data, name: String, reason: StaticString) {
        guard let queue else {
            Logger.performance.error("storage_write_lost name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
            return
        }
        do {
            try queue.append(key: Self.queuePrefix + name, payload: data)
            Logger.performance.notice("storage_write_queued name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
        } catch {
            Logger.performance.error("storage_write_lost name=\(name, privacy: .public) reason=\(String(describing: reason), privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func saveLegacy(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic])
            try protectedData.setProtection(.complete, for: url)
            return true
        } catch {
            return false
        }
    }
}

/// Synchronized key/value database. Values remain JSON blobs so persisted model
/// compatibility stays independent of the SQL schema.
final class StorageDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    /// Protected `complete`: unreadable while the device is locked.
    convenience init(url: URL, protectedData: any ProtectedDataAvailability) {
        self.init(path: url.path)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            do { try protectedData.setProtection(.complete, for: URL(fileURLWithPath: path)) }
            catch { Logger.performance.error("storage_protection_failed error=\(String(describing: error), privacy: .public)") }
        }
    }

    /// `":memory:"` opens a private in-memory database.
    init(path: String) {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK {
            handle = opened
            sqlite3_busy_timeout(opened, 2_000)
            if sqlite3_exec(opened, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK ||
               sqlite3_exec(opened, "CREATE TABLE IF NOT EXISTS storage (name TEXT PRIMARY KEY, payload BLOB NOT NULL, updated REAL NOT NULL)", nil, nil, nil) != SQLITE_OK {
                sqlite3_close(opened)
                handle = nil
            }
        } else if let opened {
            sqlite3_close(opened)
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func load(name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM storage WHERE name = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    @discardableResult
    func save(_ data: Data, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        var statement: OpaquePointer?
        let sql = "INSERT INTO storage(name, payload, updated) VALUES(?1, ?2, ?3) ON CONFLICT(name) DO UPDATE SET payload=excluded.payload, updated=excluded.updated"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
        let blobResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard blobResult == SQLITE_OK,
              sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
