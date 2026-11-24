import Foundation

public struct AnalysisEngine {
    public init() {}
    public func compute(_ rawSnapshot: RepositorySnapshot, options: AnalysisOptions = AnalysisOptions()) -> RepositoryMetrics {
        let snapshot = options.apply(to: rawSnapshot)
        // Path identities remain literal: rename transitions are retained as evidence,
        // but ambiguous cross-branch identity is deliberately not guessed.
        var files: [String: [Commit]] = [:]
        var totals: [String: (Int, Int, Int)] = [:]
        var months: [Date: Int] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for commit in snapshot.commits {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: commit.date))!
            months[month, default: 0] += 1
            var seen = Set<String>()
            for change in commit.changes {
                if seen.insert(change.path).inserted { files[change.path, default: []].append(commit) }
                let previous = totals[change.path, default: (0, 0, 0)]
                totals[change.path] = (previous.0 + (change.additions ?? 0), previous.1 + (change.deletions ?? 0), previous.2 + (change.isBinary ? 1 : 0))
            }
        }
        var hotspots: [Hotspot] = []
        for (path, commits) in files {
            let total = totals[path]!
            let hotspot = Hotspot(path: path, frequency: commits.count, additions: total.0, deletions: total.1, binaryChanges: total.2, size: snapshot.fileSizes[path], commits: commits)
            hotspots.append(hotspot)
        }
        hotspots.sort { left, right in
            if left.frequency != right.frequency { return left.frequency > right.frequency }
            if left.churn != right.churn { return left.churn > right.churn }
            return left.path < right.path
        }
        // Include zero-activity months so gaps in development remain visible.
        var activity: [ActivityBucket] = []
        if var month = months.keys.min(), let end = months.keys.max() {
            while month <= end {
                activity.append(ActivityBucket(month: month, commits: months[month, default: 0]))
                month = calendar.date(byAdding: .month, value: 1, to: month)!
            }
        }
        let advanced = AdvancedAnalysis().compute(snapshot, options: options)
        return RepositoryMetrics(commits: snapshot.commits.count, authors: Set(snapshot.commits.map { $0.email.lowercased() }).count, additions: hotspots.reduce(0) { $0 + $1.additions }, deletions: hotspots.reduce(0) { $0 + $1.deletions }, binaryChanges: hotspots.reduce(0) { $0 + $1.binaryChanges }, hotspots: hotspots, activity: activity, contributors: advanced.contributors, ownership: advanced.ownership,
                                 coupling: advanced.coupling, directories: advanced.directories, couplingLimited: advanced.limited,
                                 excludedCommits: rawSnapshot.commits.count - snapshot.commits.count, currentFileCount: snapshot.fileSizes.count)
    }
}


// MARK: - Code quality analysis (selected Git revision, read-only)

public enum CodeQualityFileKind: String, Codable, Sendable {
    case production
    case test
}

public enum CodeQualityScope: String, CaseIterable, Sendable {
    case production = "Production"
    case tests = "Tests"
    case all = "All code"

    public func includes(_ kind: CodeQualityFileKind) -> Bool {
        switch self {
        case .all: return true
        case .production: return kind == .production
        case .tests: return kind == .test
        }
    }
}

public struct DuplicateLocation: Hashable, Identifiable, Codable, Sendable {
    public var id: String { "\(path):\(startLine)-\(endLine)" }
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let kind: CodeQualityFileKind
}

/// One unique normalized code block, potentially found in three or more files.
public struct DuplicateGroup: Identifiable, Codable, Sendable {
    public let id: Int
    public let locations: [DuplicateLocation]
    public let lineCount: Int
    public let preview: String
}

public struct DuplicateMatch: Identifiable, Codable, Sendable {
    public var id: String { firstPath + ":" + String(firstLine) + "|" + secondPath + ":" + String(secondLine) }
    public let firstPath: String
    public let firstLine: Int
    public let firstEndLine: Int
    public let secondPath: String
    public let secondLine: Int
    public let secondEndLine: Int
    public let lineCount: Int
    public let preview: String
}

