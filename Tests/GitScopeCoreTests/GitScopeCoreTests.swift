import XCTest
@testable import GitScopeCore
import SQLite3

final class GitScopeCoreTests: XCTestCase {
    func testCodeQualityDetectsDuplicatesAndLinksOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = (1...14).map { "let result\($0) = process(input\($0), options: config\($0))" }.joined(separator: "\n")
        try sample.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try sample.write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let commit = Commit(id: "abc", author: "Ada", email: "ada@test.local", date: Date(), subject: "Test",
                            changes: [FileChange(path: "a.swift", additions: 14, deletions: 0),
                                      FileChange(path: "b.swift", additions: 14, deletions: 0)])
        let secondCommit = Commit(id: "def", author: "Ada", email: "ada@test.local", date: Date(), subject: "Another change",
                                  changes: [FileChange(path: "a.swift", additions: 1, deletions: 0),
                                            FileChange(path: "b.swift", additions: 1, deletions: 0)])
        let snapshot = RepositorySnapshot(root: root, head: "def", shallow: false,
                                          commits: [commit, secondCommit], fileSizes: ["a.swift": 300, "b.swift": 300])
        let metrics = AnalysisEngine().compute(snapshot)
        let quality = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(quality.inspectedFiles, 2)
        XCTAssertFalse(quality.duplicates.isEmpty)
        XCTAssertTrue(quality.candidates.contains { $0.path == "a.swift" && $0.leadingAuthor == "ada@test.local" })
        XCTAssertTrue(quality.candidates.allSatisfy { (0...100).contains($0.score) })
    }

    func testDuplicateBlocksSkipImportsAndMergeWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = (1...16).map { "let calculated\($0) = performOperation(source\($0), configuration: setting\($0))" }.joined(separator: "\n")
        let first = "import Foundation\n// Header comment\n" + shared + "\n"
        let second = "import Foundation\n// Different comment\n" + shared + "\n"
        try first.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try second.write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let commit = Commit(id: "test", author: "A", email: "a@fixture.test", date: Date(), subject: "fixture",
                            changes: [FileChange(path: "a.swift", additions: 16, deletions: 0),
                                      FileChange(path: "b.swift", additions: 16, deletions: 0)])
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "test", shallow: false,
                                         commits: [commit], fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(report.duplicates.count, 1)
        XCTAssertEqual(report.duplicates[0].lineCount, 16)
        XCTAssertEqual(report.duplicates[0].firstLine, 3)
        XCTAssertEqual(report.duplicates[0].firstEndLine, 18)
        XCTAssertEqual(report.duplicates[0].secondLine, 3)
        XCTAssertFalse(report.truncated)
    }

    func testOnlyImportsAndCommentsAreNotDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boilerplate = (1...14).map { "import Package\($0)\n// Comment \($0)" }.joined(separator: "\n")
        for file in ["a.swift", "b.swift"] {
            try boilerplate.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let commit = Commit(id: "test", author: "A", email: "a@fixture.test", date: Date(), subject: "fixture",
                            changes: [FileChange(path: "a.swift", additions: 14, deletions: 0),
                                      FileChange(path: "b.swift", additions: 14, deletions: 0)])
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "test", shallow: false,
                                          commits: [commit], fileSizes: [:]))
        XCTAssertTrue(CodeQualityAnalyzer().analyze(root: root, metrics: metrics).duplicates.isEmpty)
    }

    func testCodeQualityExcludesDocumentationAndRequiresHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldCommit = Commit(id: "1", author: "Ada", email: "ada@test.local", date: Date(), subject: "Initial",
                               changes: [FileChange(path: "docs/USER_GUIDE.md", additions: 1000, deletions: 0),
                                         FileChange(path: "Source.swift", additions: 10, deletions: 0),
                                         FileChange(path: "Single.swift", additions: 200, deletions: 0)])
        let newCommit = Commit(id: "2", author: "Ada", email: "ada@test.local", date: Date(), subject: "Update",
                               changes: [FileChange(path: "Source.swift", additions: 4, deletions: 1)])
        let snapshot = RepositorySnapshot(root: root, head: "2", shallow: false,
                                          commits: [oldCommit, newCommit], fileSizes: [:])
        let quality = CodeQualityAnalyzer().analyze(root: root, metrics: AnalysisEngine().compute(snapshot))
        XCTAssertEqual(quality.candidates.map(\.path), ["Source.swift"])
        XCTAssertEqual(quality.excludedNonCodeFiles, 1)
        XCTAssertEqual(quality.insufficientHistoryFiles, 1)
        XCTAssertEqual(quality.minimumFileCommits, 2)
    }

    func testCodeQualityV4ExcludesVersionedSwiftPackageManifests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = (1...15).map { "let dependency\($0) = packageOption(parameter\($0), configuration\($0))" }.joined(separator: "\n")
        let paths = ["Package@swift-6.0.swift", "Package@swift-6.1.swift", "Source.swift"]
        for path in paths {
            try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let commits = (1...2).map { number in
            Commit(id: "\(number)", author: "A", email: "a@test.local", date: Date(), subject: "Update",
                   changes: paths.map { FileChange(path: $0, additions: 15, deletions: 0) })
        }
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "2", shallow: false,
                                                  commits: commits, fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(report.candidates.map(\.path), ["Source.swift"])
        XCTAssertEqual(report.inspectedFiles, 1)
        XCTAssertEqual(report.excludedNonCodeFiles, 2)
        XCTAssertTrue(report.duplicates.isEmpty)
        XCTAssertTrue(report.duplicateGroups.isEmpty)
    }

    func testCodeQualityV4GroupsThreeIdenticalFilesAndScopesScores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = (1...18).map { "let result\($0) = calculate(value\($0), configuration: config\($0))" }.joined(separator: "\n")
        let paths = ["Src/Alpha.swift", "Src/Beta.swift", "Tests/AlphaTests.swift"]
        for path in paths {
            try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let commits = (1...3).map { number in
            Commit(id: "\(number)", author: "A", email: "a@test.local", date: Date(), subject: "Update",
                   changes: paths.map { FileChange(path: $0, additions: 18, deletions: 0) })
        }
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "3", shallow: false,
                                                  commits: commits, fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(report.duplicates.count, 3, "Three file pairs for the same content")
        XCTAssertEqual(report.duplicateGroups.count, 1, "Unique block, not number of pairs")
        XCTAssertEqual(report.duplicateGroups[0].locations.count, 3)
        XCTAssertEqual(report.scopedDuplicateGroups(.production).count, 1)
        XCTAssertEqual(report.scopedDuplicateGroups(.production)[0].locations.count, 2)
        XCTAssertEqual(report.scopedDuplicateGroups(.tests).count, 0)
        XCTAssertEqual(report.scopedDuplicateGroups(.all).count, 1)
        XCTAssertEqual(Set(report.scopedCandidates(.production).map(\.path)), Set(paths.prefix(2)))
        XCTAssertTrue(report.scopedCandidates(.production).allSatisfy { $0.duplicateOccurrences == 1 })
        XCTAssertEqual(report.scopedCandidates(.tests).map(\.path), ["Tests/AlphaTests.swift"])
        XCTAssertEqual(report.scopedCandidates(.tests).first?.duplicateOccurrences, 0,
                       "Cross-scope duplicates should not boost test-only priority")
        XCTAssertEqual(report.scopedCandidates(.all).count, 3)
        XCTAssertFalse(report.truncated)
    }

    func testCodeQualityV4SeparatesTestNamePatterns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ["App/Service.swift", "App/Contest.swift", "App/ServiceTests.swift", "src/__tests__/helper.ts", "src/cache.test.ts"]
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "let example = process(input: request, settings: config)\n".write(to: file, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let commits = (1...2).map { number in
            Commit(id: "\(number)", author: "A", email: "a@test.local", date: Date(), subject: "Update",
                   changes: paths.map { FileChange(path: $0, additions: 1, deletions: 0) })
        }
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "2", shallow: false,
                                                  commits: commits, fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(Set(report.scopedCandidates(.production).map(\.path)), Set(["App/Service.swift", "App/Contest.swift"]))
        XCTAssertEqual(Set(report.scopedCandidates(.tests).map(\.path)),
                       Set(["App/ServiceTests.swift", "src/__tests__/helper.ts", "src/cache.test.ts"]))
    }

    func testCodeQualityV5ReportsRealSkipReasonsAndPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let result = request.value\n".write(to: root.appendingPathComponent("valid.swift"),
                                                atomically: true, encoding: .utf8)
        try Data(repeating: 65, count: 512_001).write(to: root.appendingPathComponent("large.swift"))
        try Data([65, 0, 66]).write(to: root.appendingPathComponent("binary.swift"))
        try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("nonutf8.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"),
                                                    withDestinationURL: root.appendingPathComponent("valid.swift"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.swift"),
                                                withIntermediateDirectories: true)
        let paths = ["valid.swift", "large.swift", "binary.swift", "nonutf8.swift",
                     "link.swift", "directory.swift", "missing.swift", "../escape.swift"]
        let commit = Commit(id: "v5", author: "Ada", email: "ada@test.local", date: Date(),
                            subject: "History", changes: paths.map { FileChange(path: $0, additions: 1, deletions: 0) })
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "v5", shallow: false,
                                                  commits: [commit], fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(report.inspectedFiles, 1)
        XCTAssertEqual(report.skippedFiles, 7)
        XCTAssertEqual(report.skippedDetails.count, report.skippedFiles)
        XCTAssertEqual(report.totalCandidateSourceFiles, 8)
        XCTAssertEqual(report.notProcessedFiles, 0)
        XCTAssertEqual(report.skippedCount(for: .missing), 1)
        XCTAssertEqual(report.skippedCount(for: .tooLarge), 1)
        XCTAssertEqual(report.skippedCount(for: .binary), 2)
        XCTAssertEqual(report.skippedCount(for: .symlink), 1)
        XCTAssertEqual(report.skippedCount(for: .notRegular), 1)
        XCTAssertEqual(report.skippedCount(for: .unsafePath), 1)
        XCTAssertEqual(Set(report.skippedDetails.map(\.path)), Set(paths).subtracting(["valid.swift"]))
        XCTAssertEqual(report.attemptedCoveragePercent, 12.5, accuracy: 0.01)
    }

    func testCodeQualityV5ZeroSkippedFilesHasFullAttemptedCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let x = 123\n".write(to: root.appendingPathComponent("file.swift"),
                                       atomically: true, encoding: .utf8)
        let commit = Commit(id: "v5", author: "Ada", email: "ada@test.local", date: Date(),
                            subject: "History", changes: [FileChange(path: "file.swift", additions: 1, deletions: 0)])
        let metrics = AnalysisEngine().compute(RepositorySnapshot(root: root, head: "v5", shallow: false,
                                                  commits: [commit], fileSizes: [:]))
        let report = CodeQualityAnalyzer().analyze(root: root, metrics: metrics)
        XCTAssertEqual(report.skippedFiles, 0)
        XCTAssertEqual(report.skippedDetails.count, 0)
        XCTAssertEqual(report.inspectedFiles, 1)
        XCTAssertEqual(report.attemptedCoveragePercent, 100, accuracy: 0.01)
    }

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
    // v6: the selected commit's file tree is authoritative; deleted historical paths
    // and untracked working-tree files must not be treated as scan candidates.
    func testCodeQualityV6ScansOnlySelectedRevisionPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Tester",
                                   "GIT_AUTHOR_EMAIL": "tester@example.test", "GIT_COMMITTER_NAME": "Tester",
                                   "GIT_COMMITTER_EMAIL": "tester@example.test"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args)")
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        let repeated = (1...16).map { "let value\($0) = computeResult(input\($0), configuration: option\($0))" }.joined(separator: "\n") + "\n"
        _ = try git(["init", "-b", "main"])
        try "old history\n".write(to: root.appendingPathComponent("old.swift"), atomically: true, encoding: .utf8)
        try repeated.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try repeated.write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Initial"])
        let initial = try git(["rev-parse", "HEAD"])
        _ = try git(["rm", "old.swift"])
        _ = try git(["commit", "-m", "Remove legacy file"])
        let selected = try git(["rev-parse", "HEAD"])
        try repeated.write(to: root.appendingPathComponent("untracked.swift"), atomically: true, encoding: .utf8)
        let commit1 = Commit(id: initial, author: "Tester", email: "tester@example.test", date: Date(),
                             subject: "Initial", changes: ["old.swift", "a.swift", "b.swift"].map {
                                 FileChange(path: $0, additions: 16, deletions: 0) })
        let commit2 = Commit(id: selected, author: "Tester", email: "tester@example.test", date: Date(),
                             subject: "Removal", changes: [FileChange(path: "old.swift", additions: 0, deletions: 1)])
        let snapshot = RepositorySnapshot(root: root, head: selected, shallow: false,
                                          commits: [commit1, commit2],
                                          fileSizes: ["a.swift": repeated.utf8.count, "b.swift": repeated.utf8.count])
        let result = CodeQualityAnalyzer().analyze(snapshot: snapshot, metrics: AnalysisEngine().compute(snapshot))
        XCTAssertTrue(result.revisionBasedScan)
        XCTAssertEqual(result.inspectedFiles, 2)
        XCTAssertEqual(result.skippedFiles, 0)
        XCTAssertEqual(result.historicalOnlyPaths, 1)
        XCTAssertEqual(result.totalCandidateSourceFiles, 2)
        XCTAssertEqual(result.attemptedCoveragePercent, 100)
        XCTAssertEqual(result.duplicateGroups.count, 1)
        XCTAssertEqual(Set(result.duplicateGroups[0].locations.map(\.path)), ["a.swift", "b.swift"])
        XCTAssertFalse(result.duplicateGroups[0].locations.contains { $0.path == "untracked.swift" })
    }

    func testCodeQualityV6ReadsOldBranchBlobWithoutCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Tester",
                                   "GIT_AUTHOR_EMAIL": "tester@example.test", "GIT_COMMITTER_NAME": "Tester",
                                   "GIT_COMMITTER_EMAIL": "tester@example.test"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args)")
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        _ = try git(["init", "-b", "main"])
        let repeated = (1...16).map { "let result\($0) = calculate(input\($0), config: value\($0))" }.joined(separator: "\n") + "\n"
        try repeated.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try repeated.write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Identical at this revision"])
        let oldSHA = try git(["rev-parse", "HEAD"])
        try "let latest = \"different code here\"\n".write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Modify working tree"])
        let newSHA = try git(["rev-parse", "HEAD"])
        let changes = ["a.swift", "b.swift"].map { FileChange(path: $0, additions: 16, deletions: 0) }
        let oldCommit = Commit(id: oldSHA, author: "Tester", email: "tester@example.test", date: Date(), subject: "Old", changes: changes)
        let snapshot = RepositorySnapshot(root: root, head: oldSHA, shallow: false,
                                          commits: [oldCommit], fileSizes: ["a.swift": repeated.utf8.count,
                                                                             "b.swift": repeated.utf8.count])
        let report = CodeQualityAnalyzer().analyze(snapshot: snapshot, metrics: AnalysisEngine().compute(snapshot))
        XCTAssertEqual(report.inspectedFiles, 2)
        XCTAssertEqual(report.duplicateGroups.count, 1, "The selected historical SHA has duplicate code even though the current checkout does not")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newSHA, "Scanning must not checkout or change HEAD")
        XCTAssertEqual(try git(["status", "--porcelain"]), "", "Scanning must not modify the working tree")
    }

    func testCodeQualityV6AppliesPathFilterToSelectedTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Tester",
                                   "GIT_AUTHOR_EMAIL": "tester@example.test", "GIT_COMMITTER_NAME": "Tester",
                                   "GIT_COMMITTER_EMAIL": "tester@example.test"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        _ = try git(["init", "-b", "main"])
        let repeated = (1...16).map { "let result\($0) = calculate(input\($0), config: value\($0))" }.joined(separator: "\n") + "\n"
        try repeated.write(to: root.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
        try repeated.write(to: root.appendingPathComponent("Second.swift"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "A"])
        let sha = try git(["rev-parse", "HEAD"])
        let changes = ["First.swift", "Second.swift"].map { FileChange(path: $0, additions: 16, deletions: 0) }
        let snapshot = RepositorySnapshot(root: root, head: sha, shallow: false,
                                          commits: [Commit(id: sha, author: "Tester", email: "tester@example.test",
                                                           date: Date(), subject: "A", changes: changes)],
                                          fileSizes: ["First.swift": repeated.utf8.count, "Second.swift": repeated.utf8.count])
        var options = AnalysisOptions()
        options.pathQuery = "First"
        let report = CodeQualityAnalyzer().analyze(snapshot: snapshot, metrics: AnalysisEngine().compute(snapshot, options: options), options: options)
        XCTAssertEqual(report.inspectedFiles, 1)
        XCTAssertEqual(report.totalCandidateSourceFiles, 1)
        XCTAssertEqual(report.duplicateGroups.count, 0)
    }

}

