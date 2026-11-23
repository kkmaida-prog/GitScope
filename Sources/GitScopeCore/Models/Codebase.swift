import Foundation

/// Git paths are always `/`-separated and repository-relative. These helpers avoid NSString path APIs,
/// which normalise paths (tilde, trailing slashes) in ways that do not apply to Git paths.
public enum RepoPath {
    /// Parent folder, or the empty string for a top-level path.
    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
    public static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
    /// Lowercased extension without the dot; empty for none and for dot-files such as `.nvmrc`.
    public static func fileExtension(_ path: String) -> String {
        let file = name(path)
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return "" }
        return file[file.index(after: dot)...].lowercased()
    }
    public static func stem(_ path: String) -> String {
        let file = name(path)
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
        return String(file[..<dot])
    }
}

// MARK: - Dependency and tool declarations

public enum DependencyKind: String, Codable, Sendable, CaseIterable {
    case library = "Library"
    case framework = "Framework"
    /// Build tools, toolchains, language versions, platform targets and base images.
    case tool = "Tool"
}

/// One dependency or tool exactly as a manifest declared it at one revision.
public struct DependencyDeclaration: Codable, Sendable, Hashable {
    public let name: String
    /// The declared requirement or resolved version; empty when the manifest gives none.
    public let version: String
    public let kind: DependencyKind
    public let ecosystem: String
    public init(name: String, version: String, kind: DependencyKind, ecosystem: String) {
        self.name = name; self.version = version; self.kind = kind; self.ecosystem = ecosystem
    }
    /// Identity across revisions and manifests. Names compare case-insensitively.
    public var key: String { ecosystem + "\u{1}" + kind.rawValue + "\u{1}" + name.lowercased() }
}

/// One commit's change to one recognised manifest: the parsed content before and after that commit.
/// Comparing each commit with its own parent keeps events correct on non-linear histories,
/// where ordering revisions by date would interleave unrelated branches.
public struct ManifestRevision: Codable, Sendable, Equatable {
    public let commit: String
    public let date: Date
    public let path: String
    public let deleted: Bool
    public let declarations: [DependencyDeclaration]
    /// Declarations in the parent commit's version of the file; nil when the commit created the file.
    public let previous: [DependencyDeclaration]?
    public init(commit: String, date: Date, path: String, deleted: Bool, declarations: [DependencyDeclaration], previous: [DependencyDeclaration]?) {
        self.commit = commit; self.date = date; self.path = path; self.deleted = deleted; self.declarations = declarations; self.previous = previous
    }
}

public enum DependencyChangeType: String, Sendable {
    case added = "Added", removed = "Removed", upgraded = "Upgraded", downgraded = "Downgraded", changed = "Changed"
}

public struct DependencyChange: Identifiable, Sendable {
    public var id: String { commit + "\u{1}" + path + "\u{1}" + key }
    public let key: String
    public let commit: String
    public let date: Date
    public let path: String
    public let name: String
    public let kind: DependencyKind
    public let ecosystem: String
    public let from: String?
    public let to: String?
    public let change: DependencyChangeType
    /// A different major version (or minor version for 0.x), or a replacement/removal.
    public let isMajor: Bool
    public var summary: String {
        switch change {
        case .added: return "\(name) added" + (to.map { $0.isEmpty ? "" : " at \($0)" } ?? "")
        case .removed: return "\(name) removed" + (from.map { $0.isEmpty ? "" : " (was \($0))" } ?? "")
        default: return "\(name) \(display(from)) → \(display(to))"
        }
    }
    private func display(_ value: String?) -> String { (value ?? "").isEmpty ? "unspecified" : value! }
}

/// A source line that probably uses a dependency, found by import-name matching at the selected revision.
public struct DependencyUsage: Identifiable, Sendable, Hashable {
    public var id: String { path + ":\(line)" }
    public let path: String
    public let line: Int
    public let text: String
    public let module: String
}

/// A commit that changed at least one dependency or tool declaration.
public struct DependencyTransition: Identifiable, Sendable {
    public var id: String { commit }
    public let commit: String
    public let date: Date
    public let subject: String
    public let author: String
    public let email: String
    public let changes: [DependencyChange]
    /// Modules containing the manifests and every other file changed by the same commit.
    public let changedModules: [String]
    public let changedFiles: [String]
    /// Usages that still reference a removed dependency, or a major-upgraded dependency from files untouched since.
    public let remainingUsages: [DependencyUsage]
}