public struct RefactoringCandidate: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: CodeQualityFileKind
    public let score: Int
    public let frequency: Int
    public let churn: Int
    public let duplicateOccurrences: Int
    public let leadingAuthor: String?
    public let leadingAuthorShare: Double
}

/// A source path from Git history that the read-only working-tree duplicate scan could not inspect.
public enum DuplicateScanSkipReason: String, CaseIterable, Codable, Sendable {
    case missing = "Missing historical paths"
    case tooLarge = "Files over size limit"
    case binary = "Binary / non-UTF8 files"
    case symlink = "Symbolic links"
    case unreadable = "Unreadable files"
    case notRegular = "Not regular files"
    case unsafePath = "Unsafe / outside repository paths"
}

public struct DuplicateScanSkip: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let reason: DuplicateScanSkipReason
}

public struct CodeQualityReport: Codable, Sendable {
    public let candidates: [RefactoringCandidate]
    public let duplicates: [DuplicateMatch]
    public let duplicateGroups: [DuplicateGroup]
    public let inspectedFiles: Int
    public let skippedFiles: Int
    /// One reason per skipped eligible source path, not fabricated example totals.
    public let skippedDetails: [DuplicateScanSkip]
    /// Eligible historical source paths considered by the duplicate scanner.
    public let totalCandidateSourceFiles: Int
    public var notProcessedFiles: Int {
        max(0, totalCandidateSourceFiles - inspectedFiles - skippedFiles)
    }
    /// Percentage of paths that the scanner actually attempted to read.
    /// Not a measure of all tracked repository files or of duplicate completeness.
    public var attemptedCoveragePercent: Double {
        let attempted = inspectedFiles + skippedFiles
        return attempted == 0 ? 100 : 100 * Double(inspectedFiles) / Double(attempted)
    }
    public func skippedCount(for reason: DuplicateScanSkipReason) -> Int {
        skippedDetails.filter { $0.reason == reason }.count
    }
    public let truncated: Bool
    public let excludedNonCodeFiles: Int
    public let insufficientHistoryFiles: Int
    public let minimumFileCommits: Int
    /// Eligible code paths that occur in filtered Git history but no longer exist
    /// in the selected revision. These are intentionally not scan failures.
    public let historicalOnlyPaths: Int
    /// True if content was read from immutable blobs in the selected Git revision.
    public let revisionBasedScan: Bool

    /// Refilter existing results without rereading source files. Frequency/churn maxima
    /// and duplicate contribution are recalculated within the selected scope.
    public func scopedDuplicateGroups(_ scope: CodeQualityScope) -> [DuplicateGroup] {
        duplicateGroups.compactMap { group in
            let locations = group.locations.filter { scope.includes($0.kind) }
            guard Set(locations.map(\.path)).count >= 2 else { return nil }
            return DuplicateGroup(id: group.id, locations: locations,
                                  lineCount: group.lineCount, preview: group.preview)
        }
    }

    public func scopedCandidates(_ scope: CodeQualityScope) -> [RefactoringCandidate] {
        let selected = candidates.filter { scope.includes($0.kind) }
        let maxFrequency = max(1, selected.map(\.frequency).max() ?? 1)
        let maxChurn = max(1, selected.map(\.churn).max() ?? 1)
        var duplicateCounts: [String: Int] = [:]
        for group in scopedDuplicateGroups(scope) {
            for path in Set(group.locations.map(\.path)) {
                duplicateCounts[path, default: 0] += 1
            }
        }
        return selected.map { file in
            let duplicates = duplicateCounts[file.path, default: 0]
            let frequency = log1p(Double(file.frequency)) / log1p(Double(maxFrequency))
            let churn = log1p(Double(file.churn)) / log1p(Double(maxChurn))
            let duplication = min(1.0, Double(duplicates) / 3.0)
            let score = min(100, Int((65 * frequency + 25 * churn + 10 * duplication).rounded()))
            return RefactoringCandidate(path: file.path, kind: file.kind, score: score,
                                        frequency: file.frequency, churn: file.churn,
                                        duplicateOccurrences: duplicates,
                                        leadingAuthor: file.leadingAuthor,
                                        leadingAuthorShare: file.leadingAuthorShare)
        }.sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
    }
}

