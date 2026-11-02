import SwiftUI
import Charts
import GitScopeCore

struct ContentView: View {
    @StateObject private var model = RepositoryViewModel()
    @State private var showFilters = false
    @State private var selectedPair: CouplingPair?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                Label("GitScope", systemImage: "point.3.connected.trianglepath.dotted").font(.title2.bold()).padding(.top, 18)
                Text("REPOSITORY INTELLIGENCE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).tracking(1.5)
                List(selection: $model.selection) {
                    Label("Overview", systemImage: "square.grid.2x2").tag("Overview")
                    Label("Hotspots", systemImage: "flame").tag("Hotspots")
                    Label("Ownership", systemImage: "person.2").tag("Ownership")
                    Label("Coupling", systemImage: "link").tag("Coupling")
                }.listStyle(.sidebar)
                if !model.recents.isEmpty {
                    Text("RECENT REPOSITORIES").font(.caption2).foregroundStyle(.secondary)
                    ForEach(model.recents) { recent in
                        Button { model.openRecent(recent) } label: { Label(recent.name, systemImage: "folder").lineLimit(1) }.buttonStyle(.plain).disabled(model.isLoading)
                    }
                }
                Spacer()
                Label("Local & read-only", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Text("Your repository stays on your Mac.").font(.caption2).foregroundStyle(.tertiary)
            }.padding(16).navigationSplitViewColumnWidth(220)
        } detail: {
            Group {
                if let snapshot = model.snapshot, let metrics = model.metrics {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header(snapshot)
                            if snapshot.shallow { Label("Shallow repository — history and metrics are incomplete.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            scope(snapshot, metrics)
                            if let warning = snapshot.cacheWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                            switch model.selection {
                            case "Hotspots": hotspots(metrics)
                            case "Ownership": OwnershipView(metrics: metrics) { path in model.selectedHotspot = metrics.hotspots.first { $0.path == path } }
                            case "Coupling": CouplingView(metrics: metrics) { selectedPair = $0 }
                            default: overview(snapshot, metrics)
                            }
                        }.padding(32)
                    }
                } else {
                    ContentUnavailableView {
                        Label("See your repository’s story", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Explore commit activity and the files that change most often.\nChoose a local repository to begin.")
                    } actions: {
                        Button("Choose Repository…", action: model.chooseRepository).buttonStyle(.borderedProminent).disabled(model.isLoading)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay { if model.isLoading { loading } }
            .toolbar {
                ToolbarItem { Button(action: model.chooseRepository) { Label("Open Repository", systemImage: "folder.badge.plus") }.keyboardShortcut("o").disabled(model.isLoading) }
                ToolbarItem { Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.snapshot == nil || model.isLoading) }
            }
            .alert("Unable to analyze repository", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
            .sheet(item: $model.selectedHotspot) { hotspot in FileInspector(hotspot: hotspot) }
            .sheet(isPresented: $showFilters) { if let snapshot = model.snapshot { FilterEditor(options: model.options, snapshot: snapshot, apply: model.apply) } }
            .sheet(item: $selectedPair) { pair in CouplingInspector(pair: pair) }
        }.tint(.teal)
    }
    private func header(_ snapshot: RepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selection.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(2)
            Text(snapshot.root.lastPathComponent).font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Revision \(snapshot.head.prefix(10)) · Reachable non-merge commits · UTC months").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func scope(_ snapshot: RepositorySnapshot, _ metrics: RepositoryMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Branch", selection: Binding(get: { snapshot.reference }, set: { model.refresh(reference: $0) })) {
                    Text("Working tree HEAD").tag("HEAD")
                    ForEach(snapshot.branches, id: \.self) { branch in Text(String(branch.dropFirst("refs/heads/".count))).tag(branch) }
                }.frame(maxWidth: 340).disabled(model.isLoading)
                Spacer()
                Button { showFilters = true } label: { Label("Shared filters", systemImage: "line.3.horizontal.decrease.circle") }.disabled(model.isLoading)
            }
            Text("\(snapshot.importMode.rawValue) · \(snapshot.importedCommits) commits read · \(metrics.commits) eligible / \(snapshot.commits.count) total · \(metrics.excludedCommits) excluded").font(.caption).foregroundStyle(.secondary)
            Text(scopeDescription).font(.caption).foregroundStyle(.secondary)
            Text("File count and sizes describe the selected revision with path/type exclusions. Date and author filters apply to historical activity.").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private var scopeDescription: String {
        let options = model.options
        var parts = ["Bulk limit: \(options.maximumFilesPerCommit == 0 ? "off" : String(options.maximumFilesPerCommit))"]
        if let since = options.since { parts.append("from " + since.formatted(.iso8601.year().month().day().dateSeparator(.dash))) }
        if let until = options.until { parts.append("before " + until.formatted(.iso8601.year().month().day().dateSeparator(.dash))) }
        if !options.authorQuery.isEmpty { parts.append("author: " + options.authorQuery) }
        if !options.pathQuery.isEmpty { parts.append("path: " + options.pathQuery) }
        if !options.fileExtension.isEmpty { parts.append("type: " + options.fileExtension) }
        parts.append("\(options.excludedPatterns.count) path exclusions")
        return parts.joined(separator: " · ")
    }
    private func overview(_ snapshot: RepositorySnapshot, _ metrics: RepositoryMetrics) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                metric("Commits", value: metrics.commits.formatted(), icon: "arrow.triangle.branch")
                metric("Authors", value: metrics.authors.formatted(), icon: "person.2")
                metric("Files at revision", value: metrics.currentFileCount.formatted(), icon: "doc.on.doc")
                metric("Line churn", value: (metrics.additions + metrics.deletions).formatted(), icon: "plus.forwardslash.minus")
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Commit activity").font(.title3.bold())
                Text("Monthly commits · committed date · UTC").font(.caption).foregroundStyle(.secondary)
                Chart(metrics.activity) { bucket in
                    BarMark(x: .value("Month", bucket.month, unit: .month), y: .value("Commits", bucket.commits)).foregroundStyle(.teal.gradient).cornerRadius(3)
                }.chartXScale(domain: activityDomain(metrics.activity))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!).frame(height: 210)
                HStack { Text("+\(metrics.additions.formatted()) added"); Text("−\(metrics.deletions.formatted()) deleted"); Spacer(); Text("\(metrics.binaryChanges) binary changes excluded from churn") }.font(.caption).foregroundStyle(.secondary)
            }.card()
            if !metrics.directories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Directory activity").font(.title3.bold())
                    ForEach(metrics.directories.prefix(6)) { directory in
                        HStack { Text(directory.path).font(.system(.body, design: .monospaced)); Spacer(); Text("\(directory.commits) commits · \(directory.churn) churn").foregroundStyle(.secondary) }
                    }
                }.card()
            }
            HStack { Text("Most frequently changed").font(.title3.bold()); Spacer(); Button("View all hotspots") { model.selection = "Hotspots" } }
            hotspotRows(Array(metrics.hotspots.prefix(5)))
            Text("Hotspots are inspection candidates, not evidence of defects. Size is the current Git blob size in bytes; missing size means the historical path is absent at this revision. Renamed paths are shown separately in this MVP.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func hotspots(_ metrics: RepositoryMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Find the files that keep changing").font(.title2.bold())
            Text("Ranked by distinct commits per historical path. Ties use churn, then path. Select a file to inspect its evidence.").foregroundStyle(.secondary)
            TextField("Filter by path", text: $model.search).textFieldStyle(.roundedBorder)
            if model.hotspots.isEmpty { Text("No matching file changes.").foregroundStyle(.secondary) }
            hotspotRows(model.hotspots)
        }
    }
    private func hotspotRows(_ rows: [Hotspot]) -> some View {
        VStack(spacing: 0) {
            HStack { Text("FILE"); Spacer(); Text("COMMITS / CHURN / REVISION SIZE") }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(14)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows) { hotspot in
                    Button { model.selectedHotspot = hotspot } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "doc.text").foregroundStyle(.teal)
                            Text(hotspot.path).font(.system(.body, design: .monospaced)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer()
                            Text("\(hotspot.frequency)").fontWeight(.semibold).frame(width: 65, alignment: .trailing)
                            Text(hotspot.churn.formatted()).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                            Text(hotspot.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—").foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                        }.padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
    private func activityDomain(_ activity: [ActivityBucket]) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = activity.first?.month ?? calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .month, value: 1, to: activity.last?.month ?? start)!
        return start...end
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(.teal) }.font(.caption)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
    private var loading: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 18) { ProgressView(); Text(model.status).font(.headline); Text("Previous results stay available after cancellation.").font(.caption).foregroundStyle(.secondary); Button("Cancel", action: model.cancel) }.padding(32)
        }
    }
}
private extension View {
    func card() -> some View { padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary)) }
}
struct FileInspector: View {
    let hotspot: Hotspot
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("File history").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(hotspot.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("\(hotspot.frequency) commits · +\(hotspot.additions) / −\(hotspot.deletions) lines · \(hotspot.binaryChanges) binary changes").foregroundStyle(.secondary)
            List(hotspot.commits) { commit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject).fontWeight(.medium)
                    Text("\(commit.id.prefix(10)) · \(commit.author) <\(commit.email)> · \(commit.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(commit.changes.filter { $0.path == hotspot.path }.enumerated()), id: \.offset) { _, change in
                        Text(change.oldPath.map { "Renamed from \($0) · " } ?? "" ) + Text(change.isBinary ? "Binary" : "+\(change.additions ?? 0) / −\(change.deletions ?? 0)")
                    }
                }.padding(.vertical, 6).textSelection(.enabled)
            }
        }.padding(24).frame(minWidth: 760, minHeight: 480)
    }
}
