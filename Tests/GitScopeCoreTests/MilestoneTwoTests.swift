import XCTest
import SQLite3
@testable import GitScopeCore

final class MilestoneTwoTests: XCTestCase {
    private func change(_ path: String, _ added: Int = 1, _ deleted: Int = 0) -> FileChange { FileChange(path: path, additions: added, deletions: deleted) }
    private func commit(_ id: String, _ changes: [FileChange], email: String = "a@example.test", time: Double = 100) -> Commit {
        Commit(id: id, author: email.hasPrefix("a") ? "Ada" : "Bob", email: email, date: Date(timeIntervalSince1970: time), subject: id, changes: changes)
    }
    private func snapshot(_ commits: [Commit]) -> RepositorySnapshot {
        RepositorySnapshot(root: URL(fileURLWithPath: "/tmp/fixture"), head: "abc", shallow: false, commits: commits, fileSizes: ["src/a.swift": 10, "src/b.swift": 20, "vendor/x.c": 30])
    }
    func testSharedDatesAuthorPathsAndExclusions() {
        let raw = snapshot([
            commit("before", [change("src/a.swift")], time: 99),
            commit("included", [change("src/a.swift", 3), change("vendor/x.c", 10)], time: 100),
            commit("other author", [change("src/b.swift", 8)], email: "b@example.test", time: 110),
            commit("end boundary", [change("src/a.swift")], time: 200)
        ])
        var options = AnalysisOptions()
        options.since = Date(timeIntervalSince1970: 100); options.until = Date(timeIntervalSince1970: 200)
        options.authorQuery = "ADA"; options.excludedPatterns = ["vendor/*"]
        options.fileExtension = ".swift"; options.pathQuery = "src/"
        let metrics = AnalysisEngine().compute(raw, options: options)
        XCTAssertEqual(metrics.commits, 1); XCTAssertEqual(metrics.excludedCommits, 3)
        XCTAssertEqual(metrics.additions, 3); XCTAssertEqual(metrics.currentFileCount, 2)
        XCTAssertEqual(metrics.hotspots.map(\.path), ["src/a.swift"])
        XCTAssertEqual(metrics.contributors.first?.churn, 3)
        XCTAssertTrue(metrics.coupling.isEmpty)
    }
    func testBulkFilterRunsBeforePathFilter() {
        let raw = snapshot([commit("bulk", [change("src/a.swift"), change("vendor/x.c"), change("README")])])
        var options = AnalysisOptions(); options.maximumFilesPerCommit = 2; options.pathQuery = "src/"
        XCTAssertEqual(AnalysisEngine().compute(raw, options: options).commits, 0)
        options.maximumFilesPerCommit = 0
        XCTAssertEqual(AnalysisEngine().compute(raw, options: options).commits, 1)
    }
    func testEmptyCommitPreservedOnlyWithoutPathScope() {
        let raw = snapshot([commit("empty", [])])
        XCTAssertEqual(AnalysisEngine().compute(raw).commits, 1)
        var options = AnalysisOptions(); options.pathQuery = "src"
        XCTAssertEqual(AnalysisEngine().compute(raw, options: options).commits, 0)
    }
    func testGlobAndExtensionPolicy() {
        var options = AnalysisOptions(); options.excludedPatterns = ["vendor/*", "*.lock", "*/generated/*"]
        XCTAssertFalse(options.includes(path: "vendor/deep/library.c"))
        XCTAssertFalse(options.includes(path: "pkg/generated/file.swift"))
        XCTAssertFalse(options.includes(path: "Package.lock"))
        XCTAssertTrue(options.includes(path: "Sources/Main.SWIFT"))
        options.fileExtension = "swift"
        XCTAssertTrue(options.includes(path: "Sources/Main.SWIFT"))
        XCTAssertFalse(options.includes(path: "Sources/Main.c"))
    }
    func testOwnershipChurnIsScopedToFileAndEmailIsNormalized() throws {
        let raw = snapshot([
            commit("one", [change("src/a.swift", 2), change("src/b.swift", 50)], email: "A@example.test"),
            commit("two", [change("src/a.swift", 4, 1)], email: "a@example.test"),
            commit("three", [change("src/a.swift", 1)], email: "b@example.test")
        ])
        let metrics = AnalysisEngine().compute(raw)
        XCTAssertEqual(metrics.authors, 2)
        let file = try XCTUnwrap(metrics.ownership.first { $0.path == "src/a.swift" })
        XCTAssertEqual(file.contributors[0].email, "a@example.test")
        XCTAssertEqual(file.contributors[0].commits, 2)
        XCTAssertEqual(file.contributors[0].churn, 7)
        XCTAssertEqual(file.contributors[0].share, 2.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(file.contributors[0].churnShare, 7.0 / 8.0, accuracy: 0.00001)
        XCTAssertEqual(metrics.contributors[0].churn, 57)
        XCTAssertEqual(metrics.directories.first?.commits, 3) // not number of touched files
        XCTAssertEqual(metrics.directories.first?.churn, 58)
    }
    func testCouplingSupportConfidenceThresholdsAndEvidence() throws {
        let raw = snapshot([
            commit("both1", [change("a"), change("b")]), commit("both2", [change("b"), change("a")]),
            commit("onlyA", [change("a")]), commit("onlyC", [change("c")])
        ])
        let metrics = AnalysisEngine().compute(raw)
        let pair = try XCTUnwrap(metrics.coupling.first)
        XCTAssertEqual(metrics.coupling.count, 1)
        XCTAssertEqual(pair.first, "a"); XCTAssertEqual(pair.second, "b")
        XCTAssertEqual(pair.jointCommits, 2)
        XCTAssertEqual(pair.support, 0.5, accuracy: 0.00001)
        XCTAssertEqual(pair.confidenceForward, 2.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(pair.confidenceReverse, 1)
        XCTAssertEqual(pair.commits.map(\.id), ["both1", "both2"])
        var options = AnalysisOptions(); options.minimumJointCommits = 3
        XCTAssertTrue(AnalysisEngine().compute(raw, options: options).coupling.isEmpty)
        options.minimumJointCommits = 2; options.minimumConfidence = 1
        XCTAssertEqual(AnalysisEngine().compute(raw, options: options).coupling.count, 1) // either direction
    }
    func testCouplingCountsEachPathOnceAndSuppressesOversizedRun() {
        var options = AnalysisOptions(); options.minimumJointCommits = 1; options.maximumFilesPerCommit = 0
        let repeated = snapshot([commit("duplicate", [change("a"), change("a"), change("b")])])
        let metric = AnalysisEngine().compute(repeated, options: options)
        XCTAssertEqual(metric.coupling.first?.jointCommits, 1)
        XCTAssertEqual(metric.coupling.first?.confidenceForward, 1)
        let oversized = snapshot([commit("huge", (0...100).map { change("file\($0)") })])
        let limited = AnalysisEngine().compute(oversized, options: options)
        XCTAssertTrue(limited.couplingLimited); XCTAssertTrue(limited.coupling.isEmpty)
        XCTAssertEqual(limited.commits, 1) // other metrics remain available
    }
    func testOptionsRoundTrip() throws {
        var options = AnalysisOptions(); options.excludedPatterns = ["vendor/*"]; options.since = Date(timeIntervalSince1970: 100); options.minimumConfidence = 0.75
        XCTAssertEqual(try JSONDecoder().decode(AnalysisOptions.self, from: JSONEncoder().encode(options)), options)
    }
    func testSQLiteRoundTripIsolationAndRollback() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("cache.sqlite")
        let cache = RepositoryCache(url: database)
        let original = snapshot([commit("original", [change("src/a.swift")])])
        try cache.write(original)
        let read = try XCTUnwrap(cache.read(root: original.root, reference: "HEAD"))
        XCTAssertEqual(read.commits, original.commits); XCTAssertEqual(read.fileSizes, original.fileSizes)
        XCTAssertNil(try cache.read(root: directory, reference: "HEAD"))
        XCTAssertNil(try cache.read(root: original.root, reference: "refs/heads/feature"))
        // Force an insertion error after BEGIN: the original row must survive rollback.
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "CREATE TRIGGER reject_insert BEFORE INSERT ON snapshots BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", nil, nil, nil), SQLITE_OK)
        sqlite3_close(pointer)
        XCTAssertThrowsError(try cache.write(snapshot([commit("replacement", [change("b")])])))
        XCTAssertEqual(try cache.read(root: original.root, reference: "HEAD")?.commits, original.commits)
    }
    func testCancelledWriteKeepsPublishedSnapshot() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RepositoryCache(url: directory.appendingPathComponent("cache.sqlite"))
        let original = snapshot([commit("original", [])]); try cache.write(original)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try cache.write(original); XCTFail("Cancelled write should fail") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await cancelled.value
        XCTAssertEqual(try cache.read(root: original.root, reference: "HEAD")?.commits, original.commits)
    }
    func testCachedIncrementalAndRewriteImportsMatchFullImport() throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        try fixture.add("first.txt", "first\n")
        let service = GitRepositoryService(cacheURL: fixture.directory.appendingPathComponent("cache.sqlite"))
        let initial = try service.load(fixture.repository)
        XCTAssertEqual(initial.importMode, .fresh); XCTAssertEqual(initial.importedCommits, 1)
        let cached = try service.load(fixture.repository)
        XCTAssertEqual(cached.importMode, .cached); XCTAssertEqual(cached.importedCommits, 0)
        try fixture.add("second.txt", "second\n")
        let increment = try service.load(fixture.repository)
        XCTAssertEqual(increment.importMode, .incremental); XCTAssertEqual(increment.importedCommits, 1)
        let full = try GitRepositoryService().load(fixture.repository)
        XCTAssertEqual(increment.commits, full.commits); XCTAssertEqual(increment.fileSizes, full.fileSizes)
        _ = try fixture.git(["reset", "--hard", initial.head])
        try fixture.add("rewritten.txt", "different history\n")
        let rewrite = try service.load(fixture.repository)
        XCTAssertEqual(rewrite.importMode, .fresh)
        XCTAssertEqual(rewrite.commits, try GitRepositoryService().load(fixture.repository).commits)
        XCTAssertFalse(rewrite.commits.contains { $0.subject == "second.txt" })
    }
    func testBranchSelectionDefaultsAndCacheIsolationWithoutCheckout() throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        try fixture.add("main.txt", "main\n")
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        _ = try fixture.git(["checkout", "-b", "feature"])
        try fixture.add("feature.txt", "feature\n")
        let workingHead = try fixture.git(["rev-parse", "HEAD"])
        let service = GitRepositoryService(cacheURL: fixture.directory.appendingPathComponent("cache.sqlite"))
        let main = try service.load(fixture.repository, reference: "DEFAULT")
        XCTAssertEqual(main.head, mainHead); XCTAssertEqual(main.reference, "refs/heads/main")
        XCTAssertEqual(main.commits.count, 1)
        let feature = try service.load(fixture.repository, reference: "refs/heads/feature")
        XCTAssertEqual(feature.commits.count, 2); XCTAssertEqual(feature.importMode, .fresh)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), workingHead)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"]), "refs/heads/feature")
        XCTAssertEqual(try service.load(fixture.repository, reference: "refs/heads/main").importMode, .cached)
        XCTAssertThrowsError(try service.load(fixture.repository, reference: "--all"))
    }
    func testCorruptCachePayloadReimportsSafely() throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        try fixture.add("a", "one\n")
        let url = fixture.directory.appendingPathComponent("cache.sqlite")
        let service = GitRepositoryService(cacheURL: url)
        let before = try service.load(fixture.repository)
        var pointer: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(pointer, "UPDATE snapshots SET payload=x'00ff'", nil, nil, nil), SQLITE_OK); sqlite3_close(pointer)
        let after = try service.load(fixture.repository)
        XCTAssertEqual(after.importMode, .fresh); XCTAssertEqual(after.commits, before.commits)
        XCTAssertNotNil(after.cacheWarning)
        XCTAssertEqual(try service.load(fixture.repository).importMode, .cached)
    }
    func testShallowHistoryChangeInvalidatesSameHeadCache() throws {
        let fixture = try GitFixture(); defer { fixture.remove() }
        try fixture.add("first", "first\n"); try fixture.add("second", "second\n")
        let clone = fixture.directory.appendingPathComponent("shallow")
        _ = try fixture.git(["clone", "--depth", "1", fixture.repository.absoluteString, clone.path])
        let service = GitRepositoryService(cacheURL: fixture.directory.appendingPathComponent("cache.sqlite"))
        let shallow = try service.load(clone)
        XCTAssertTrue(shallow.shallow); XCTAssertEqual(shallow.commits.count, 1)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", clone.path, "fetch", "--unshallow"]
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let complete = try service.load(clone)
        XCTAssertEqual(complete.head, shallow.head); XCTAssertFalse(complete.shallow)
        XCTAssertEqual(complete.importMode, .fresh); XCTAssertEqual(complete.commits.count, 2)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
}
private final class GitFixture {
    let directory: URL
    let repository: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    @discardableResult func git(_ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-C", repository.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test", "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.failed("Fixture command failed: \(args)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func add(_ path: String, _ contents: String) throws {
        try contents.write(to: repository.appendingPathComponent(path), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", path])
    }
}
