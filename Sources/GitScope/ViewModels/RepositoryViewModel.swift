import SwiftUI
import AppKit
import GitScopeCore

struct RecentRepository: Identifiable, Codable {
    var id: String { path }
    let path: String
    let name: String
    let bookmark: Data
}
@MainActor final class RepositoryViewModel: ObservableObject {
    @Published var snapshot: RepositorySnapshot?
    @Published var metrics: RepositoryMetrics?
    @Published var codeQuality: CodeQualityReport?
    @Published var codeQualityCacheStatus: CodeQualityCacheStatus?
    @Published var options = AnalysisOptions()
    @Published var isLoading = false
    @Published var error: String?
    @Published var selection = "Overview"
    @Published var search = ""
    @Published var selectedHotspot: Hotspot?
    @Published var recents: [RecentRepository] = []
    @Published var status = ""
    /// Line-level evidence for the selected revision; nil until the first scan completes.
    @Published var scan: CodeScan?
    @Published var ruleSettings = LegacyRuleSettings()
    /// Folder shown by the Structure view; the empty string is the repository root.
    @Published var structureFolder = ""
    @Published var inspectedLocation: CodeLocation?
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    init() {
        if let data = defaults.data(forKey: "recentRepositories.v2"), let stored = try? JSONDecoder().decode([RecentRepository].self, from: data) { recents = stored }
    }
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Select a local Git repository. GitScope only reads its history."
        if panel.runModal() == .OK, let url = panel.url { open(url, reference: "DEFAULT") }
    }
    func openRecent(_ recent: RecentRepository) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: recent.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            open(url, reference: "DEFAULT")
        } catch { self.error = "Access to this recent repository expired. Use Open Repository to select its folder again." }
    }
    private func remember(_ url: URL, root: URL) {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        recents.removeAll { $0.path == root.path }
        recents.insert(RecentRepository(path: root.path, name: root.lastPathComponent, bookmark: bookmark), at: 0)
        recents = Array(recents.prefix(8))
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: "recentRepositories.v2") }
    }
    private var accessURL: URL?
    func refresh(reference: String? = nil) {
        if let url = accessURL { open(url, reference: reference ?? snapshot?.reference ?? "HEAD") }
    }
    func open(_ url: URL, reference: String = "DEFAULT") {
        guard !isLoading else { return }
        error = nil; isLoading = true; status = "Reading branch and local history…"
        task = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; isLoading = false }
            do {
                let result = try await GitRepositoryService(cacheURL: RepositoryCache.defaultURL).analyze(url, reference: reference)
                try Task.checkCancellation()
                let loadedOptions: AnalysisOptions
                if snapshot?.root == result.root { loadedOptions = options }
                else if let data = defaults.data(forKey: "options." + result.root.path), let saved = try? JSONDecoder().decode(AnalysisOptions.self, from: data) { loadedOptions = saved }
                else { loadedOptions = AnalysisOptions() }
                let rules = snapshot?.root == result.root ? ruleSettings : storedRules(for: result.root)
                status = "Scanning code at the selected revision…"
                let scanned = try await CodebaseScanner().scan(result, rules: rules.effectiveRules)
                try Task.checkCancellation()
                status = "Computing activity, ownership, structure, dependencies and legacy signals…"
                let computed = await Task.detached(priority: .userInitiated) { AnalysisEngine().compute(result, options: loadedOptions, scan: scanned) }.value
                status = "Checking selected-revision code quality…"
                let quality = await Task.detached(priority: .userInitiated) {
                    CodeQualityCacheService(cacheURL: RepositoryCache.defaultURL)
                        .loadOrCompute(snapshot: result, metrics: computed, options: loadedOptions)
                }.value
                try Task.checkCancellation()
                if snapshot?.root != result.root { structureFolder = "" }
                snapshot = result; metrics = computed; codeQuality = quality.report; codeQualityCacheStatus = quality.status; options = loadedOptions; accessURL = url
                scan = scanned; ruleSettings = rules
                if computed.structure.folders[structureFolder] == nil { structureFolder = "" }
                selectedHotspot = nil; inspectedLocation = nil; search = ""; remember(url, root: result.root)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func apply(_ draft: AnalysisOptions) {
        guard let snapshot, !isLoading else { return }
        if let since = draft.since, let until = draft.until, since >= until { error = "The start date must be earlier than the end date."; return }
        isLoading = true; status = "Applying shared filters…"
        task = Task {
            defer { isLoading = false }
            let scan = self.scan
            let computed = await Task.detached(priority: .userInitiated) { AnalysisEngine().compute(snapshot, options: draft, scan: scan) }.value
            let quality = await Task.detached(priority: .userInitiated) {
                CodeQualityCacheService(cacheURL: RepositoryCache.defaultURL)
                    .loadOrCompute(snapshot: snapshot, metrics: computed, options: draft)
            }.value
            guard !Task.isCancelled else { return }
            metrics = computed; codeQuality = quality.report; codeQualityCacheStatus = quality.status; options = draft; selectedHotspot = nil
            if computed.structure.folders[structureFolder] == nil { structureFolder = "" }
            if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: "options." + snapshot.root.path) }
        }
    }
    func cancel() { task?.cancel() }

    // MARK: Legacy rules and line evidence

    private func storedRules(for root: URL) -> LegacyRuleSettings {
        guard let data = defaults.data(forKey: "legacyRules." + root.path), let saved = try? JSONDecoder().decode(LegacyRuleSettings.self, from: data) else { return LegacyRuleSettings() }
        return saved
    }
    /// Saves the rules for this repository and rescans the pinned revision. History is not re-imported.
    func updateRules(_ settings: LegacyRuleSettings) {
        guard let snapshot, !isLoading else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "legacyRules." + snapshot.root.path) }
        isLoading = true; status = "Rescanning code with the updated rules…"
        let url = accessURL, options = self.options
        task = Task {
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { url?.stopAccessingSecurityScopedResource() }; isLoading = false }
            do {
                let scanned = try await CodebaseScanner().scan(snapshot, rules: settings.effectiveRules)
                let computed = await Task.detached(priority: .userInitiated) { AnalysisEngine().compute(snapshot, options: options, scan: scanned) }.value
                try Task.checkCancellation()
                ruleSettings = settings; scan = scanned; metrics = computed
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    /// Reads lines around a location and blames the focused line, at the pinned revision.
    func context(path: String, line: Int?) async throws -> CodeContext {
        guard let snapshot else { throw GitError.failed("Open a repository first.") }
        let url = accessURL
        return try await Task.detached(priority: .userInitiated) {
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
            return try CodebaseScanner().context(root: snapshot.root, head: snapshot.head, path: path, line: line)
        }.value
    }
    func inspect(path: String, line: Int? = nil) {
        guard let metrics else { return }
        inspectedLocation = CodeLocation(path: path, line: line, metrics: metrics)
    }
    func showFolder(_ path: String) {
        structureFolder = path; selection = "Structure"
    }
    var hotspots: [Hotspot] { (metrics?.hotspots ?? []).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } }
}
