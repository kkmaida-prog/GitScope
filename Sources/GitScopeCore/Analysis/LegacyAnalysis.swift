import Foundation

/// Builds legacy findings. Every finding starts with one concrete signal (a matched rule, a removed or
/// upgraded dependency, or a path name); history and file age are attached as supporting signals.
struct LegacyAnalysis {
    static let legacyWords = ["legacy", "deprecated", "obsolete"]

    func compute(raw: RepositorySnapshot, filtered: RepositorySnapshot, options: AnalysisOptions, scan: CodeScan?, dependencies: DependencyInsights,
                 index: ModuleIndex, history: DependencyAnalysis.FileHistory, now: Date = Date()) -> LegacyInsights {
        var touching: [String: [Commit]] = [:]
        for commit in filtered.commits {
            for path in Set(commit.changes.map(\.path)) { touching[path, default: []].append(commit) }
        }
        let ageThreshold = Self.ageThreshold(paths: Array(raw.fileSizes.keys), history: history, now: now)
        var findings: [LegacyFinding] = []
        func add(_ key: String, _ path: String, _ location: CodeLine?, _ signals: [LegacySignal], base: Int) {
            guard options.includes(path: path), !ManifestCatalog.isVendored(path) else { return }
            var all = signals, score = base
            if let first = history.first[path], now.timeIntervalSince(first) >= ageThreshold {
                all.append(LegacySignal(kind: .fileAge, detail: Self.ageDetail(first: first, last: history.last[path], now: now)))
                score += 2
            }
            if all.contains(where: { $0.kind == .changingAfterMigration }) { score += 3 }
            findings.append(LegacyFinding(key: key, path: path, line: location?.line, text: location?.text, module: index.module(for: path).name, signals: all,
                                          firstSeen: history.first[path], lastChanged: history.last[path], commits: touching[path] ?? [], score: score))
        }
        func churn(after date: Date, path: String, migration: String) -> LegacySignal? {
            let later = (touching[path] ?? []).filter { $0.date > date }
            guard !later.isEmpty else { return nil }
            return LegacySignal(kind: .changingAfterMigration, detail: "Changed in \(later.count) eligible commit\(later.count == 1 ? "" : "s") since \(migration) on \(Self.day(date)); the old usage is still here.")
        }
        if let scan {
            let rules = Dictionary(scan.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for match in scan.matches {
                guard let rule = rules[match.ruleID] else { continue }
                var signals: [LegacySignal] = []
                switch rule.category {
                case .deprecatedAPI:
                    var detail = "Uses \(rule.title)" + (rule.replacement.map { "; replace with \($0)" } ?? "") + "."
                    if !rule.note.isEmpty { detail += " " + rule.note }
                    if let start = scan.migrationStarts[rule.id] { detail += " Migration to \(rule.replacement ?? "the replacement") began on \(Self.day(start.date)) in \(start.commit.prefix(10))." }
                    signals.append(LegacySignal(kind: .deprecatedAPI, detail: detail))
                    if let start = scan.migrationStarts[rule.id],
                       let signal = churn(after: start.date, path: match.location.path, migration: "the migration to \(rule.replacement ?? "the replacement") began") { signals.append(signal) }
                case .deprecationMarker: signals.append(LegacySignal(kind: .deprecationMarker, detail: rule.note))
                case .legacyMarker: signals.append(LegacySignal(kind: .legacyMarker, detail: rule.note))
                }
                let base = rule.category == .deprecatedAPI ? 4 : rule.category == .deprecationMarker ? 2 : 1
                add("rule." + rule.id, match.location.path, match.location, signals, base: base)
            }
        }
        for summary in dependencies.summaries {
            if !summary.isCurrent, let removal = summary.referenceChange {
                for usage in summary.usages {
                    var signals = [LegacySignal(kind: .removedDependency, detail: "Imports \(summary.name), which was removed from \(removal.path) on \(Self.day(removal.date)) in \(removal.commit.prefix(10)). The code may rely on a vendored copy, a transitive dependency or dead code.")]
                    if let signal = churn(after: removal.date, path: usage.path, migration: "\(summary.name) was removed") { signals.append(signal) }
                    add("removed." + summary.key, usage.path, CodeLine(path: usage.path, line: usage.line, text: usage.text), signals, base: 5)
                }
            } else if summary.isCurrent, let upgrade = summary.referenceChange {
                for usage in summary.staleUsages {
                    let detail = "Imports \(summary.name), but this file has not changed since \(summary.name) moved from \(upgrade.from ?? "?") to \(upgrade.to ?? "?") on \(Self.day(upgrade.date)) (\(upgrade.commit.prefix(10))). Review it for APIs from the old major version."
                    add("upgrade." + summary.key, usage.path, CodeLine(path: usage.path, line: usage.line, text: usage.text), [LegacySignal(kind: .notRevisitedAfterUpgrade, detail: detail)], base: 3)
                }
            }
        }
        for path in raw.fileSizes.keys {
            let components = path.lowercased().split(separator: "/").map { String($0) }
            let stems = components.dropLast().map { $0 } + [RepoPath.stem(components.last ?? "")]
            guard let word = stems.lazy.compactMap({ stem in stem == "old" ? "old" : Self.legacyWords.first { stem.contains($0) } }).first else { continue }
            add("path", path, nil, [LegacySignal(kind: .legacyPath, detail: "The path contains “\(word)”, which usually marks code kept for compatibility or awaiting removal.")], base: 1)
        }
        findings.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.path != right.path { return left.path.localizedStandardCompare(right.path) == .orderedAscending }
            return (left.line ?? 0) < (right.line ?? 0)
        }
        var warnings = scan?.warnings ?? []
        if scan == nil { warnings.append("The code scan has not run yet; only path-name signals are shown.") }
        return LegacyInsights(findings: findings, scanned: scan != nil, warnings: warnings)
    }

    /// Old means at least one year and within the oldest quarter of files present at the selected revision.
    static func ageThreshold(paths: [String], history: DependencyAnalysis.FileHistory, now: Date) -> TimeInterval {
        let ages = paths.compactMap { history.first[$0].map { now.timeIntervalSince($0) } }.sorted()
        let year: TimeInterval = 365 * 86_400
        guard !ages.isEmpty else { return year }
        return max(year, ages[min(ages.count - 1, Int(Double(ages.count) * 0.75))])
    }
    static func ageDetail(first: Date, last: Date?, now: Date) -> String {
        let years = now.timeIntervalSince(first) / (365.25 * 86_400)
        var text = "First recorded \(String(format: "%.1f", years)) years ago (\(day(first)))"
        if let last { text += "; last changed \(day(last))" }
        return text + ". Among the oldest files at this revision."
    }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// UTC calendar day, matching the rest of GitScope's date policy.
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}
