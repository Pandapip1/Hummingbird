import Foundation

/// Small JSON-file persistence in Application Support. Writes are atomic so a crash never leaves a half-written file.
public enum Storage {
    public static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Jaybird", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        let url = directory.appendingPathComponent(name + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }
}
