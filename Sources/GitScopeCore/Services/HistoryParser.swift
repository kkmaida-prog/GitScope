import Foundation

public enum ParseError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return "Invalid Git output: \(message)" }; return nil }
}
/// Protocol v1: NUL marker + five metadata fields, followed by NUL numstat records.
/// Git paths may contain tabs/newlines; only the first two tabs delimit counts.
public struct HistoryParser {
    public init() {}
    public func parse(_ data: Data) throws -> [Commit] {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid("non-UTF-8 history is not supported in this milestone") }
        let tokens = text.components(separatedBy: "\0")
        var index = 0
        var result: [Commit] = []
        while index < tokens.count {
            if tokens[index].trimmingCharacters(in: .newlines).isEmpty { index += 1; continue }
            guard tokens[index] == "GITSCOPEv1", index + 5 < tokens.count else { throw ParseError.invalid("missing commit boundary") }
            let oid = tokens[index + 1], author = tokens[index + 2], email = tokens[index + 3]
            guard oid.count == 40 || oid.count == 64, oid.allSatisfy({ $0.isHexDigit }), let seconds = TimeInterval(tokens[index + 4]), seconds.isFinite else { throw ParseError.invalid("commit metadata") }
            let subject = tokens[index + 5]
            index += 6
            var changes: [FileChange] = []
            while index < tokens.count && tokens[index] != "GITSCOPEv1" {
                var record = tokens[index]; index += 1
                // Git inserts one LF between the header and the first numstat record.
                if record.hasPrefix("\n") { record.removeFirst() }
                if record.isEmpty { continue }
                let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { throw ParseError.invalid("numstat record") }
                let binary = parts[0] == "-" && parts[1] == "-"
                let added = Int(parts[0]), deleted = Int(parts[1])
                guard binary || (added != nil && deleted != nil && added! >= 0 && deleted! >= 0) else { throw ParseError.invalid("line counts") }
                var path = String(parts[2]); var old: String?
                if path.isEmpty {
                    guard index + 1 < tokens.count, !tokens[index].isEmpty, !tokens[index + 1].isEmpty else { throw ParseError.invalid("rename paths") }
                    old = tokens[index]; path = tokens[index + 1]; index += 2
                }
                changes.append(FileChange(path: path, oldPath: old, additions: added, deletions: deleted))
            }
            result.append(Commit(id: oid, author: author, email: email, date: Date(timeIntervalSince1970: seconds), subject: subject, changes: changes))
        }
        return result
    }
    public func parseTree(_ data: Data) throws -> [String: Int] {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid("non-UTF-8 tree") }
        var sizes: [String: Int] = [:]
        for entry in text.split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t") else { throw ParseError.invalid("tree entry") }
            let fields = entry[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 4 else { throw ParseError.invalid("tree metadata") }
            // Submodules have no blob size; do not count them as regular files.
            if fields[1] == "blob" {
                guard let size = Int(fields[3]) else { throw ParseError.invalid("blob size") }
                sizes[String(entry[entry.index(after: tab)...])] = size
            }
        }
        return sizes
    }
}
