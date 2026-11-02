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
    @Published var options = AnalysisOptions()
    @Published var isLoading = false
    @Published var error: String?
    @Published var selection = "Overview"
    @Published var search = ""
    @Published var selectedHotspot: Hotspot?
    @Published var recents: [RecentRepository] = []
    @Published var status = ""
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
                status = "Computing activity, ownership and coupling…"
                let computed = await Task.detached(priority: .userInitiated) { AnalysisEngine().compute(result, options: loadedOptions) }.value
                try Task.checkCancellation()
                snapshot = result; metrics = computed; options = loadedOptions; accessURL = url
                selectedHotspot = nil; search = ""; remember(url, root: result.root)
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
            let computed = await Task.detached(priority: .userInitiated) { AnalysisEngine().compute(snapshot, options: draft) }.value
            guard !Task.isCancelled else { return }
            metrics = computed; options = draft; selectedHotspot = nil
            if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: "options." + snapshot.root.path) }
        }
    }
    func cancel() { task?.cancel() }
    var hotspots: [Hotspot] { (metrics?.hotspots ?? []).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } }
}
