import Foundation

/// Maps paths to modules. A module is a folder with a recognised project manifest at the selected revision;
/// a Swift package additionally contributes one module per `Sources/<Target>`, `Tests/<Target>` and `Plugins/<Target>` folder.
/// Each path belongs to the deepest module whose folder contains it.
public struct ModuleIndex: Sendable {
    public struct Module: Sendable, Hashable {
        public let name: String
        public let root: String
        public let kinds: [String]
        public let manifests: [String]
    }
    public let modules: [Module]
    private let byDepth: [Module]

    public init(currentPaths: [String], repositoryName: String) {
        var kinds: [String: [String]] = [:], manifests: [String: [String]] = [:]
        var swiftPackages: [String] = []
        for path in currentPaths {
            guard let format = ManifestCatalog.format(for: path), format.marksModule else { continue }
            let root = ManifestCatalog.moduleRoot(for: path, format: format)
            if !(kinds[root]?.contains(format.moduleKind) ?? false) { kinds[root, default: []].append(format.moduleKind) }
            manifests[root, default: []].append(path)
            if format == .swiftPackage { swiftPackages.append(root) }
        }
        var targets: [String: String] = [:]
        // SwiftPM's default layout; a folder counts as a target only if it contains compilable sources
        // (so resource or test-plan folders under Tests/ are not mistaken for targets).
        let compiled: Set<String> = ["swift", "c", "cc", "cpp", "m", "mm"]
        for package in swiftPackages {
            let base = package.isEmpty ? "" : package + "/"
            for path in currentPaths where path.hasPrefix(base) && compiled.contains(RepoPath.fileExtension(path)) {
                let parts = path.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count >= 3, ["Sources", "Tests", "Plugins"].contains(String(parts[0])) else { continue }
                targets[base + parts[0] + "/" + parts[1]] = parts[0] == "Tests" ? "Swift test target" : parts[0] == "Plugins" ? "Swift package plugin" : "Swift target"
            }
        }
        var modules = kinds.map { root, kinds in
            Module(name: root.isEmpty ? repositoryName : RepoPath.name(root), root: root, kinds: kinds.sorted(), manifests: manifests[root, default: []].sorted())
        }
        for (root, kind) in targets where kinds[root] == nil {
            modules.append(Module(name: RepoPath.name(root), root: root, kinds: [kind], manifests: []))
        }
        if !modules.contains(where: { $0.root.isEmpty }) { modules.append(Module(name: repositoryName, root: "", kinds: ["Repository"], manifests: [])) }
        self.modules = modules.sorted { $0.root == $1.root ? $0.name < $1.name : $0.root < $1.root }
        byDepth = modules.sorted { $0.root.count > $1.root.count }
    }
    public func module(for path: String) -> Module {
        byDepth.first { $0.root.isEmpty || path == $0.root || path.hasPrefix($0.root + "/") }!
    }
}

/// Aggregates the filtered history and the selected revision by every folder level and by module.
struct RepositoryStructureAnalysis {
    private final class Aggregate {
        var commits = Set<Int>()
        var recent: [Int] = []
        var churn = 0
        var authors: [String: (name: String, commits: Set<Int>, churn: Int)] = [:]
        var first: Date?, last: Date?
        var currentFiles = 0, bytes = 0, findings = 0
        func add(commit index: Int, _ commit: Commit, churn change: Int) {
            if commits.insert(index).inserted {
                if recent.count < 40 { recent.append(index) }
                first = min(first ?? commit.date, commit.date); last = max(last ?? commit.date, commit.date)
            }
            churn += change
            let email = commit.email.lowercased()
            var author = authors[email] ?? (commit.author, [], 0)
            author.commits.insert(index); author.churn += change
            authors[email] = author
        }
        func contributors() -> [AuthorContribution] {
            let total = commits.count
            return authors.map { email, value in
                AuthorContribution(name: value.name, email: email, commits: value.commits.count, churn: value.churn,
                                   share: Double(value.commits.count) / Double(max(1, total)), churnShare: churn == 0 ? 0 : Double(value.churn) / Double(churn))
            }.sorted { $0.commits == $1.commits ? $0.email < $1.email : $0.commits > $1.commits }
        }
    }

