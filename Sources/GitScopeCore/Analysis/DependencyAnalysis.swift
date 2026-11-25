import Foundation

/// Turns manifest revisions into version-change events, per-dependency histories and per-commit transitions.
/// History is computed on the complete raw snapshot; shared filters then select which events are shown.
struct DependencyAnalysis {
    struct FileHistory {
        let first: [String: Date]
        let last: [String: Date]
        /// Follows recorded renames, so a renamed file keeps the age of its oldest recorded path.
        init(_ commits: [Commit]) {
            var first: [String: Date] = [:], last: [String: Date] = [:]
            for commit in commits.reversed() {
                for change in commit.changes {
                    if let old = change.oldPath, let inherited = first[old] { first[change.path] = min(first[change.path] ?? inherited, inherited) }
                    if first[change.path] == nil { first[change.path] = commit.date }
                    last[change.path] = commit.date
                }
            }
            self.first = first; self.last = last
        }
    }

    func compute(_ raw: RepositorySnapshot, options: AnalysisOptions, index: ModuleIndex, scan: CodeScan?, history: FileHistory) -> DependencyInsights {
        let commits = Dictionary(raw.commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [DependencyChange] = []
        var latest: [String: DependencyDeclaration] = [:]
        // Each revision is compared with its own parent version, never with a neighbour by date.
        for revision in raw.manifests {
            let old = Dictionary((revision.previous ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let new = Dictionary(revision.declarations.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for (key, declaration) in new {
                latest[key] = latest[key] ?? declaration
                if let previous = old[key] {
                    if previous.version != declaration.version { events.append(event(revision, declaration, from: previous.version, to: declaration.version)) }
                } else {
                    events.append(event(revision, declaration, from: nil, to: declaration.version))
                }
            }
            for (key, previous) in old where new[key] == nil {
                latest[key] = latest[key] ?? previous
                events.append(event(revision, previous, from: previous.version, to: nil))
            }
        }
        var current: [String: [ManifestVersion]] = [:]
        for (path, declarations) in raw.currentManifests {
            for declaration in declarations {
                latest[declaration.key] = declaration
                current[declaration.key, default: []].append(ManifestVersion(path: path, version: declaration.version))
            }
        }
        events = collapseMoves(events)
        let usages = usagesByDependency(latest: latest, scan: scan, index: index, options: options)
        var summaries: [DependencySummary] = []
        let grouped = Dictionary(grouping: events, by: \.key)
        for key in Set(grouped.keys).union(current.keys) {
            let changes = (grouped[key] ?? []).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            let visible = changes.filter { visibleEvent($0, options: options, commits: commits) }
            let declaration = latest[key]!
            let paths = changes.map(\.path) + (current[key] ?? []).map(\.path)
            guard !visible.isEmpty || current[key] != nil, paths.contains(where: { options.includes(path: $0) }) else { continue }
            var seen = Set<String>()
            let versions = changes.flatMap { [$0.from, $0.to].compactMap { $0 } }.filter { !$0.isEmpty && seen.insert($0).inserted }
            let used = usages[key] ?? []
            let isCurrent = current[key] != nil
            let reference = changes.last { change in (!isCurrent && change.change == .removed) || (change.isMajor && change.change != .removed && change.change != .added) }
            let stale = reference.map { event in used.filter { !isCurrent || (history.last[$0.path] ?? .distantPast) < event.date } } ?? []
            summaries.append(DependencySummary(key: key, name: declaration.name, kind: declaration.kind, ecosystem: declaration.ecosystem,
                                               current: (current[key] ?? []).sorted { $0.path < $1.path }, firstSeen: changes.first?.date, lastChanged: changes.last?.date,
                                               distinctVersions: versions, changes: visible, usages: used, modulesUsing: Array(Set(used.map(\.module))).sorted(), staleUsages: stale,
                                               referenceChange: reference))
        }
        summaries.sort { left, right in
            if left.isCurrent != right.isCurrent { return left.isCurrent }
            if left.kind != right.kind { return DependencyKind.allCases.firstIndex(of: left.kind)! < DependencyKind.allCases.firstIndex(of: right.kind)! }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        let byKey = Dictionary(summaries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var transitions: [DependencyTransition] = []
        for (commitID, changes) in Dictionary(grouping: events.filter { visibleEvent($0, options: options, commits: commits) }, by: \.commit) {
            let commit = commits[commitID]
            let files = Array(Set((commit?.changes.map(\.path) ?? []) + changes.map(\.path))).sorted()
            var remaining = Set<DependencyUsage>()
            for change in changes {
                guard let summary = byKey[change.key] else { continue }
                if change.change == .removed && !summary.isCurrent { remaining.formUnion(summary.usages) }
                else if change.isMajor && change.change != .added && change.change != .removed {
                    remaining.formUnion(summary.usages.filter { (history.last[$0.path] ?? .distantPast) < change.date })
                }
            }
            transitions.append(DependencyTransition(commit: commitID, date: changes[0].date, subject: commit?.subject ?? "", author: commit?.author ?? "", email: commit?.email ?? "",
                                                    changes: changes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                                                    changedModules: Array(Set(files.map { index.module(for: $0).name })).sorted(), changedFiles: files,
                                                    remainingUsages: remaining.sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }))
        }
        transitions.sort { $0.date == $1.date ? $0.commit < $1.commit : $0.date > $1.date }
        let paths = raw.currentManifests.keys.filter { options.includes(path: $0) }.sorted()
        return DependencyInsights(summaries: summaries, transitions: transitions, manifestPaths: paths, warning: raw.manifestWarning)
    }

    private func event(_ revision: ManifestRevision, _ declaration: DependencyDeclaration, from: String?, to: String?) -> DependencyChange {
        let type: DependencyChangeType
        var major = false
        switch (from, to) {
        case (nil, _): type = .added
        case (_, nil): type = .removed; major = true
        case let (old?, new?):
            switch VersionOrdering.compare(old, new) {
            case .orderedAscending?: type = .upgraded
            case .orderedDescending?: type = .downgraded
            default: type = .changed
            }
            major = VersionOrdering.isMajorChange(old, new)
        }
        return DependencyChange(key: declaration.key, commit: revision.commit, date: revision.date, path: revision.path, name: declaration.name, kind: declaration.kind,
                                ecosystem: declaration.ecosystem, from: from, to: to, change: type, isMajor: major)
    }

    /// A manifest moved within one commit appears as a removal plus an addition; pair them into one change (or none).
    private func collapseMoves(_ events: [DependencyChange]) -> [DependencyChange] {
        var result: [DependencyChange] = []
        for (_, group) in Dictionary(grouping: events, by: { $0.commit + "\u{1}" + $0.key }) {
            var removals = group.filter { $0.change == .removed }
            var kept: [DependencyChange] = []
            for change in group where change.change != .removed {
                if change.change == .added, let pairIndex = removals.firstIndex(where: { $0.path != change.path }) {
                    let removed = removals.remove(at: pairIndex)
                    if removed.from != change.to {
                        let old = removed.from ?? "", new = change.to ?? ""
                        let order = VersionOrdering.compare(old, new)
                        kept.append(DependencyChange(key: change.key, commit: change.commit, date: change.date, path: change.path, name: change.name, kind: change.kind,
                                                     ecosystem: change.ecosystem, from: removed.from, to: change.to,
                                                     change: order == .orderedAscending ? .upgraded : order == .orderedDescending ? .downgraded : .changed,
                                                     isMajor: VersionOrdering.isMajorChange(old, new)))
                    }
                } else { kept.append(change) }
            }
            result += kept + removals
        }
        return result
    }

    private func visibleEvent(_ change: DependencyChange, options: AnalysisOptions, commits: [String: Commit]) -> Bool {
        if !options.includes(path: change.path) { return false }
        if let since = options.since, change.date < since { return false }
        if let until = options.until, change.date >= until { return false }
        if !options.authorQuery.isEmpty {
            guard let commit = commits[change.commit], (commit.author + " " + commit.email).localizedCaseInsensitiveContains(options.authorQuery) else { return false }
        }
        return true
    }

    private func usagesByDependency(latest: [String: DependencyDeclaration], scan: CodeScan?, index: ModuleIndex, options: AnalysisOptions) -> [String: [DependencyUsage]] {
        guard let scan else { return [:] }
        var result: [String: [DependencyUsage]] = [:]
        let candidates = latest.values.filter { $0.kind != .tool }.map(DependencyMatcher.Prepared.init)
        for reference in scan.imports where options.includes(path: reference.location.path) {
            let imported = DependencyMatcher.ImportedName(reference)
            for candidate in candidates where candidate.matches(imported) {
                result[candidate.declaration.key, default: []].append(DependencyUsage(path: reference.location.path, line: reference.location.line, text: reference.location.text,
                                                                                      module: index.module(for: reference.location.path).name))
            }
        }
        return result.mapValues { Array(Set($0)).sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path } }
    }
}

/// Heuristic, ecosystem-aware matching of an import statement to a declared dependency name.
/// It is an indication of probable usage, not a resolved build graph.
enum DependencyMatcher {
    static func normalized(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
    struct ImportedName {
        let ext: String
        let module: String
        let normalizedModule: String
        init(_ reference: ImportReference) {
            ext = RepoPath.fileExtension(reference.location.path)
            module = reference.module
            normalizedModule = DependencyMatcher.normalized(reference.module)
        }
    }
    struct Prepared {
        let declaration: DependencyDeclaration
        let lowerName: String
        let normalizedName: String
        let swiftStem: String
        init(_ declaration: DependencyDeclaration) {
            self.declaration = declaration
            lowerName = declaration.name.lowercased()
            normalizedName = DependencyMatcher.normalized(declaration.name)
            var stem = normalizedName
            if stem.count > 5 && stem.hasPrefix("swift") { stem.removeFirst(5) }
            swiftStem = stem
        }
        func matches(_ imported: ImportedName) -> Bool {
            let module = imported.module, name = declaration.name, ext = imported.ext
            switch declaration.ecosystem {
            case "SwiftPM", "CocoaPods", "Carthage":
                guard ["swift", "m", "mm", "h"].contains(ext) else { return false }
                let value = imported.normalizedModule
                return value == normalizedName || value == swiftStem || (swiftStem.count >= 3 && value.hasPrefix(swiftStem))
            case "npm":
                guard ["js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte"].contains(ext) else { return false }
                let parts = module.split(separator: "/")
                let package = module.hasPrefix("@") && parts.count >= 2 ? parts[0] + "/" + parts[1] : String(parts.first ?? "")
                return package.lowercased() == lowerName
            case "pip":
                return ext == "py" && DependencyMatcher.normalized(String(module.split(separator: ".").first ?? "")) == normalizedName
            case "Go modules":
                return ext == "go" && (module == name || module.hasPrefix(name + "/"))
            case "Cargo":
                return ext == "rs" && module == name.replacingOccurrences(of: "-", with: "_")
            case "RubyGems":
                return ext == "rb" && (module == name || module.hasPrefix(name + "/"))
            case "Gradle", "Maven":
                guard ["java", "kt", "kts", "scala", "groovy"].contains(ext), let group = name.split(separator: ":").first, group.split(separator: ".").count >= 2 else { return false }
                return module.hasPrefix(group + ".")
            case "NuGet":
                return ext == "cs" && (module == name || module.hasPrefix(name + "."))
            default:
                return false
            }
        }
    }
}