public struct CodeQualityAnalyzer {
    public init() {}
    private let extensions: Set<String> = ["swift", "php", "sql", "cs", "java", "js", "ts", "jsx", "tsx", "py", "go", "rb", "kt", "c", "h", "cpp", "hpp"]

    private struct CodeLine {
        let number: Int
        let text: String
    }
    private struct IndexedFile {
        let path: String
        let lines: [CodeLine]
    }
    private struct Occurrence {
        let fileIndex: Int
        let start: Int
    }
    private struct GroupBuilder {
        let lineCount: Int
        let preview: String
        var locations: [DuplicateLocation] = []
        var seen: Set<DuplicateLocation> = []
        mutating func insert(_ location: DuplicateLocation) {
            if seen.insert(location).inserted { locations.append(location) }
        }
    }
    private struct CandidateBlock {
        let firstFile: Int
        let firstStart: Int
        let secondFile: Int
        let secondStart: Int
        let count: Int
    }

    // Shared path classification for rankings AND duplicate detection.
    private func fileKind(_ path: String) -> CodeQualityFileKind {
        let components = path.lowercased().split(separator: "/").map(String.init)
        let folders: Set<String> = ["test", "tests", "__tests__", "spec", "specs", "unittests", "integrationtests", "uitests"]
        if components.dropLast().contains(where: { folders.contains($0) }) { return .test }
        let name = components.last ?? ""
        let originalName = String(path.split(separator: "/").last ?? "")
        // Keep the Test/Tests capitalisation in Swift/Java/C# conventions so a normal
        // production filename like Contest.swift is not mistaken for a test.
        let conventionalTestSuffixes = ["Test.swift", "Tests.swift", "Spec.swift",
                                        "Test.java", "Tests.java", "Test.kt", "Tests.kt",
                                        "Test.cs", "Tests.cs"]
        if name.hasPrefix("test_") || name.hasSuffix("_test.swift") ||
           name.hasSuffix("_tests.swift") || name.hasSuffix("_test.py") ||
           name.contains(".test.") || name.contains(".spec.") ||
           conventionalTestSuffixes.contains(where: { originalName.hasSuffix($0) }) { return .test }
        return .production
    }

    // Conservatively exclude docs, manifests, generated and vendored content from refactoring rankings.
    private func isScorableSource(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/").map(String.init)
        guard let filename = components.last else { return false }
        let ignoredDirectories: Set<String> = ["docs", "documentation", "vendor", "node_modules", "pods", "build", ".build", ".build-verification", "dist", "generated", "third_party", "third-party", ".git", "deriveddata", "coverage"]
        guard !components.dropLast().contains(where: { ignoredDirectories.contains($0) }) else { return false }
        let ignoredFilenames: Set<String> = ["package.swift", "package.json", "composer.json", "podfile", "gemfile", "makefile", "dockerfile", "cmakelists.txt"]
        guard !ignoredFilenames.contains(filename),
              !(filename.hasPrefix("package@swift-") && filename.hasSuffix(".swift")),
              !filename.hasSuffix(".generated.swift"),
              !filename.hasSuffix(".g.swift"), !filename.hasSuffix(".designer.cs") else { return false }
        return extensions.contains((filename as NSString).pathExtension)
    }

