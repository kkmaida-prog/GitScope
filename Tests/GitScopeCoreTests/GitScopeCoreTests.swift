import XCTest
@testable import GitScopeCore

final class GitScopeCoreTests: XCTestCase {
    private let oid = String(repeating: "a", count: 40)
    private func history(_ records: String) -> Data {
        Data("\0GITSCOPEv1\0\(oid)\0Ada\0ada@example.test\01700000000\0A subject\0\n\(records)".utf8)
    }
    func testMetadataAndUnusualPaths() throws {
        let commits = try HistoryParser().parse(history("4\t2\tSources/a\tb\ncafé.swift\0"))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].id, oid)
        XCTAssertEqual(commits[0].author, "Ada")
        XCTAssertEqual(commits[0].email, "ada@example.test")
        XCTAssertEqual(commits[0].date.timeIntervalSince1970, 1700000000)
        XCTAssertEqual(commits[0].changes[0].path, "Sources/a\tb\ncafé.swift")
        XCTAssertEqual(commits[0].changes[0].additions, 4)
        XCTAssertEqual(commits[0].changes[0].deletions, 2)
    }
    func testBinaryRenameAndEmptyCommit() throws {
        let parser = HistoryParser()
        let commit = try XCTUnwrap(parser.parse(history("-\t-\timage.png\00\t0\t\0old name\0new name\0")).first)
        XCTAssertTrue(commit.changes[0].isBinary)
        XCTAssertEqual(commit.changes[1].oldPath, "old name")
        XCTAssertEqual(commit.changes[1].path, "new name")
        XCTAssertEqual(try parser.parse(history("")).first?.changes.count, 0)
    }
    func testMalformedOutputFailsInsteadOfPublishingPartialMetrics() {
        XCTAssertThrowsError(try HistoryParser().parse(history("bad\t2\tfile\0")))
        XCTAssertThrowsError(try HistoryParser().parse(history("0\t0\t\0old\0")))
        XCTAssertThrowsError(try HistoryParser().parse(Data([0xff])))
        XCTAssertThrowsError(try HistoryParser().parse(Data("truncated".utf8)))
    }
    func testTreeSizeAndSubmodulePolicy() throws {
        let sizes = try HistoryParser().parseTree(Data("100644 blob \(oid)      12\twith\ttab\nname\0160000 commit \(oid)       -\tsubmodule\0".utf8))
        XCTAssertEqual(sizes, ["with\ttab\nname": 12])
    }
    func testMetricsFrequencyChurnBinaryAuthorsAndMonthGaps() {
        let a = FileChange(path: "a", additions: 3, deletions: 1)
        let b = FileChange(path: "b", additions: nil, deletions: nil)
        let commits = [
            Commit(id: "1", author: "Ada", email: "ADA@example.test", date: Date(timeIntervalSince1970: 1704067200), subject: "January", changes: [a, b]),
            Commit(id: "2", author: "Ada renamed", email: "ada@example.test", date: Date(timeIntervalSince1970: 1709251200), subject: "March", changes: [a])
        ]
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: URL(fileURLWithPath: "/tmp"), head: oid, shallow: false, commits: commits, fileSizes: ["a": 20]))
        XCTAssertEqual(metrics.commits, 2); XCTAssertEqual(metrics.authors, 1)
        XCTAssertEqual(metrics.additions, 6); XCTAssertEqual(metrics.deletions, 2)
        XCTAssertEqual(metrics.binaryChanges, 1)
        XCTAssertEqual(metrics.hotspots.map(\.path), ["a", "b"])
        XCTAssertEqual(metrics.hotspots[0].frequency, 2)
        XCTAssertEqual(metrics.hotspots[0].size, 20)
        XCTAssertNil(metrics.hotspots[1].size)
        XCTAssertEqual(metrics.activity.map(\.commits), [1, 0, 1])
    }
    func testEmptyMetricsAndDeterministicTieBreak() {
        let empty = RepositorySnapshot(root: URL(fileURLWithPath: "/tmp"), head: oid, shallow: false, commits: [], fileSizes: [:])
        XCTAssertTrue(AnalysisEngine().compute(empty).activity.isEmpty)
        let commit = Commit(id: oid, author: "A", email: "a", date: Date(), subject: "", changes: [FileChange(path: "z", additions: 1, deletions: 0), FileChange(path: "a", additions: 1, deletions: 0)])
        XCTAssertEqual(AnalysisEngine().compute(RepositorySnapshot(root: empty.root, head: oid, shallow: false, commits: [commit], fileSizes: [:])).hotspots.map(\.path), ["a", "z"])
    }
    func testRealGitReadOnlyIntegration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test", "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        _ = try git(["init", "-b", "main"])
        let name = "café\tline\nfile.txt"
        try "one\ntwo\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Initial"])
        _ = try git(["mv", name, "renamed.txt"]); _ = try git(["commit", "-m", "Rename"])
        _ = try git(["checkout", "-b", "feature"])
        try "branch\n".write(to: root.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Branch"])
        _ = try git(["checkout", "main"])
        _ = try git(["merge", "--no-ff", "feature", "-m", "Merge"])
        let marker = root.appendingPathComponent("HOOK_EXECUTED")
        let hook = root.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let before = try git(["status", "--porcelain=v1"])
        let headBefore = try git(["rev-parse", "HEAD"])
        let snapshot = try GitRepositoryService().load(root)
        XCTAssertEqual(snapshot.commits.count, Int(try git(["rev-list", "--count", "--no-merges", "HEAD"])))
        XCTAssertEqual(snapshot.commits.count, 3)
        XCTAssertTrue(snapshot.commits.flatMap(\.changes).contains { $0.oldPath == name && $0.path == "renamed.txt" })
        XCTAssertEqual(AnalysisEngine().compute(snapshot).additions, 3)
        XCTAssertEqual(AnalysisEngine().compute(snapshot).binaryChanges, 1)
        XCTAssertEqual(snapshot.fileSizes["renamed.txt"], 8)
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), before)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testInvalidRepositoryReportsError() throws {
        XCTAssertThrowsError(try GitRepositoryService().load(FileManager.default.temporaryDirectory))
    }
}
