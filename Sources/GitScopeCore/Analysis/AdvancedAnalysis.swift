import Foundation

struct AdvancedAnalysis {
    struct Result {
        let contributors: [AuthorContribution]
        let ownership: [FileOwnership]
        let coupling: [CouplingPair]
        let directories: [DirectoryActivity]
        let limited: Bool
    }
    private struct Pair: Hashable { let first: String; let second: String }
    func contributors(_ commits: [Commit]) -> [AuthorContribution] {
        let groups = Dictionary(grouping: commits, by: { $0.email.lowercased() })
        let totalChurn = commits.reduce(0) { $0 + $1.changes.reduce(0) { $0 + ($1.additions ?? 0) + ($1.deletions ?? 0) } }
        return groups.map { email, events in
            let churn = events.reduce(0) { $0 + $1.changes.reduce(0) { $0 + ($1.additions ?? 0) + ($1.deletions ?? 0) } }
            return AuthorContribution(name: events[0].author, email: email, commits: events.count,
                               churn: churn, share: Double(events.count) / Double(max(1, commits.count)),
                               churnShare: totalChurn == 0 ? 0 : Double(churn) / Double(totalChurn))
        }.sorted { $0.commits == $1.commits ? $0.email < $1.email : $0.commits > $1.commits }
    }
    func compute(_ snapshot: RepositorySnapshot, options: AnalysisOptions) -> Result {
        var files: [String: [Commit]] = [:]
        var directoryCommits: [String: [Commit]] = [:]
        var directoryChurn: [String: Int] = [:]
        var pairs: [Pair: [Int]] = [:]
        var pairEvents = 0
        var limited = false
        for (commitIndex, commit) in snapshot.commits.enumerated() {
            let paths = Array(Set(commit.changes.map(\.path))).sorted()
            let grouped = Dictionary(grouping: commit.changes, by: \.path)
            for path in paths {
                // File ownership must use only this file's line changes, not the whole commit's churn.
                let local = grouped[path] ?? []
                files[path, default: []].append(Commit(id: commit.id, author: commit.author, email: commit.email, date: commit.date, subject: commit.subject, changes: local))
            }
            var directories = Set<String>()
            for change in commit.changes {
                let directory = change.path.contains("/") ? String(change.path.split(separator: "/", maxSplits: 1)[0]) : "(root)"
                directories.insert(directory)
                directoryChurn[directory, default: 0] += (change.additions ?? 0) + (change.deletions ?? 0)
            }
            for directory in directories { directoryCommits[directory, default: []].append(commit) }
            // Hard ceiling bounds pair enumeration even when the global bulk filter is disabled.
            if limited { continue }
            if paths.count > 100 { limited = true; pairs.removeAll(); continue }
            if paths.count > 1 {
                for a in 0..<(paths.count - 1) {
                    for b in (a + 1)..<paths.count {
                        let key = Pair(first: paths[a], second: paths[b])
                        if (pairs[key] == nil && pairs.count >= 100_000) || pairEvents >= 1_000_000 { limited = true; break }
                        pairs[key, default: []].append(commitIndex)
                        pairEvents += 1
                    }
                    if limited { break }
                }
                if limited { pairs.removeAll() }
            }
        }
        // Partial counts are not meaningful: suppress the entire coupling result on overflow.
        let coupling: [CouplingPair] = limited ? [] : pairs.compactMap { pair, events in
            let forward = Double(events.count) / Double(files[pair.first]!.count)
            let reverse = Double(events.count) / Double(files[pair.second]!.count)
            guard events.count >= max(1, options.minimumJointCommits), max(forward, reverse) >= options.minimumConfidence else { return nil }
            return CouplingPair(first: pair.first, second: pair.second, jointCommits: events.count,
                                support: Double(events.count) / Double(max(1, snapshot.commits.count)),
                                confidenceForward: forward, confidenceReverse: reverse, commits: events.map { snapshot.commits[$0] })
        }.sorted { left, right in
            if left.jointCommits != right.jointCommits { return left.jointCommits > right.jointCommits }
            return left.id < right.id
        }
        let ownership = files.map { path, commits in FileOwnership(path: path, contributors: contributors(commits)) }.sorted { $0.path < $1.path }
        var directories: [DirectoryActivity] = []
        for (path, commits) in directoryCommits {
            directories.append(DirectoryActivity(path: path, commits: commits.count, churn: directoryChurn[path, default: 0]))
        }
        directories.sort { left, right in
            if left.commits != right.commits { return left.commits > right.commits }
            return left.path < right.path
        }
        return Result(contributors: contributors(snapshot.commits), ownership: ownership, coupling: coupling, directories: directories, limited: limited)
    }
}
