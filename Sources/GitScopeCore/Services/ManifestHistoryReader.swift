import Foundation

/// Reads every version of recognised manifests in a commit range with two kinds of read-only Git calls:
/// one `git log --raw` for blob IDs, then `git cat-file --batch` for the blob contents.
struct ManifestHistoryReader {
    let runner: GitCommandRunner
    /// Larger manifests (generated lock files, huge project files) are skipped rather than parsed.
    static let maximumBlobBytes = 2 * 1024 * 1024
    static let batchBytes = 48 * 1024 * 1024

    static func warning(for error: Error) -> String {
        "Dependency history could not be read (\(error.localizedDescription)). Commit metrics are unaffected."
    }

    private struct Record { let commit: String; let date: Date; let path: String; let oldBlob: String?; let newBlob: String? }

    /// Reads manifest changes in `range` and the manifests present at `head`.
    func read(range: String, head: String, at root: URL) throws -> (revisions: [ManifestRevision], current: [String: [DependencyDeclaration]]) {
        let log = try runner.run(["log", "--no-merges", "--no-renames", "--raw", "--no-abbrev", "-z", "--format=%x00GSMANv1%x00%H%x00%ct", range, "--"] + ManifestCatalog.pathspecs, at: root)
        let records = try parseLog(log)
        // ls-tree does not accept glob pathspecs; list the tree and keep recognised manifests.
        let tree = try runner.run(["ls-tree", "-r", "-z", head, "--"], at: root)
        let currentBlobs = parseTree(tree)
        var blobPaths: [String: String] = [:]
        for record in records {
            for blob in [record.oldBlob, record.newBlob].compactMap({ $0 }) where blobPaths[blob] == nil { blobPaths[blob] = record.path }
        }
        for (path, blob) in currentBlobs where blobPaths[blob] == nil { blobPaths[blob] = path }
        if blobPaths.isEmpty { return ([], [:]) }
        let blobs = blobPaths.keys.sorted()
        let sizes = try blobSizes(blobs, at: root)
        var contents: [String: [DependencyDeclaration]] = [:]
        var chunk: [String] = [], chunkBytes = 0
        func flush() throws {
            guard !chunk.isEmpty else { return }
            for (blob, data) in try blobContents(chunk, at: root) {
                contents[blob] = ManifestParser().parse(String(decoding: data, as: UTF8.self), path: blobPaths[blob]!)
            }
            chunk = []; chunkBytes = 0
        }
        for blob in blobs {
            guard let size = sizes[blob], size <= Self.maximumBlobBytes else { continue }
            if chunkBytes + size > Self.batchBytes { try flush() }
            chunk.append(blob); chunkBytes += size
        }
        try flush()
        // A side that was skipped for size cannot be compared, so that change is omitted rather than guessed.
        let revisions = records.compactMap { record -> ManifestRevision? in
            var previous: [DependencyDeclaration]?
            if let old = record.oldBlob { guard let parsed = contents[old] else { return nil }; previous = parsed }
            var declarations: [DependencyDeclaration] = []
            if let new = record.newBlob { guard let parsed = contents[new] else { return nil }; declarations = parsed }
            return ManifestRevision(commit: record.commit, date: record.date, path: record.path, deleted: record.newBlob == nil, declarations: declarations, previous: previous)
        }
        var current: [String: [DependencyDeclaration]] = [:]
        for (path, blob) in currentBlobs { if let parsed = contents[blob] { current[path] = parsed } }
        return (revisions, current)
    }

    private func parseTree(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let fields = entry[..<tab].split(separator: " ")
            let path = String(entry[entry.index(after: tab)...])
            if fields.count == 3, fields[1] == "blob", ManifestCatalog.format(for: path) != nil { result[path] = String(fields[2]) }
        }
        return result
    }

    /// Protocol: NUL marker `GSMANv1`, object ID and committer timestamp, then `:modes oids status` NUL path NUL records.
    private func parseLog(_ data: Data) throws -> [Record] {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid("non-UTF-8 manifest history") }
        let tokens = text.components(separatedBy: "\0")
        var index = 0
        var result: [Record] = []
        while index < tokens.count {
            if tokens[index].trimmingCharacters(in: .newlines).isEmpty { index += 1; continue }
            guard tokens[index] == "GSMANv1", index + 2 < tokens.count, let seconds = TimeInterval(tokens[index + 2]) else { throw ParseError.invalid("manifest commit boundary") }
            let commit = tokens[index + 1]
            index += 3
            while index < tokens.count && tokens[index] != "GSMANv1" {
                var header = tokens[index]
                if header.hasPrefix("\n") { header.removeFirst() }
                if header.isEmpty { index += 1; continue }
                guard header.hasPrefix(":"), index + 1 < tokens.count else { throw ParseError.invalid("raw diff record") }
                let fields = header.dropFirst().split(separator: " ")
                guard fields.count == 5 else { throw ParseError.invalid("raw diff fields") }
                let path = tokens[index + 1]
                index += 2
                guard ManifestCatalog.format(for: path) != nil else { continue }
                // Submodule entries (mode 160000) have no manifest blob; all-zero IDs mean the side does not exist.
                if fields[0] == "160000" || fields[1] == "160000" { continue }
                func blob(_ field: Substring) -> String? { field.allSatisfy { $0 == "0" } ? nil : String(field) }
                result.append(Record(commit: commit, date: Date(timeIntervalSince1970: seconds), path: path, oldBlob: blob(fields[2]), newBlob: blob(fields[3])))
            }
        }
        return result
    }

    private func blobSizes(_ blobs: [String], at root: URL) throws -> [String: Int] {
        let output = try runner.run(["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], at: root, input: Data((blobs.joined(separator: "\n") + "\n").utf8))
        var sizes: [String: Int] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 3, fields[1] == "blob", let size = Int(fields[2]) { sizes[String(fields[0])] = size }
        }
        return sizes
    }

    /// Parses `<oid> <type> <size>\n<content>\n` records from `git cat-file --batch`.
    private func blobContents(_ blobs: [String], at root: URL) throws -> [(String, Data)] {
        let output = try runner.run(["cat-file", "--batch"], at: root, input: Data((blobs.joined(separator: "\n") + "\n").utf8))
        var result: [(String, Data)] = []
        var position = output.startIndex
        while position < output.endIndex {
            guard let newline = output[position...].firstIndex(of: 0x0A) else { throw ParseError.invalid("blob header") }
            let header = String(decoding: output[position..<newline], as: UTF8.self).split(separator: " ")
            position = output.index(after: newline)
            if header.count == 2 && header[1] == "missing" { continue }
            guard header.count == 3, let size = Int(header[2]), output.distance(from: position, to: output.endIndex) >= size else { throw ParseError.invalid("blob record") }
            let end = output.index(position, offsetBy: size)
            if header[1] == "blob" { result.append((String(header[0]), Data(output[position..<end]))) }
            position = end < output.endIndex ? output.index(after: end) : end
        }
        return result
    }
}
