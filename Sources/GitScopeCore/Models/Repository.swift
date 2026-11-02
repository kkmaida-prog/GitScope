import Foundation

public struct FileChange: Sendable, Equatable, Codable {
    public let path: String
    public let oldPath: String?
    public let additions: Int?
    public let deletions: Int?
    public var isBinary: Bool { additions == nil }
    public init(path: String, oldPath: String? = nil, additions: Int?, deletions: Int?) {
        self.path = path; self.oldPath = oldPath; self.additions = additions; self.deletions = deletions
    }
}
public struct Commit: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let changes: [FileChange]
    public init(id: String, author: String, email: String, date: Date, subject: String, changes: [FileChange]) {
        self.id = id; self.author = author; self.email = email; self.date = date; self.subject = subject; self.changes = changes
    }
}
public struct RepositorySnapshot: Sendable, Codable {
    public let root: URL
    public let head: String
    public let shallow: Bool
    public let commits: [Commit]
    public let fileSizes: [String: Int]
    public let reference: String
    public let branches: [String]
    public let importMode: ImportMode
    public let cacheWarning: String?
    public let importedCommits: Int
    public init(root: URL, head: String, shallow: Bool, commits: [Commit], fileSizes: [String: Int], reference: String = "HEAD", branches: [String] = [], importMode: ImportMode = .fresh, importedCommits: Int = 0, cacheWarning: String? = nil) {
        self.root = root; self.head = head; self.shallow = shallow; self.commits = commits; self.fileSizes = fileSizes
        self.cacheWarning = cacheWarning
        self.reference = reference; self.branches = branches; self.importMode = importMode; self.importedCommits = importedCommits
    }
}
public struct Hotspot: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let frequency: Int
    public let additions: Int
    public let deletions: Int
    public let binaryChanges: Int
    public let size: Int?
    public let commits: [Commit]
    public var churn: Int { additions + deletions }
}
public struct ActivityBucket: Identifiable, Sendable {
    public var id: Date { month }
    public let month: Date
    public let commits: Int
}
public struct RepositoryMetrics: Sendable {
    public let commits: Int
    public let authors: Int
    public let additions: Int
    public let deletions: Int
    public let binaryChanges: Int
    public let hotspots: [Hotspot]
    public let activity: [ActivityBucket]
    public let contributors: [AuthorContribution]
    public let ownership: [FileOwnership]
    public let coupling: [CouplingPair]
    public let directories: [DirectoryActivity]
    public let couplingLimited: Bool
    public let excludedCommits: Int
    public let currentFileCount: Int
}
