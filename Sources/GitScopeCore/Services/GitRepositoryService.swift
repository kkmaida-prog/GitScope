import Foundation

public enum GitError: LocalizedError {
    case failed(String), limit
    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .limit: return "Analysis exceeded the MVP limit (120 seconds per command or 128 MiB output). Choose a smaller repository."
        }
    }
}
public struct GitCommandRunner: Sendable {
    public init() {}
    public func run(_ arguments: [String], at url: URL) throws -> Data {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "diff.external=", "-c", "core.quotePath=false", "-C", url.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"]
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        try process.run()
        func withinOutputLimits() -> Bool {
            let count = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            let errorCount = ((try? FileManager.default.attributesOfItem(atPath: errorURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            return count <= 128 * 1024 * 1024 && errorCount <= 1024 * 1024
        }
        let deadline = Date().addingTimeInterval(120)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() > deadline || !withinOutputLimits() { throw GitError.limit }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } catch {
            if process.isRunning { process.terminate() }
            // A fixed Git executable with hooks/filters disabled should exit promptly.
            let stop = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard withinOutputLimits() else { throw GitError.limit }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message.isEmpty ? "Git could not read this repository." : message)
        }
        return try Data(contentsOf: outputURL)
    }
}
public struct GitRepositoryService: Sendable {
    public let cacheURL: URL?
    public init(cacheURL: URL? = nil) { self.cacheURL = cacheURL }
    public func analyze(_ url: URL, reference: String = "HEAD") async throws -> RepositorySnapshot {
        let worker = Task.detached(priority: .userInitiated) { try self.load(url, reference: reference) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    public func load(_ url: URL, reference requested: String = "HEAD") throws -> RepositorySnapshot {
        let runner = GitCommandRunner()
        func string(_ args: [String], at location: URL) throws -> String {
            String(decoding: try runner.run(args, at: location), as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        guard try string(["rev-parse", "--is-inside-work-tree"], at: url) == "true" else { throw GitError.failed("Select a working-tree Git repository. Bare repositories are not supported.") }
        let root = URL(fileURLWithPath: try string(["rev-parse", "--show-toplevel"], at: url))
        let branches = try string(["for-each-ref", "--format=%(refname)", "refs/heads/"], at: root).split(separator: "\n").map(String.init)
        let reference = requested == "DEFAULT" ? (branches.contains("refs/heads/main") ? "refs/heads/main" : "HEAD") : requested
        guard reference == "HEAD" || branches.contains(reference) else { throw GitError.failed("The selected local branch no longer exists. Choose another branch.") }
        let head: String
        do { head = try string(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], at: root) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GitError.failed("This branch has no readable commit. Create a commit first, or check the repository for corruption.") }
        let shallow = try string(["rev-parse", "--is-shallow-repository"], at: root) == "true"
        let cache = cacheURL.map { RepositoryCache(url: $0) }
        var warning: String?
        var previous: RepositorySnapshot?
        do { previous = try cache?.read(root: root, reference: reference) }
        catch { warning = "Local cache could not be read; history was re-imported." }
        if let previous, previous.head == head, previous.shallow == shallow {
            return RepositorySnapshot(root: root, head: head, shallow: shallow, commits: previous.commits,
                                      fileSizes: previous.fileSizes, reference: reference, branches: branches,
                                      importMode: .cached, importedCommits: 0)
        }
        var base: RepositorySnapshot?
        if let previous, !shallow, !previous.shallow {
            do {
                _ = try runner.run(["merge-base", "--is-ancestor", previous.head, head], at: root)
                base = previous
            } catch is CancellationError { throw CancellationError() }
            catch { /* A rewrite or missing old object requires a full rebuild. */ }
        }
        let range = base.map { $0.head + ".." + head } ?? head
        let history = try runner.run(["log", "--no-merges", "--no-ext-diff", "--no-textconv", "--find-renames", "--numstat", "-z", "--format=%x00GITSCOPEv1%x00%H%x00%an%x00%ae%x00%ct%x00%s%x00", range, "--"], at: root)
        let parser = HistoryParser()
        let imported = try parser.parse(history)
        var seen = Set<String>()
        let commits = (imported + (base?.commits ?? [])).filter { seen.insert($0.id).inserted }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
        let sizes = try parser.parseTree(runner.run(["ls-tree", "-r", "-l", "-z", head, "--"], at: root))
        let snapshot = RepositorySnapshot(root: root, head: head, shallow: shallow, commits: commits, fileSizes: sizes,
                                          reference: reference, branches: branches, importMode: base == nil ? .fresh : .incremental,
                                          importedCommits: imported.count)
        do { try cache?.write(snapshot) }
        catch is CancellationError { throw CancellationError() }
        catch { warning = "Analysis succeeded, but the local cache could not be saved." }
        try Task.checkCancellation()
        return RepositorySnapshot(root: root, head: head, shallow: shallow, commits: commits, fileSizes: sizes,
                                  reference: reference, branches: branches, importMode: snapshot.importMode,
                                  importedCommits: imported.count, cacheWarning: warning)
    }
}
