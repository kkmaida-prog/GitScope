import Foundation
import SQLite3

/// A versioned, disposable SQLite cache. Payload version 3 adds manifest history; older rows are ignored and replaced.
/// Each row is an atomically published snapshot.
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
        // Separate versioned results in the existing history-v2.sqlite database.
        // No migration of the snapshot table or existing cache contents is required.
        try execute("CREATE TABLE IF NOT EXISTS code_quality_results (repository TEXT NOT NULL, reference TEXT NOT NULL, head TEXT NOT NULL, configuration TEXT NOT NULL, version INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(repository, reference, head, configuration, version))", on: database)
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
            guard sqlite3_prepare_v2(database, "SELECT payload FROM snapshots WHERE repository=? AND reference=? AND version=3", -1, &statement, nil) == SQLITE_OK, let statement else { throw GitError.failed("Cannot read the local cache.") }
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
                guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO snapshots(repository, reference, version, payload) VALUES(?,?,3,?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw GitError.failed("Cannot prepare the local cache.") }
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
    /// A stale algorithm version or different configuration is a miss, never a valid hit.
    /// A damaged JSON payload throws; the caller may safely recompute and replace it.
    public func readCodeQuality(root: URL, reference: String, head: String,
                                configuration: String, version: Int) throws -> CodeQualityReport? {
        try connection { database in
            var statement: OpaquePointer?
            let query = "SELECT payload FROM code_quality_results WHERE repository=? AND reference=? AND head=? AND configuration=? AND version=?"
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw GitError.failed("Cannot read code quality cache.") }
            defer { sqlite3_finalize(statement) }
            bind(root.standardizedFileURL.path, to: 1, in: statement)
            bind(reference, to: 2, in: statement)
            bind(head, to: 3, in: statement)
            bind(configuration, to: 4, in: statement)
            guard sqlite3_bind_int(statement, 5, Int32(version)) == SQLITE_OK else {
                throw GitError.failed("Cannot bind code quality cache version.")
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw GitError.failed("Cannot read code quality cache row.") }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0), count > 0 else {
                throw GitError.failed("Empty code quality cache payload.")
            }
            return try JSONDecoder().decode(CodeQualityReport.self, from: Data(bytes: bytes, count: count))
        }
    }

    /// Atomically publish one complete report. Do not cache cancelled/partial work.
    public func writeCodeQuality(_ report: CodeQualityReport, root: URL, reference: String,
                                 head: String, configuration: String, version: Int) throws {
        let payload = try JSONEncoder().encode(report)
        try Task.checkCancellation()
        try connection { database in
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                var statement: OpaquePointer?
                let query = "INSERT OR REPLACE INTO code_quality_results (repository, reference, head, configuration, version, payload) VALUES (?,?,?,?,?,?)"
                guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw GitError.failed("Cannot prepare code quality cache write.") }
                defer { sqlite3_finalize(statement) }
                bind(root.standardizedFileURL.path, to: 1, in: statement)
                bind(reference, to: 2, in: statement)
                bind(head, to: 3, in: statement)
                bind(configuration, to: 4, in: statement)
                let versionStatus = sqlite3_bind_int(statement, 5, Int32(version))
                let blobStatus = payload.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard versionStatus == SQLITE_OK, blobStatus == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw GitError.failed("Cannot save code quality cache payload.")
                }
                // Keep filter variants for this revision, but prune entries for a
                // superseded HEAD on the same branch to bound cache growth.
                var stale: OpaquePointer?
                let cleanup = "DELETE FROM code_quality_results WHERE repository=? AND reference=? AND head<>?"
                guard sqlite3_prepare_v2(database, cleanup, -1, &stale, nil) == SQLITE_OK,
                      let stale else { throw GitError.failed("Cannot prune obsolete quality cache rows.") }
                defer { sqlite3_finalize(stale) }
                bind(root.standardizedFileURL.path, to: 1, in: stale)
                bind(reference, to: 2, in: stale)
                bind(head, to: 3, in: stale)
                guard sqlite3_step(stale) == SQLITE_DONE else {
                    throw GitError.failed("Cannot prune obsolete quality cache rows.")
                }
                try Task.checkCancellation()
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

}


/// Only the history extraction was cached before v7. This service caches the
/// deterministic Code Quality report separately in the SAME SQLite database.
public enum CodeQualityCacheStatus: String, Sendable {
    case hit = "Cache hit"
    case stored = "Computed and cached"
    case unavailable = "Computed (cache unavailable)"
}

public struct CodeQualityCachedResult: Sendable {
    public let report: CodeQualityReport
    public let status: CodeQualityCacheStatus
}

public struct CodeQualityCacheService: Sendable {
    public let cache: RepositoryCache
    /// Bump after any change in scan algorithm or report interpretation.
    public static let algorithmVersion = 7

    public init(cacheURL: URL) { self.cache = RepositoryCache(url: cacheURL) }

    private struct CacheConfiguration: Encodable {
        let options: AnalysisOptions
        let minimumLines: Int
        let minimumFileCommits: Int
        let shallow: Bool
        let historyFingerprint: String
    }

    /// Git commit SHAs are immutable. Include the history fingerprint as well,
    /// because shallow history may deepen without changing the HEAD SHA.
    private func fingerprint(_ commits: [Commit]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for id in commits.map(\.id).sorted() {
            for byte in id.utf8 {
                value = (value ^ UInt64(byte)) &* 1_099_511_628_211
            }
            value = (value ^ 0xff) &* 1_099_511_628_211
        }
        return String(value, radix: 16) + ":\(commits.count)"
    }

    public func loadOrCompute(snapshot: RepositorySnapshot, metrics: RepositoryMetrics,
                              options: AnalysisOptions = AnalysisOptions(),
                              minimumLines: Int = 10, minimumFileCommits: Int = 2) -> CodeQualityCachedResult {
        let configuration = CacheConfiguration(options: options, minimumLines: minimumLines,
                                               minimumFileCommits: minimumFileCommits,
                                               shallow: snapshot.shallow,
                                               historyFingerprint: fingerprint(snapshot.commits))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(configuration) else {
            let report = CodeQualityAnalyzer().analyze(snapshot: snapshot, metrics: metrics,
                                                        options: options, minimumLines: minimumLines,
                                                        minimumFileCommits: minimumFileCommits)
            return CodeQualityCachedResult(report: report, status: .unavailable)
        }
        let configKey = encoded.base64EncodedString()
        if !Task.isCancelled,
           let cached = try? cache.readCodeQuality(root: snapshot.root, reference: snapshot.reference,
                                                   head: snapshot.head, configuration: configKey,
                                                   version: Self.algorithmVersion) {
            return CodeQualityCachedResult(report: cached, status: .hit)
        }
        let report = CodeQualityAnalyzer().analyze(snapshot: snapshot, metrics: metrics,
                                                    options: options, minimumLines: minimumLines,
                                                    minimumFileCommits: minimumFileCommits)
        // A cancellation/limit cannot publish a partial duplicate result as a complete cache hit.
        guard !Task.isCancelled, !report.truncated else {
            return CodeQualityCachedResult(report: report, status: .unavailable)
        }
        do {
            try cache.writeCodeQuality(report, root: snapshot.root, reference: snapshot.reference,
                                       head: snapshot.head, configuration: configKey,
                                       version: Self.algorithmVersion)
            return CodeQualityCachedResult(report: report, status: .stored)
        } catch {
            return CodeQualityCachedResult(report: report, status: .unavailable)
        }
    }
}
