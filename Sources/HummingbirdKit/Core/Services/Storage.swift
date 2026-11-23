import CSQLite
import Foundation
import PlatformSupport

/// App persistence backed by one SQLite database (`storage.sqlite3`) in a
/// data directory. Existing JSON stores are imported lazily, so upgrades
/// retain user data without a separate migration.
///
/// Writes are encoded and committed in submission order on a background
/// queue, so the main actor never waits for JSON or SQLite.
final class Storage: Sendable {
    private let backend: StorageBackend
    private let writer = DispatchQueue(label: "app.hummingbird.storage", qos: .utility)

    init(directory: URL) {
        backend = StorageBackend(directory: directory)
    }

    private init(backend: StorageBackend) {
        self.backend = backend
    }

    /// A private in-memory database with no files at all, for tests.
    static func inMemory() -> Storage {
        Storage(backend: StorageBackend(directory: nil))
    }

    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        backend.load(type, name: name)
    }

    func save<T: Encodable & Sendable>(_ value: T, name: String) {
        writer.async { [backend] in backend.save(value, name: name) }
    }

    /// Deletes `name` (a store whose data moved elsewhere), in order with the writes.
    func remove(name: String) {
        writer.async { [backend] in backend.remove(name: name) }
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

    init(directory: URL?) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = StorageDatabase(url: directory.appendingPathComponent("storage.sqlite3"))
        } else {
            database = StorageDatabase(path: ":memory:")
        }
    }

    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
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
        let legacyURL = directory.appendingPathComponent(name + ".json")
        if database.save(data, name: name) {
            do { try FileManager.default.removeItem(at: legacyURL) }
            catch where (error as NSError).code == NSFileNoSuchFileError { }
            catch { saveLegacy(data, to: legacyURL) }
        } else {
            saveLegacy(data, to: legacyURL)
        }
    }

    func remove(name: String) {
        lock.lock()
        defer { lock.unlock() }
        database.remove(name: name)
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json")) }
    }

    private func saveLegacy(_ data: Data, to url: URL) {
        try? FileProtection.writeProtected(data, to: url)
    }
}

/// Synchronized key/value database. Values remain JSON blobs so persisted model
/// compatibility stays independent of the SQL schema.
final class StorageDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    convenience init(url: URL) {
        self.init(path: url.path)
        FileProtection.protectExistingFiles(atPaths: [url.path, url.path + "-wal", url.path + "-shm"])
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

extension StorageDatabase {
    func remove(name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM storage WHERE name = ?1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return }
        _ = sqlite3_step(statement)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