    // Simple language-independent normalization. This intentionally does not strip inline comments,
    // change identifiers or claim semantic equivalence.
    private func normalizedLines(_ source: String) -> [CodeLine] {
        var result: [CodeLine] = []
        var inBlockComment = false
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") ||
                trimmed.hasPrefix("--") || trimmed.hasPrefix("import ") || trimmed.hasPrefix("@import ") ||
                trimmed.hasPrefix("from ") || trimmed.hasPrefix("using ") || trimmed.hasPrefix("#include") ||
                trimmed.hasPrefix("require ") || trimmed.hasPrefix("package ") { continue }
            let normalized = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !normalized.isEmpty { result.append(CodeLine(number: index + 1, text: normalized)) }
        }
        return result
    }

    private func overlapping(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }

    /// Scan exactly the source files present in the selected Git revision, not all
    /// historical hotspot paths. Blob contents are read from Git objects by SHA:
    /// no checkout, branch switching, or working-tree writes are necessary.
    /// Path/extension exclusions apply to revision-file selection; date/author
    /// filters continue to affect the history-based scoring metrics independently.
    public func analyze(snapshot: RepositorySnapshot, metrics: RepositoryMetrics,
                        options: AnalysisOptions = AnalysisOptions(),
                        minimumLines: Int = 10, minimumFileCommits: Int = 2) -> CodeQualityReport {
        let selectedFiles = snapshot.fileSizes.filter { options.includes(path: $0.key) }
        return analyzeImpl(root: snapshot.root, metrics: metrics,
                           revision: snapshot.head, revisionFiles: selectedFiles,
                           minimumLines: minimumLines, minimumFileCommits: minimumFileCommits)
    }

    /// Kept for callers/tests that explicitly need the legacy working-tree scanner.
    /// The application uses analyze(snapshot:metrics:options:) instead.
    public func analyze(root: URL, metrics: RepositoryMetrics,
                        minimumLines: Int = 10, minimumFileCommits: Int = 2) -> CodeQualityReport {
        analyzeImpl(root: root, metrics: metrics, revision: nil, revisionFiles: nil,
                    minimumLines: minimumLines, minimumFileCommits: minimumFileCommits)
    }

    private func analyzeImpl(root: URL, metrics: RepositoryMetrics,
                             revision: String?, revisionFiles: [String: Int]?,
                             minimumLines: Int, minimumFileCommits: Int) -> CodeQualityReport {
        let window = max(3, minimumLines)
        let maxBytes = 512_000
        let maxFiles = 2_000
        let maxWindows = 120_000
        let maxCandidateBlocks = 12_000
        let maxMatches = 400
        var inspected = 0
        var skippedDetails: [DuplicateScanSkip] = []
        func skip(_ path: String, because reason: DuplicateScanSkipReason) {
            skippedDetails.append(DuplicateScanSkip(path: path, reason: reason))
        }
        var windows = 0
        var truncated = false
        let rootURL = root.standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path + "/"
        var files: [IndexedFile] = []
        var index: [String: [Occurrence]] = [:]
        var blocks: [CandidateBlock] = []

        // A historical hotspot is not evidence that its path exists in the selected
        // revision. The current tree comes from `git ls-tree` in RepositorySnapshot.
        let revisionPaths = revisionFiles.map { Set($0.keys) }
        let historicalOnlyPaths = revisionPaths.map { present in
            metrics.hotspots.filter { isScorableSource($0.path) && !present.contains($0.path) }.count
        } ?? 0
        let scanPaths: [String] = (revisionFiles.map { Array($0.keys) }
                                   ?? metrics.hotspots.map(\.path))
            .filter { isScorableSource($0) }.sorted()
        let runner = GitCommandRunner()
        for path in scanPaths {
            if Task.isCancelled { truncated = true; break }
            if inspected >= maxFiles { truncated = true; break }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"),
                  !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
                skip(path, because: .unsafePath)
                continue
            }
            let data: Data
            if let revision, let revisionFiles {
                // Snapshot sizes let us skip large blobs BEFORE spawning Git.
                if (revisionFiles[path] ?? Int.max) > maxBytes {
                    skip(path, because: .tooLarge)
                    continue
                }
                // Git does the path lookup in the immutable commit tree; this also
                // works for branches selected without checking them out. No shell.
                do {
                    data = try runner.run(["cat-file", "blob", "\(revision):\(path)"], at: rootURL)
                } catch is CancellationError {
                    truncated = true
                    break
                } catch {
                    skip(path, because: .unreadable)
                    continue
                }
            } else {
                // Compatibility for callers that explicitly request the local tree.
                let file = rootURL.appendingPathComponent(path)
                let info: URLResourceValues
                do {
                    info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                } catch {
                    let reason: DuplicateScanSkipReason = FileManager.default.fileExists(atPath: file.path)
                        ? .unreadable : .missing
                    skip(path, because: reason)
                    continue
                }
                if info.isSymbolicLink == true {
                    skip(path, because: .symlink)
                    continue
                }
                guard file.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else {
                    skip(path, because: .unsafePath)
                    continue
                }
                guard info.isRegularFile == true else {
                    skip(path, because: .notRegular)
                    continue
                }
                if (info.fileSize ?? Int.max) > maxBytes {
                    skip(path, because: .tooLarge)
                    continue
                }
                guard let fileData = try? Data(contentsOf: file) else {
                    skip(path, because: .unreadable)
                    continue
                }
                data = fileData
            }
            if data.count > maxBytes {
                skip(path, because: .tooLarge)
                continue
            }
            guard !data.contains(0), let source = String(data: data, encoding: .utf8) else {
                skip(path, because: .binary)
                continue
            }
            inspected += 1
            let lines = normalizedLines(source)
            guard lines.count >= window else { continue }
            let fileIndex = files.count
            files.append(IndexedFile(path: path, lines: lines))
            for start in 0...(lines.count - window) {
                if windows >= maxWindows || blocks.count >= maxCandidateBlocks {
                    truncated = true
                    break
                }
                windows += 1
                let signature = lines[start..<(start + window)].map(\.text).joined(separator: "\n")
                // Short boilerplate blocks do not provide useful refactoring evidence.
                if signature.count < max(140, window * 12) { continue }
                for previous in index[signature] ?? [] where previous.fileIndex != fileIndex {
                    let original = files[previous.fileIndex].lines
                    // Only record the earliest seed of a maximal block. This prevents a long
                    // duplicate being reported as dozens of shifted windows.
                    if previous.start > 0 && start > 0 &&
                        original[previous.start - 1].text == lines[start - 1].text { continue }
                    var count = window
                    while previous.start + count < original.count && start + count < lines.count &&
                            original[previous.start + count].text == lines[start + count].text {
                        count += 1
                    }
                    blocks.append(CandidateBlock(firstFile: previous.fileIndex, firstStart: previous.start,
                                                 secondFile: fileIndex, secondStart: start, count: count))
                    if blocks.count >= maxCandidateBlocks { truncated = true; break }
                }
                if truncated { break }
                if index[signature, default: []].count < 12 {
                    index[signature, default: []].append(Occurrence(fileIndex: fileIndex, start: start))
                }
            }
            if truncated { break }
        }

        // Keep longer blocks first. Remove duplicates that overlap on BOTH sides of a file pair;
        // the final 400-result limit applies after collapsing overlapping windows.
        blocks.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.firstFile != $1.firstFile { return $0.firstFile < $1.firstFile }
            if $0.secondFile != $1.secondFile { return $0.secondFile < $1.secondFile }
            if $0.firstStart != $1.firstStart { return $0.firstStart < $1.firstStart }
            return $0.secondStart < $1.secondStart
        }
        var accepted: [CandidateBlock] = []
        var matches: [DuplicateMatch] = []
        var groupBuilders: [GroupBuilder] = []
        var groupIndex: [String: Int] = [:]
        for block in blocks {
            let covered = accepted.contains { existing in
                existing.firstFile == block.firstFile && existing.secondFile == block.secondFile &&
                overlapping(existing.firstStart, existing.firstStart + existing.count - 1,
                            block.firstStart, block.firstStart + block.count - 1) &&
                overlapping(existing.secondStart, existing.secondStart + existing.count - 1,
                            block.secondStart, block.secondStart + block.count - 1)
            }
            if covered { continue }
            if matches.count >= maxMatches { truncated = true; break }
            accepted.append(block)
            let first = files[block.firstFile]
            let second = files[block.secondFile]
            let start1 = first.lines[block.firstStart].number
            let end1 = first.lines[block.firstStart + block.count - 1].number
            let start2 = second.lines[block.secondStart].number
            let end2 = second.lines[block.secondStart + block.count - 1].number
            matches.append(DuplicateMatch(firstPath: first.path, firstLine: start1, firstEndLine: end1,
                                          secondPath: second.path, secondLine: start2, secondEndLine: end2,
                                          lineCount: block.count,
                                          preview: first.lines[block.firstStart..<min(block.firstStart + 3, block.firstStart + block.count)].map(\.text).joined(separator: "\n")))
            // Pairs with identical *full* normalized content share one group.
            // Three identical files produce three pairs but only one unique block.
            let content = first.lines[block.firstStart..<(block.firstStart + block.count)]
                .map(\.text).joined(separator: "\n")
            let groupID: Int
            if let existing = groupIndex[content] { groupID = existing }
            else {
                groupID = groupBuilders.count
                groupIndex[content] = groupID
                groupBuilders.append(GroupBuilder(lineCount: block.count, preview: matches.last!.preview))
            }
            groupBuilders[groupID].insert(DuplicateLocation(path: first.path, startLine: start1,
                                                             endLine: end1, kind: fileKind(first.path)))
            groupBuilders[groupID].insert(DuplicateLocation(path: second.path, startLine: start2,
                                                             endLine: end2, kind: fileKind(second.path)))
        }
        let groups = groupBuilders.enumerated().map { index, builder in
            DuplicateGroup(id: index, locations: builder.locations.sorted { left, right in
                if left.path != right.path { return left.path < right.path }
                return left.startLine < right.startLine
            }, lineCount: builder.lineCount, preview: builder.preview)
        }

        // Do not score files with a single historical observation: a large initial import
        // should not automatically rank as a high-priority refactoring target.
        let threshold = max(1, minimumFileCommits)
        let sourceHotspots = metrics.hotspots.filter { hotspot in
            isScorableSource(hotspot.path) && (revisionPaths?.contains(hotspot.path) ?? true)
        }
        let eligibleHotspots = sourceHotspots.filter { $0.frequency >= threshold }
        let ownership = Dictionary(uniqueKeysWithValues: metrics.ownership.map { ($0.path, $0) })
        let unrankedCandidates = eligibleHotspots.map { hotspot -> RefactoringCandidate in
            let leader = ownership[hotspot.path]?.contributors.first
            return RefactoringCandidate(path: hotspot.path, kind: fileKind(hotspot.path), score: 0,
                                         frequency: hotspot.frequency, churn: hotspot.churn,
                                         duplicateOccurrences: 0,
                                         leadingAuthor: leader?.email, leadingAuthorShare: leader?.share ?? 0)
        }
        let report = CodeQualityReport(candidates: unrankedCandidates, duplicates: matches,
                                       duplicateGroups: groups, inspectedFiles: inspected,
                                       skippedFiles: skippedDetails.count,
                                       skippedDetails: skippedDetails,
                                       totalCandidateSourceFiles: scanPaths.count,
                                       truncated: truncated,
                                       excludedNonCodeFiles: (revisionFiles?.count ?? metrics.hotspots.count) -
                                           (revisionFiles?.keys.filter { isScorableSource($0) }.count ?? sourceHotspots.count),
                                       insufficientHistoryFiles: sourceHotspots.count - eligibleHotspots.count,
                                       minimumFileCommits: threshold,
                                       historicalOnlyPaths: historicalOnlyPaths,
                                       revisionBasedScan: revision != nil)
        // Keep the original report.candidates API meaningful for callers using all files.
        return CodeQualityReport(candidates: report.scopedCandidates(.all), duplicates: matches,
                                 duplicateGroups: groups, inspectedFiles: inspected,
                                 skippedFiles: skippedDetails.count,
                                 skippedDetails: skippedDetails,
                                 totalCandidateSourceFiles: scanPaths.count,
                                 truncated: truncated,
                                 excludedNonCodeFiles: report.excludedNonCodeFiles,
                                 insufficientHistoryFiles: report.insufficientHistoryFiles,
                                 minimumFileCommits: threshold,
                                 historicalOnlyPaths: historicalOnlyPaths,
                                 revisionBasedScan: revision != nil)
    }
}