public struct DependencySummary: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let kind: DependencyKind
    public let ecosystem: String
    /// Current declaration per manifest path at the selected revision. Empty when no longer declared.
    public let current: [ManifestVersion]
    /// Dates of the first and latest recorded change; nil when the history holds no change (for example a shallow clone).
    public let firstSeen: Date?
    public let lastChanged: Date?
    public let distinctVersions: [String]
    public let changes: [DependencyChange]
    public let usages: [DependencyUsage]
    public let modulesUsing: [String]
    /// Usage files whose last change predates the latest major upgrade or the removal.
    public let staleUsages: [DependencyUsage]
    /// The event `staleUsages` are measured against: the removal (when no longer declared) or the latest major version change.
    /// Taken from the complete history, so it is available even when shared filters hide the event itself.
    public let referenceChange: DependencyChange?
    public var isCurrent: Bool { !current.isEmpty }
    public var currentVersion: String {
        let versions = Array(Set(current.map(\.version).filter { !$0.isEmpty })).sorted()
        return versions.isEmpty ? (isCurrent ? "unspecified" : "removed") : versions.joined(separator: " · ")
    }
}
public struct ManifestVersion: Sendable, Hashable {
    public let path: String
    public let version: String
}

public struct DependencyInsights: Sendable {
    public let summaries: [DependencySummary]
    public let transitions: [DependencyTransition]
    public let manifestPaths: [String]
    public let warning: String?
    public static let empty = DependencyInsights(summaries: [], transitions: [], manifestPaths: [], warning: nil)
}

// MARK: - Repository structure

public struct FolderSummary: Identifiable, Sendable {
    public var id: String { path }
    /// Repository-relative folder path; the empty string is the repository root.
    public let path: String
    public let name: String
    public let parent: String?
    public let subfolders: [String]
    /// Files directly in this folder that exist at the selected revision (after path filters).
    public let files: [String]
    public let currentFiles: Int
    public let bytes: Int
    public let commits: Int
    public let churn: Int
    public let contributors: [AuthorContribution]
    public let firstChange: Date?
    public let lastChange: Date?
    public let findings: Int
    public let recentCommits: [Commit]
    public var leader: AuthorContribution? { contributors.first }
}

public struct ModuleSummary: Identifiable, Sendable {
    public var id: String { root + "\u{1}" + name }
    public let name: String
    /// Folder that contains the module; the empty string is the repository root.
    public let root: String
    public let kinds: [String]
    public let manifests: [String]
    public let currentFiles: Int
    public let bytes: Int
    public let commits: Int
    public let churn: Int
    public let contributors: [AuthorContribution]
    public let lastChange: Date?
    public let findings: Int
    public let dependencies: [DependencyDeclaration]
}

public struct RepositoryStructure: Sendable {
    public let folders: [String: FolderSummary]
    public let modules: [ModuleSummary]
    public static let empty = RepositoryStructure(folders: [:], modules: [])
    public var root: FolderSummary? { folders[""] }
}

// MARK: - Legacy rules and code scan

public enum LegacyRuleCategory: String, Codable, Sendable {
    case deprecatedAPI = "Deprecated API"
    case deprecationMarker = "Deprecated declaration"
    case legacyMarker = "Legacy marker"
}

/// A detection rule. `keywords` are literal substrings used to prefilter with `git grep -F`;
/// `pattern` (NSRegularExpression) confirms each candidate line.
public struct LegacyRule: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var category: LegacyRuleCategory
    public var keywords: [String]
    public var pattern: String
    public var caseInsensitive: Bool
    /// Human-readable replacement, e.g. "WKWebView".
    public var replacement: String?
    /// Literal text whose first appearance marks the start of a migration.
    public var replacementKeyword: String?
    /// Lowercased file extensions without dots; empty applies to every scanned source file.
    public var extensions: [String]
    public var note: String
    public var builtIn: Bool
    public init(id: String, title: String, category: LegacyRuleCategory, keywords: [String], pattern: String, caseInsensitive: Bool = false,
                replacement: String? = nil, replacementKeyword: String? = nil, extensions: [String] = [], note: String = "", builtIn: Bool = false) {
        self.id = id; self.title = title; self.category = category; self.keywords = keywords; self.pattern = pattern
        self.caseInsensitive = caseInsensitive; self.replacement = replacement; self.replacementKeyword = replacementKeyword
        self.extensions = extensions; self.note = note; self.builtIn = builtIn
    }
    /// A user rule matching a literal identifier or call, optionally with the literal that replaces it.
    public static func custom(old: String, replacement: String?, extensions: [String] = []) -> LegacyRule {
        let trimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LegacyRule(id: "custom." + trimmed, title: trimmed, category: .deprecatedAPI, keywords: [trimmed],
                          pattern: NSRegularExpression.escapedPattern(for: trimmed), replacement: (new?.isEmpty ?? true) ? nil : new,
                          replacementKeyword: (new?.isEmpty ?? true) ? nil : new,
                          extensions: extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty },
                          note: "Custom rule for this repository")
    }
    public func applies(to path: String) -> Bool {
        extensions.isEmpty || extensions.contains(RepoPath.fileExtension(path))
    }
}

