import Foundation
import Darwin

public struct AnalysisOptions: Codable, Equatable, Sendable {
    public var since: Date?
    /// Exclusive upper bound, independent of the UI's inclusive day picker.
    public var until: Date?
    public var authorQuery = ""
    public var pathQuery = ""
    public var fileExtension = ""
    public var excludedPatterns: [String] = []
    /// Commits larger than this are excluded before path filtering. Zero disables the rule.
    public var maximumFilesPerCommit = 50
    public var minimumJointCommits = 2
    public var minimumConfidence = 0.2
    public init() {}
    public func includes(path: String) -> Bool {
        if !pathQuery.isEmpty && !path.localizedCaseInsensitiveContains(pathQuery) { return false }
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !suffix.isEmpty && !(path as NSString).pathExtension.caseInsensitiveCompare(suffix).isOrderedSame { return false }
        return !excludedPatterns.contains { fnmatch($0, path, 0) == 0 }
    }
    public func apply(to snapshot: RepositorySnapshot) -> RepositorySnapshot {
        let scoped = !pathQuery.isEmpty || !fileExtension.isEmpty || !excludedPatterns.isEmpty
        let commits = snapshot.commits.compactMap { commit -> Commit? in
            if let since, commit.date < since { return nil }
            if let until, commit.date >= until { return nil }
            if !authorQuery.isEmpty && !(commit.author + " " + commit.email).localizedCaseInsensitiveContains(authorQuery) { return nil }
            if maximumFilesPerCommit > 0 && Set(commit.changes.map(\.path)).count > maximumFilesPerCommit { return nil }
            let changes = commit.changes.filter { includes(path: $0.path) }
            if changes.isEmpty && (!commit.changes.isEmpty || scoped) { return nil }
            return Commit(id: commit.id, author: commit.author, email: commit.email, date: commit.date, subject: commit.subject, changes: changes)
        }
        return RepositorySnapshot(root: snapshot.root, head: snapshot.head, shallow: snapshot.shallow, commits: commits,
                                  fileSizes: snapshot.fileSizes.filter { includes(path: $0.key) }, reference: snapshot.reference,
                                  branches: snapshot.branches, importMode: snapshot.importMode, importedCommits: snapshot.importedCommits)
    }
}
private extension ComparisonResult {
    var isOrderedSame: Bool { self == .orderedSame }
}
public struct AuthorContribution: Identifiable, Sendable {
    public var id: String { email }
    public let name: String
    public let email: String
    public let commits: Int
    public let churn: Int
    public let share: Double
    public let churnShare: Double
}
public struct FileOwnership: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let contributors: [AuthorContribution]
}
public struct CouplingPair: Identifiable, Sendable {
    public var id: String { first + "\0" + second }
    public let first: String
    public let second: String
    public let jointCommits: Int
    public let support: Double
    public let confidenceForward: Double
    public let confidenceReverse: Double
    public let commits: [Commit]
}
public struct DirectoryActivity: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let commits: Int
    public let churn: Int
}
public enum ImportMode: String, Codable, Sendable {
    case fresh = "Full import"
    case cached = "Cache hit"
    case incremental = "Incremental import"
}