// MARK: - v7 persistent Code Quality SQLite cache
final class CodeQualitySQLiteCacheTests: XCTestCase {
    private func fixture() throws -> (URL, RepositorySnapshot, RepositoryMetrics, CodeQualityCacheService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commit1 = Commit(id: "first", author: "Ada", email: "ada@example.test", date: Date(timeIntervalSince1970: 1), subject: "first",
                             changes: [FileChange(path: "Source/A.swift", additions: 3, deletions: 0)])
        let commit2 = Commit(id: "second", author: "Ada", email: "ada@example.test", date: Date(timeIntervalSince1970: 2), subject: "second",
                             changes: [FileChange(path: "Source/A.swift", additions: 1, deletions: 0)])
        // Empty selected revision: testing cache behavior independently of Git execution.
        let snapshot = RepositorySnapshot(root: root, head: "head1", shallow: false, commits: [commit1, commit2], fileSizes: [:], reference: "HEAD")
        let metrics = AnalysisEngine().compute(snapshot)
        return (root, snapshot, metrics, CodeQualityCacheService(cacheURL: root.appendingPathComponent("history-v2.sqlite")))
    }

    func testV7FirstComputeThenPersistentSQLiteHit() throws {
        let (root, snapshot, metrics, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = service.loadOrCompute(snapshot: snapshot, metrics: metrics)
        XCTAssertEqual(initial.status, .stored)
        let reopened = CodeQualityCacheService(cacheURL: root.appendingPathComponent("history-v2.sqlite"))
        let second = reopened.loadOrCompute(snapshot: snapshot, metrics: metrics)
        XCTAssertEqual(second.status, .hit)
        XCTAssertEqual(second.report.inspectedFiles, initial.report.inspectedFiles)
        XCTAssertEqual(second.report.historicalOnlyPaths, initial.report.historicalOnlyPaths)
        XCTAssertEqual(second.report.scopedCandidates(.all).map(\.path), initial.report.scopedCandidates(.all).map(\.path))
    }

    func testV7OptionsRevisionAndThresholdsInvalidateResult() throws {
        let (root, snapshot, metrics, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics).status, .stored)
        var filter = AnalysisOptions()
        filter.fileExtension = "swift"
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics, options: filter).status, .stored)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics, options: filter).status, .hit)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics, minimumLines: 12).status, .stored)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics, minimumFileCommits: 3).status, .stored)
        let updated = RepositorySnapshot(root: root, head: "head2", shallow: false, commits: snapshot.commits, fileSizes: [:], reference: "HEAD")
        XCTAssertEqual(service.loadOrCompute(snapshot: updated, metrics: metrics).status, .stored)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics).status, .stored,
                       "Superseded HEAD should be pruned to prevent unbounded cache growth")
    }

    func testV7CacheCorruptionTriggersRecompute() throws {
        let (root, snapshot, metrics, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics).status, .stored)
        // Inject a damaged payload through the existing SQLite database.
        let database = root.appendingPathComponent("history-v2.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE code_quality_results SET payload=x'00ff'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics).status, .stored)
        XCTAssertEqual(service.loadOrCompute(snapshot: snapshot, metrics: metrics).status, .hit)
    }

    func testV7ReportSerializationPreservesDuplicateGroups() throws {
        let (root, snapshot, _, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = RefactoringCandidate(path: "Source/A.swift", kind: .production, score: 65,
                                         frequency: 2, churn: 4, duplicateOccurrences: 1,
                                         leadingAuthor: "ada@example.test", leadingAuthorShare: 1)
        let first = DuplicateLocation(path: "Source/A.swift", startLine: 1, endLine: 12, kind: .production)
        let second = DuplicateLocation(path: "Source/B.swift", startLine: 3, endLine: 14, kind: .production)
        let group = DuplicateGroup(id: 0, locations: [first, second], lineCount: 12, preview: "let x = 1")
        let report = CodeQualityReport(candidates: [owner], duplicates: [], duplicateGroups: [group],
                                       inspectedFiles: 2, skippedFiles: 0, skippedDetails: [],
                                       totalCandidateSourceFiles: 2, truncated: false, excludedNonCodeFiles: 0,
                                       insufficientHistoryFiles: 0, minimumFileCommits: 2,
                                       historicalOnlyPaths: 0, revisionBasedScan: true)
        try service.cache.writeCodeQuality(report, root: root, reference: snapshot.reference,
                                           head: snapshot.head, configuration: "test-configuration", version: CodeQualityCacheService.algorithmVersion)
        let loaded = try XCTUnwrap(service.cache.readCodeQuality(root: root, reference: snapshot.reference,
                                            head: snapshot.head, configuration: "test-configuration", version: CodeQualityCacheService.algorithmVersion))
        XCTAssertEqual(loaded.duplicateGroups.count, 1)
        XCTAssertEqual(loaded.duplicateGroups[0].locations, [first, second])
        XCTAssertEqual(loaded.scopedCandidates(.production).first?.duplicateOccurrences, 1)
        XCTAssertNil(try service.cache.readCodeQuality(root: root, reference: "other", head: snapshot.head,
                                                       configuration: "test-configuration", version: CodeQualityCacheService.algorithmVersion))
        XCTAssertNil(try service.cache.readCodeQuality(root: root, reference: snapshot.reference, head: snapshot.head,
                                                       configuration: "test-configuration", version: CodeQualityCacheService.algorithmVersion + 1))
    }
}
