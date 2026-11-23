import Foundation

public struct AnalysisEngine {
    public init() {}
    /// `scan` carries line-level evidence from the selected revision. Without it, structure and dependency
    /// history are still computed; usages and rule-based legacy findings are empty.
    public func compute(_ rawSnapshot: RepositorySnapshot, options: AnalysisOptions = AnalysisOptions(), scan: CodeScan? = nil) -> RepositoryMetrics {
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
        // A scan from another revision would place lines in the wrong files; ignore it.
        let currentScan = scan?.head == rawSnapshot.head ? scan : nil
        let index = ModuleIndex(currentPaths: Array(rawSnapshot.fileSizes.keys), repositoryName: rawSnapshot.root.lastPathComponent)
        let history = DependencyAnalysis.FileHistory(rawSnapshot.commits)
        let dependencies = DependencyAnalysis().compute(rawSnapshot, options: options, index: index, scan: currentScan, history: history)
        let legacy = LegacyAnalysis().compute(raw: rawSnapshot, filtered: snapshot, options: options, scan: currentScan, dependencies: dependencies, index: index, history: history)
        let structure = RepositoryStructureAnalysis().compute(snapshot, index: index, findings: legacy.findings, dependencies: dependencies)
        return RepositoryMetrics(commits: snapshot.commits.count, authors: Set(snapshot.commits.map { $0.email.lowercased() }).count, additions: hotspots.reduce(0) { $0 + $1.additions }, deletions: hotspots.reduce(0) { $0 + $1.deletions }, binaryChanges: hotspots.reduce(0) { $0 + $1.binaryChanges }, hotspots: hotspots, activity: activity, contributors: advanced.contributors, ownership: advanced.ownership,
                                 coupling: advanced.coupling, directories: advanced.directories, couplingLimited: advanced.limited,
                                 excludedCommits: rawSnapshot.commits.count - snapshot.commits.count, currentFileCount: snapshot.fileSizes.count,
                                 structure: structure, dependencies: dependencies, legacy: legacy)
    }
}