/// Per-repository rule choices, stored outside the repository.
public struct LegacyRuleSettings: Codable, Equatable, Sendable {
    public var disabledBuiltIns: [String] = []
    public var custom: [LegacyRule] = []
    public init() {}
    public var effectiveRules: [LegacyRule] {
        LegacyRules.builtIn.filter { !disabledBuiltIns.contains($0.id) } + custom
    }
}

public struct CodeLine: Sendable, Hashable, Codable {
    public let path: String
    public let line: Int
    public let text: String
    public init(path: String, line: Int, text: String) { self.path = path; self.line = line; self.text = text }
}
public struct RuleMatch: Sendable, Hashable {
    public let ruleID: String
    public let location: CodeLine
}
public struct ImportReference: Sendable, Hashable {
    public let module: String
    public let location: CodeLine
}
public struct MigrationStart: Sendable, Hashable {
    public let ruleID: String
    public let commit: String
    public let date: Date
}

/// Raw evidence read from the selected revision. Interpretation happens in pure analysis.
public struct CodeScan: Sendable {
    public let head: String
    public let rules: [LegacyRule]
    public let matches: [RuleMatch]
    public let imports: [ImportReference]
    public let migrationStarts: [String: MigrationStart]
    public let warnings: [String]
    public init(head: String, rules: [LegacyRule], matches: [RuleMatch], imports: [ImportReference], migrationStarts: [String: MigrationStart], warnings: [String]) {
        self.head = head; self.rules = rules; self.matches = matches; self.imports = imports; self.migrationStarts = migrationStarts; self.warnings = warnings
    }
}

// MARK: - Legacy findings

public enum LegacySignalKind: String, Sendable, CaseIterable {
    case deprecatedAPI = "Deprecated API"
    case removedDependency = "Removed dependency still imported"
    case changingAfterMigration = "Still changing after migration"
    case notRevisitedAfterUpgrade = "Not revisited after upgrade"
    case deprecationMarker = "Deprecated declaration"
    case legacyMarker = "Legacy marker"
    case legacyPath = "Legacy path name"
    case fileAge = "Old file"
}

public struct LegacySignal: Sendable, Hashable {
    public let kind: LegacySignalKind
    public let detail: String
}

public struct LegacyFinding: Identifiable, Sendable {
    public var id: String { path + "\u{1}\(line ?? 0)\u{1}" + key }
    let key: String
    public let path: String
    public let line: Int?
    public let text: String?
    public let module: String
    /// The first signal is the primary evidence; the remainder are supporting signals.
    public let signals: [LegacySignal]
    public let firstSeen: Date?
    public let lastChanged: Date?
    /// Eligible commits that touched the file, newest first.
    public let commits: [Commit]
    public let score: Int
    public var primary: LegacySignal { signals[0] }
}

public struct LegacyInsights: Sendable {
    public let findings: [LegacyFinding]
    public let scanned: Bool
    public let warnings: [String]
    public static let empty = LegacyInsights(findings: [], scanned: false, warnings: [])
    public func count(_ kind: LegacySignalKind) -> Int { findings.filter { $0.signals.contains { $0.kind == kind } }.count }
}

// MARK: - On-demand line evidence

public struct BlameLine: Sendable, Hashable {
    public let commit: String
    public let author: String
    public let email: String
    public let date: Date
    public let summary: String
}
public struct CodeContext: Sendable {
    public let lines: [CodeLine]
    public let blame: BlameLine?
}
