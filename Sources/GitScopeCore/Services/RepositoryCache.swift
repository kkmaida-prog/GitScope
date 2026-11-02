import Foundation
import SQLite3

/// A versioned, disposable SQLite cache. Each row is an atomically published snapshot.
/// Open a connection per operation; connections never cross task boundaries.
public struct RepositoryCache: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitScope", isDirectory: true).appendingPathComponent("history-v2.sqlite")
    }
    private func connection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw GitError.failed("Cannot open the local analysis cache.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3000)
        try execute("CREATE TABLE IF NOT EXISTS snapshots (repository TEXT NOT NULL, reference TEXT NOT NULL, version INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(repository, reference))", on: database)
        return try body(database)
    }
    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw GitError.failed("Local cache transaction failed: \(String(cString: sqlite3_errmsg(database)))") }
    }
    private func bind(_ text: String, to index: Int32, in statement: OpaquePointer) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    public func read(root: URL, reference: String) throws -> RepositorySnapshot? {
        try connection { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT payload FROM snapshots WHERE repository=? AND reference=? AND version=2", -1, &statement, nil) == SQLITE_OK, let statement else { throw GitError.failed("Cannot read the local cache.") }
            defer { sqlite3_finalize(statement) }
            bind(root.standardizedFileURL.path, to: 1, in: statement); bind(reference, to: 2, in: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw GitError.failed("Invalid local cache row.") }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let snapshot = try JSONDecoder().decode(RepositorySnapshot.self, from: data)
            guard snapshot.root.standardizedFileURL == root.standardizedFileURL, snapshot.reference == reference else { return nil }
            return snapshot
        }
    }
    public func write(_ snapshot: RepositorySnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        try connection { database in
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO snapshots(repository, reference, version, payload) VALUES(?,?,2,?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw GitError.failed("Cannot prepare the local cache.") }
                defer { sqlite3_finalize(statement) }
                bind(snapshot.root.standardizedFileURL.path, to: 1, in: statement); bind(snapshot.reference, to: 2, in: statement)
                let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw GitError.failed("Cannot save the local cache.") }
                try Task.checkCancellation()
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }
}
