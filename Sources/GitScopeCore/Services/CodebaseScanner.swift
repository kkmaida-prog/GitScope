import Foundation

/// Reads line-level evidence from the pinned revision with read-only `git grep`, `git log -S`, `git show` and `git blame`.
/// It never reads the working tree, so uncommitted edits cannot leak into results tied to a revision.
public struct CodebaseScanner: Sendable {
    /// Migration starts are searched with pickaxe, which diffs history; bound how many rules may request it.
    public static let maximumMigrationSearches = 12
    static let maximumStoredLineLength = 400
    static let excludedPathspecs = ManifestCatalog.vendoredComponents.sorted().map { ":(exclude,glob)**/" + $0 + "/**" }
    static let importExtensions = ["swift", "m", "mm", "h", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "py", "rb", "rs", "java", "kt", "kts", "scala", "groovy", "cs"]

    public init() {}

    public func scan(_ snapshot: RepositorySnapshot, rules: [LegacyRule]) async throws -> CodeScan {
        let worker = Task.detached(priority: .userInitiated) { try self.load(snapshot, rules: rules) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public func load(_ snapshot: RepositorySnapshot, rules: [LegacyRule]) throws -> CodeScan {
        let runner = GitCommandRunner()
        let root = snapshot.root, head = snapshot.head
        var warnings: [String] = []
        var matches: [RuleMatch] = []
        var replacementsPresent = Set<String>()
        let compiled = rules.compactMap { rule -> (LegacyRule, NSRegularExpression)? in
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: rule.caseInsensitive ? [.caseInsensitive] : []) else {
                warnings.append("Rule “\(rule.title)” has an invalid pattern and was skipped."); return nil
            }
            return (rule, expression)
        }
        let keywords = Array(Set(compiled.flatMap { $0.0.keywords + ($0.0.replacementKeyword.map { [$0] } ?? []) }.filter { !$0.isEmpty })).sorted()
        if !keywords.isEmpty {
            do {
                let output = try runner.run(["grep", "-n", "-I", "-z", "--no-color", "-F"] + keywords.flatMap { ["-e", $0] } + [head, "--"]
                                            + Self.pathspecs(LegacyRules.sourceExtensions) + Self.excludedPathspecs, at: root, allowedStatuses: [0, 1])
                for line in try Self.parseGrep(output, head: head) {
                    for (rule, expression) in compiled where rule.applies(to: line.path) {
                        if let keyword = rule.replacementKeyword, line.text.contains(keyword) { replacementsPresent.insert(rule.id) }
                        guard rule.keywords.contains(where: { line.text.range(of: $0, options: rule.caseInsensitive ? .caseInsensitive : []) != nil }),
                              Self.matches(expression, line: line, category: rule.category) else { continue }
                        matches.append(RuleMatch(ruleID: rule.id, location: Self.stored(line)))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Legacy rules could not be scanned: \(error.localizedDescription)") }
        }
        var migrationStarts: [String: MigrationStart] = [:]
        let matchedRules = Set(matches.map(\.ruleID))
        let migrations = compiled.map(\.0).filter { matchedRules.contains($0.id) && replacementsPresent.contains($0.id) && $0.replacementKeyword != nil }
        if migrations.count > Self.maximumMigrationSearches {
            warnings.append("Migration start dates were searched for the first \(Self.maximumMigrationSearches) of \(migrations.count) rules in progress.")
        }
        for rule in migrations.prefix(Self.maximumMigrationSearches) {
            do {
                let output = try runner.run(["log", "--no-merges", "--format=%H%x00%ct", "-S" + rule.replacementKeyword!, head, "--"]
                                            + Self.pathspecs(rule.extensions.isEmpty ? LegacyRules.sourceExtensions : rule.extensions) + Self.excludedPathspecs, at: root)
                // Pickaxe lists commits that changed the number of occurrences; the oldest one introduced the replacement.
                if let oldest = String(decoding: output, as: UTF8.self).split(separator: "\n").last {
                    let fields = oldest.split(separator: "\0")
                    if fields.count == 2, let seconds = TimeInterval(fields[1]) {
                        migrationStarts[rule.id] = MigrationStart(ruleID: rule.id, commit: String(fields[0]), date: Date(timeIntervalSince1970: seconds))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("The migration start for “\(rule.title)” could not be dated: \(error.localizedDescription)") }
        }
        var imports: [ImportReference] = []
        do { imports = try readImports(runner: runner, snapshot: snapshot) }
        catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Import statements could not be scanned, so dependency usage is unavailable: \(error.localizedDescription)") }
        return CodeScan(head: head, rules: rules, matches: matches, imports: imports, migrationStarts: migrationStarts, warnings: warnings)
    }

    /// Source lines around `line` at the pinned revision, plus the commit that last changed that line.
    public func context(root: URL, head: String, path: String, line: Int?, radius: Int = 8) throws -> CodeContext {
        let runner = GitCommandRunner()
        let data = try runner.run(["show", "--no-textconv", head + ":" + path], at: root)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let focus = min(max(1, line ?? 1), max(1, lines.count))
        let lower = line == nil ? 1 : max(1, focus - radius), upper = line == nil ? min(lines.count, 2 * radius + 1) : min(lines.count, focus + radius)
        let window = lower <= upper ? (lower...upper).map { CodeLine(path: path, line: $0, text: String(lines[$0 - 1].prefix(Self.maximumStoredLineLength))) } : []
        var blame: BlameLine?
        if let line, line <= lines.count {
            let output = try runner.run(["blame", "--porcelain", "-L", "\(line),\(line)", head, "--", path], at: root)
            blame = Self.parseBlame(output)
        }
        return CodeContext(lines: window, blame: blame)
    }

    // MARK: Imports

    private func readImports(runner: GitCommandRunner, snapshot: RepositorySnapshot) throws -> [ImportReference] {
        let patterns = [#"^[[:space:]]*(@testable[[:space:]]+|@_exported[[:space:]]+|@preconcurrency[[:space:]]+|pub[[:space:]]+|global[[:space:]]+)?(import|from|use|using|require|extern[[:space:]]+crate)[[:space:]]"#,
                        #"require\("#, #"#import[[:space:]]*<"#, #"@import[[:space:]]"#, #"[[:space:]]from[[:space:]]+['"]"#]
        var lines = try grep(runner, snapshot, patterns: patterns, extensions: Self.importExtensions)
        if snapshot.fileSizes.keys.contains(where: { $0.hasSuffix(".go") }) {
            lines += try grep(runner, snapshot, patterns: [#"^[[:space:]]*import[[:space:]]"#, #"^[[:space:]]*([A-Za-z_.]+[[:space:]]+)?"[^"]+"[[:space:]]*$"#], extensions: ["go"])
        }
        return lines.flatMap { line in Self.importedModules(in: line).map { ImportReference(module: $0, location: Self.stored(line)) } }
    }
    private func grep(_ runner: GitCommandRunner, _ snapshot: RepositorySnapshot, patterns: [String], extensions: [String]) throws -> [CodeLine] {
        let output = try runner.run(["grep", "-n", "-I", "-z", "--no-color", "-E"] + patterns.flatMap { ["-e", $0] } + [snapshot.head, "--"]
                                    + Self.pathspecs(extensions) + Self.excludedPathspecs, at: snapshot.root, allowedStatuses: [0, 1])
        return try Self.parseGrep(output, head: snapshot.head)
    }
    static func importedModules(in line: CodeLine) -> [String] {
        let ext = RepoPath.fileExtension(line.path)
        let patterns: [String]
        switch ext {
        case "swift": patterns = [#"^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#]
        case "m", "mm", "h": patterns = [#"@import\s+([A-Za-z_]\w*)"#, #"#import\s*<([A-Za-z_]\w*)/"#]
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte": patterns = [#"\bfrom\s+['"]([^'"]+)['"]"#, #"^\s*import\s+['"]([^'"]+)['"]"#, #"\brequire\(\s*['"]([^'"]+)['"]\s*\)"#]
        case "py": patterns = [#"^\s*from\s+([A-Za-z_][\w.]*)\s+import\b"#, #"^\s*import\s+([A-Za-z_][\w.]*)"#]
        case "rb": patterns = [#"^\s*require\s+['"]([^'"]+)['"]"#]
        case "rs": patterns = [#"^\s*(?:pub\s+)?use\s+([A-Za-z_][A-Za-z0-9_]*)"#, #"^\s*extern\s+crate\s+([A-Za-z_][A-Za-z0-9_]*)"#]
        case "java", "kt", "kts", "scala", "groovy": patterns = [#"^\s*import\s+(?:static\s+)?([A-Za-z_][\w.]*)"#]
        case "cs": patterns = [#"^\s*(?:global\s+)?using\s+(?:static\s+)?([A-Za-z_][\w.]*)\s*;"#]
        case "go": patterns = [#"^\s*(?:import\s+)?(?:[A-Za-z_.]+\s+)?"([^"]+)"\s*$"#]
        default: return []
        }
        let parser = ManifestParser()
        let found = patterns.flatMap { parser.captures($0, line.text).map { $0[0] } }.filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("/") }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    // MARK: Parsing helpers

    static func pathspecs(_ extensions: [String]) -> [String] { extensions.map { ":(glob)**/*." + $0 } }
    static func stored(_ line: CodeLine) -> CodeLine {
        CodeLine(path: line.path, line: line.line, text: String(line.text.trimmingCharacters(in: .whitespaces).prefix(maximumStoredLineLength)))
    }

    /// `git grep -z -n` with a tree-ish prints `<rev>:<path>` NUL `<line>` NUL `<text>` LF. Paths may contain newlines.
    static func parseGrep(_ data: Data, head: String) throws -> [CodeLine] {
        var result: [CodeLine] = []
        var position = data.startIndex
        let prefix = Data((head + ":").utf8)
        while position < data.endIndex {
            guard let pathEnd = data[position...].firstIndex(of: 0), let numberEnd = data[data.index(after: pathEnd)...].firstIndex(of: 0) else { throw ParseError.invalid("grep record") }
            var pathData = data[position..<pathEnd]
            guard pathData.starts(with: prefix) else { throw ParseError.invalid("grep revision prefix") }
            pathData = pathData.dropFirst(prefix.count)
            guard let number = Int(String(decoding: data[data.index(after: pathEnd)..<numberEnd], as: UTF8.self)) else { throw ParseError.invalid("grep line number") }
            let textStart = data.index(after: numberEnd)
            let textEnd = data[textStart...].firstIndex(of: 0x0A) ?? data.endIndex
            result.append(CodeLine(path: String(decoding: pathData, as: UTF8.self), line: number, text: String(decoding: data[textStart..<textEnd], as: UTF8.self)))
            position = textEnd < data.endIndex ? data.index(after: textEnd) : textEnd
        }
        return result
    }

    /// Deprecated-API rules ignore comments and string literals; markers are expected inside comments but not strings.
    static func matches(_ expression: NSRegularExpression, line: CodeLine, category: LegacyRuleCategory) -> Bool {
        let text = line.text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if category == .deprecatedAPI && ["//", "#", "/*", "*", "--"].contains(where: { trimmed.hasPrefix($0) }) && !trimmed.hasPrefix("#import") && !trimmed.hasPrefix("#include") { return false }
        let source = text as NSString
        let quoteCharacters: Set<unichar> = ["py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "rb", "php", "vue", "svelte"].contains(RepoPath.fileExtension(line.path))
            ? [34, 39, 96] : [34]
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var open: unichar?
            var index = 0
            while index < match.range.location {
                let character = source.character(at: index)
                if character == 92 { index += 2; continue } // backslash escape
                if let quote = open { if character == quote { open = nil } }
                else if quoteCharacters.contains(character) { open = character }
                else if category == .deprecatedAPI && character == 47 && index + 1 < source.length && source.character(at: index + 1) == 47 { break } // trailing // comment
                index += 1
            }
            let inTrailingComment = category == .deprecatedAPI && index < match.range.location
            if open == nil && !inTrailingComment { return true }
        }
        return false
    }

    static func parseBlame(_ data: Data) -> BlameLine? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let first = lines.first?.split(separator: " ").first, first.count >= 40 else { return nil }
        func value(_ key: String) -> String { lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) } ?? "" }
        let mail = value("author-mail").trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return BlameLine(commit: String(first), author: value("author"), email: mail, date: Date(timeIntervalSince1970: TimeInterval(value("committer-time")) ?? 0), summary: value("summary"))
    }
}