    static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        var result = [""], current = ""
        for part in parts { current = current.isEmpty ? String(part) : current + "/" + part; result.append(current) }
        return result
    }

    func compute(_ snapshot: RepositorySnapshot, index: ModuleIndex, findings: [LegacyFinding], dependencies: DependencyInsights) -> RepositoryStructure {
        var folders: [String: Aggregate] = [:]
        var modules: [ModuleIndex.Module: Aggregate] = [:]
        var directFiles: [String: [String]] = [:]
        func folder(_ path: String) -> Aggregate { if let existing = folders[path] { return existing }; let created = Aggregate(); folders[path] = created; return created }
        func module(_ value: ModuleIndex.Module) -> Aggregate { if let existing = modules[value] { return existing }; let created = Aggregate(); modules[value] = created; return created }
        for value in index.modules { _ = module(value) }
        for (path, size) in snapshot.fileSizes {
            for ancestor in Self.ancestors(of: path) { let aggregate = folder(ancestor); aggregate.currentFiles += 1; aggregate.bytes += size }
            directFiles[RepoPath.parent(path), default: []].append(path)
            let owner = module(index.module(for: path)); owner.currentFiles += 1; owner.bytes += size
        }
        for (commitIndex, commit) in snapshot.commits.enumerated() {
            var folderChurn: [String: Int] = [:], moduleChurn: [ModuleIndex.Module: Int] = [:]
            for change in commit.changes {
                let lines = (change.additions ?? 0) + (change.deletions ?? 0)
                for ancestor in Self.ancestors(of: change.path) { folderChurn[ancestor, default: 0] += lines }
                moduleChurn[index.module(for: change.path), default: 0] += lines
            }
            // Count a commit once per folder/module while summing only that scope's churn.
            for (path, lines) in folderChurn { folder(path).add(commit: commitIndex, commit, churn: lines) }
            for (value, lines) in moduleChurn { module(value).add(commit: commitIndex, commit, churn: lines) }
        }
        for finding in findings {
            for ancestor in Self.ancestors(of: finding.path) { folder(ancestor).findings += 1 }
            module(index.module(for: finding.path)).findings += 1
        }
        if folders[""] == nil { _ = folder("") }
        var children: [String: [String]] = [:]
        for path in folders.keys where !path.isEmpty {
            let parent = RepoPath.parent(path)
            children[parent, default: []].append(path)
        }
        var summaries: [String: FolderSummary] = [:]
        for (path, aggregate) in folders {
            summaries[path] = FolderSummary(path: path, name: path.isEmpty ? snapshot.root.lastPathComponent : RepoPath.name(path),
                                            parent: path.isEmpty ? nil : RepoPath.parent(path),
                                            subfolders: (children[path] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                                            files: (directFiles[path] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                                            currentFiles: aggregate.currentFiles, bytes: aggregate.bytes, commits: aggregate.commits.count, churn: aggregate.churn,
                                            contributors: aggregate.contributors(), firstChange: aggregate.first, lastChange: aggregate.last,
                                            findings: aggregate.findings, recentCommits: aggregate.recent.map { snapshot.commits[$0] })
        }
        var declarations: [String: [DependencyDeclaration]] = [:]
        for summary in dependencies.summaries {
            for version in summary.current {
                let root: String
                if let format = ManifestCatalog.format(for: version.path) { root = ManifestCatalog.moduleRoot(for: version.path, format: format) }
                else { root = RepoPath.parent(version.path) }
                declarations[root, default: []].append(DependencyDeclaration(name: summary.name, version: version.version, kind: summary.kind, ecosystem: summary.ecosystem))
            }
        }
        var moduleSummaries: [ModuleSummary] = []
        for (value, aggregate) in modules {
            let declared: [DependencyDeclaration] = value.manifests.isEmpty ? [] : ManifestParser.merge(declarations[value.root] ?? [])
            moduleSummaries.append(ModuleSummary(name: value.name, root: value.root, kinds: value.kinds, manifests: value.manifests,
                                                 currentFiles: aggregate.currentFiles, bytes: aggregate.bytes, commits: aggregate.commits.count, churn: aggregate.churn,
                                                 contributors: aggregate.contributors(), lastChange: aggregate.last, findings: aggregate.findings, dependencies: declared))
        }
        moduleSummaries.sort { $0.commits == $1.commits ? $0.root < $1.root : $0.commits > $1.commits }
        return RepositoryStructure(folders: summaries, modules: moduleSummaries)
    }
}
