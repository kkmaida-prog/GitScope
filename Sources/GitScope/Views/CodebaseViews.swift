import SwiftUI
import GitScopeCore

private extension View {
    func panel() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
private func day(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .omitted) ?? "—" }

private struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(.teal) }.font(.caption)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

/// Leading author plus a share bar; used for folders and modules.
private struct OwnerSummary: View {
    let contributors: [AuthorContribution]
    var body: some View {
        if let leader = contributors.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(leader.email) · \(percent(leader.share)) of commits · \(contributors.count) authors").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: leader.share).accessibilityLabel("Leading author's share").accessibilityValue(percent(leader.share))
            }
        } else {
            Text("No eligible commits").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Structure

struct StructureView: View {
    @ObservedObject var model: RepositoryViewModel
    let metrics: RepositoryMetrics
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Whole-repository summary").font(.title2.bold())
            Text("Every folder level and module of the selected revision, with eligible history, ownership and legacy findings. Select a folder to drill down; select a file or finding to open its lines and commits.")
                .foregroundStyle(.secondary)
            Picker("Group by", selection: $mode) {
                Text("Folders").tag(0)
                Text("Modules").tag(1)
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            if mode == 0 { folderBrowser } else { moduleList }
        }
    }

    private var folder: FolderSummary? { metrics.structure.folders[model.structureFolder] ?? metrics.structure.root }

    @ViewBuilder private var folderBrowser: some View {
        if let folder {
            breadcrumb(folder.path)
            HStack(spacing: 12) {
                StatTile(title: "Files at revision", value: folder.currentFiles.formatted(), icon: "doc.on.doc")
                StatTile(title: "Size", value: bytes(folder.bytes), icon: "internaldrive")
                StatTile(title: "Commits", value: folder.commits.formatted(), icon: "arrow.triangle.branch")
                StatTile(title: "Line churn", value: folder.churn.formatted(), icon: "plus.forwardslash.minus")
                StatTile(title: "Legacy findings", value: folder.findings.formatted(), icon: "exclamationmark.triangle")
            }
            Text("Active \(day(folder.firstChange)) – \(day(folder.lastChange)) · counts include every subfolder").font(.caption).foregroundStyle(.secondary)
            ownership(folder)
            if !folder.subfolders.isEmpty { subfolders(folder) }
            if !folder.files.isEmpty { files(folder) }
            findings(in: folder)
            recentCommits(folder)
        }
    }

    private func breadcrumb(_ path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(metrics.structure.root?.name ?? "Repository") { model.structureFolder = "" }.buttonStyle(.link)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(part) { model.structureFolder = parts.prefix(index + 1).joined(separator: "/") }.buttonStyle(.link)
                }
            }
        }
    }

    private func ownership(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ownership of this folder").font(.title3.bold())
            if folder.contributors.isEmpty { Text("No eligible commits under the current shared filters.").foregroundStyle(.secondary) }
            ForEach(folder.contributors.prefix(6)) { author in
                HStack {
                    VStack(alignment: .leading) { Text(author.name).fontWeight(.medium); Text(author.email).font(.caption).foregroundStyle(.secondary) }.frame(width: 260, alignment: .leading)
                    ProgressView(value: author.share)
                    Text("\(author.commits) commits · \(percent(author.share)) · \(author.churn) churn").monospacedDigit().font(.caption).frame(width: 220, alignment: .trailing)
                }
            }
            if folder.contributors.count > 6 { Text("+ \(folder.contributors.count - 6) more authors").font(.caption).foregroundStyle(.secondary) }
        }.panel()
    }

    private func subfolders(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Subfolders").font(.title3.bold()).padding(.bottom, 10)
            ForEach(folder.subfolders, id: \.self) { path in
                if let child = metrics.structure.folders[path] {
                    Button { model.structureFolder = path } label: {
                        HStack(spacing: 14) {
                            Image(systemName: child.currentFiles == 0 ? "folder.badge.minus" : "folder").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(child.name).font(.system(.body, design: .monospaced))
                                OwnerSummary(contributors: child.contributors).frame(maxWidth: 360, alignment: .leading)
                            }
                            Spacer()
                            Text("\(child.currentFiles) files · \(child.commits) commits · \(child.churn.formatted()) churn").monospacedDigit().foregroundStyle(.secondary)
                            if child.findings > 0 { SignalCount(count: child.findings) }
                            Text(day(child.lastChange)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
            Text("Folders without files at this revision only have history.").font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
        }.panel()
    }

    private func files(_ folder: FolderSummary) -> some View {
        let hotspots = Dictionary(metrics.hotspots.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let findings = Dictionary(grouping: metrics.legacy.findings, by: \.path)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Files in this folder").font(.title3.bold()).padding(.bottom, 10)
            ForEach(folder.files, id: \.self) { path in
                Button { model.inspect(path: path) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.text").foregroundStyle(.teal)
                        Text(RepoPath.name(path)).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Spacer()
                        if let count = findings[path]?.count { SignalCount(count: count) }
                        Text("\(hotspots[path]?.frequency ?? 0) commits · \((hotspots[path]?.churn ?? 0).formatted()) churn").monospacedDigit().foregroundStyle(.secondary)
                        Text(hotspots[path]?.size.map(bytes) ?? "—").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }.panel()
    }

    @ViewBuilder private func findings(in folder: FolderSummary) -> some View {
        let prefix = folder.path.isEmpty ? "" : folder.path + "/"
        let scoped = metrics.legacy.findings.filter { $0.path.hasPrefix(prefix) }
        if !scoped.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Legacy findings here").font(.title3.bold()); Spacer(); Button("Open Legacy view") { model.selection = "Legacy" } }.padding(.bottom, 10)
                ForEach(scoped.prefix(15)) { finding in
                    FindingRow(finding: finding) { model.inspect(path: finding.path, line: finding.line) }
                    Divider()
                }
                if scoped.count > 15 { Text("Highest-scoring 15 of \(scoped.count).").font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
            }.panel()
        }
    }

    private func recentCommits(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent commits touching this folder").font(.title3.bold())
            if folder.recentCommits.isEmpty { Text("None under the current shared filters.").foregroundStyle(.secondary) }
            ForEach(folder.recentCommits.prefix(10)) { commit in
                CommitRow(commit: commit)
                Divider()
            }
        }.panel()
    }

    private var moduleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modules are folders with a project manifest (SwiftPM, Xcode, npm, Gradle, Maven, Cargo, Go, .NET, …) and SwiftPM targets in Sources/, Tests/ and Plugins/. Each file belongs to its deepest module.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(metrics.structure.modules) { module in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(module.name).font(.headline)
                        Text(module.root.isEmpty ? "(repository root)" : module.root).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open folder") { model.structureFolder = module.root; mode = 0 }
                    }
                    Text(module.kinds.joined(separator: " · ")).font(.caption).foregroundStyle(.teal)
                    HStack {
                        Text("\(module.currentFiles) files · \(bytes(module.bytes)) · \(module.commits) commits · \(module.churn.formatted()) churn · last change \(day(module.lastChange))")
                            .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if module.findings > 0 { SignalCount(count: module.findings) }
                    }
                    OwnerSummary(contributors: module.contributors).frame(maxWidth: 420, alignment: .leading)
                    if !module.dependencies.isEmpty {
                        DisclosureGroup("\(module.dependencies.count) declared dependencies and tools") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(module.dependencies, id: \.self) { dependency in
                                    Text("\(dependency.name)  \(dependency.version.isEmpty ? "unspecified" : dependency.version)  · \(dependency.kind.rawValue) · \(dependency.ecosystem)")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }.padding(.top, 4)
                        }
                    }
                }.panel()
            }
        }
    }
}

private struct SignalCount: View {
    let count: Int
    var body: some View {
        Label("\(count)", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            .help("\(count) legacy findings")
    }
}

/// Folder-level ownership summary shown below file ownership.
struct FolderOwnershipSection: View {
    let metrics: RepositoryMetrics
    let open: (String) -> Void
    var body: some View {
        let folders = metrics.structure.folders.values
            .filter { !$0.path.isEmpty && $0.path.split(separator: "/").count <= 2 && $0.commits > 0 }
            .sorted { $0.commits == $1.commits ? $0.path < $1.path : $0.commits > $1.commits }
        VStack(alignment: .leading, spacing: 8) {
            Text("Contribution concentration by folder").font(.title3.bold())
            Text("The same shares computed for the first two folder levels. Select a folder to open it in Structure.").font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folders) { folder in
                    Button { open(folder.path) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(folder.path + "/").font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(folder.commits) commits · \(folder.currentFiles) files").font(.caption).foregroundStyle(.secondary)
                            }
                            OwnerSummary(contributors: folder.contributors)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Dependencies

struct DependenciesView: View {
    @ObservedObject var model: RepositoryViewModel
    let metrics: RepositoryMetrics
    @State private var mode = 0
    @State private var query = ""
    @State private var kind: DependencyKind?
    @State private var includeRemoved = true
    @State private var selected: DependencySummary?
    @State private var transition: DependencyTransition?

    private var insights: DependencyInsights { metrics.dependencies }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dependency and tool history").font(.title2.bold())
            Text("Versions declared by manifests over time: libraries, frameworks, build tools, toolchains and platform targets. Each change is compared with the commit's own parent. Usage is matched from import statements at the selected revision.")
                .foregroundStyle(.secondary)
            if let warning = insights.warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack(spacing: 12) {
                StatTile(title: "Libraries", value: count(.library), icon: "shippingbox")
                StatTile(title: "Frameworks", value: count(.framework), icon: "square.stack.3d.up")
                StatTile(title: "Tools & toolchains", value: count(.tool), icon: "hammer")
                StatTile(title: "Manifests", value: insights.manifestPaths.count.formatted(), icon: "doc.plaintext")
                StatTile(title: "Changing commits", value: insights.transitions.count.formatted(), icon: "clock.arrow.circlepath")
            }
            if insights.summaries.isEmpty && insights.manifestPaths.isEmpty {
                ContentUnavailableView("No recognised manifests", systemImage: "shippingbox",
                                       description: Text("GitScope reads Package.swift/.resolved, Xcode projects, CocoaPods, Carthage, npm, pip/pyproject, Go, Cargo, Bundler, Gradle, Maven, .NET, Dockerfiles and tool-version files."))
            } else {
                Picker("Show", selection: $mode) {
                    Text("Dependencies").tag(0)
                    Text("Timeline of transitions").tag(1)
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                if mode == 0 { dependencyList } else { timeline }
            }
        }
        .sheet(item: $selected) { summary in DependencyInspector(summary: summary, insights: insights, model: model) }
        .sheet(item: $transition) { transition in TransitionInspector(transition: transition, model: model) }
    }

    private func count(_ kind: DependencyKind) -> String { insights.summaries.filter { $0.kind == kind && $0.isCurrent }.count.formatted() }

    private var filtered: [DependencySummary] {
        insights.summaries.filter { summary in
            (kind == nil || summary.kind == kind) && (includeRemoved || summary.isCurrent)
                && (query.isEmpty || summary.name.localizedCaseInsensitiveContains(query) || summary.ecosystem.localizedCaseInsensitiveContains(query))
        }
    }

    private var dependencyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Filter by name or ecosystem", text: $query).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag(DependencyKind?.none)
                    ForEach(DependencyKind.allCases, id: \.self) { value in Text(value.rawValue).tag(DependencyKind?.some(value)) }
                }.frame(width: 200)
                Toggle("Include removed", isOn: $includeRemoved)
            }
            VStack(spacing: 0) {
                HStack { Text("NAME"); Spacer(); Text("CURRENT · CHANGES · LAST CHANGE · USAGE") }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(12)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { summary in
                        Button { selected = summary } label: { DependencyRow(summary: summary) }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }
    }

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(insights.transitions) { transition in
                Button { self.transition = transition } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(transition.date.formatted(date: .abbreviated, time: .omitted)).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(transition.subject).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            if !transition.remainingUsages.isEmpty {
                                Label("\(transition.remainingUsages.count) old usages remain", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text(transition.changes.prefix(4).map(\.summary).joined(separator: " · ") + (transition.changes.count > 4 ? " · +\(transition.changes.count - 4) more" : ""))
                            .font(.callout).lineLimit(2)
                        Text("Modules: " + transition.changedModules.joined(separator: ", ") + " · \(transition.changedFiles.count) files · \(transition.author)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
}

private struct DependencyRow: View {
    let summary: DependencySummary
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: summary.kind == .tool ? "hammer" : summary.kind == .framework ? "square.stack.3d.up" : "shippingbox")
                .foregroundStyle(summary.isCurrent ? Color.teal : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.system(.body, design: .monospaced)).strikethrough(!summary.isCurrent)
                Text("\(summary.kind.rawValue) · \(summary.ecosystem)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.currentVersion).font(.system(.callout, design: .monospaced)).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
            Text("\(summary.changes.count) changes").monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(day(summary.lastChanged)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(summary.kind == .tool ? "—" : "\(summary.usages.count) uses").monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            if !summary.staleUsages.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("\(summary.staleUsages.count) usages predate the latest major change or removal") }
        }.padding(12).contentShape(Rectangle())
    }
}

private struct UsageRow: View {
    let usage: DependencyUsage
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(usage.path):\(usage.line)").font(.system(.callout, design: .monospaced))
                Text(usage.text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Text("Module " + usage.module).font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct DependencyInspector: View {
    let summary: DependencySummary
    let insights: DependencyInsights
    @ObservedObject var model: RepositoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var location: CodeLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(summary.name).font(.title2.bold()).textSelection(.enabled)
                    Text("\(summary.kind.rawValue) · \(summary.ecosystem) · \(summary.isCurrent ? "declared at this revision" : "no longer declared")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    current
                    history
                    usage
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(minWidth: 820, minHeight: 600)
        .sheet(item: $location) { location in CodeInspector(location: location, model: model) }
    }

    @ViewBuilder private var current: some View {
        Text("At the selected revision").font(.headline)
        if summary.current.isEmpty { Text("Not declared in any manifest.").foregroundStyle(.secondary) }
        ForEach(summary.current, id: \.self) { version in
            HStack { Text(version.path).font(.system(.callout, design: .monospaced)); Spacer(); Text(version.version.isEmpty ? "unspecified" : version.version).font(.system(.callout, design: .monospaced)) }
        }
        if !summary.distinctVersions.isEmpty {
            Text("Versions seen: " + summary.distinctVersions.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var history: some View {
        Text("History").font(.headline)
        if summary.changes.isEmpty { Text("No changes match the current shared filters.").foregroundStyle(.secondary) }
        ForEach(summary.changes.reversed()) { change in
            let transition = insights.transitions.first { $0.commit == change.commit }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(change.change.rawValue).fontWeight(.semibold).foregroundStyle(change.isMajor ? Color.orange : Color.primary)
                    Text(versionText(change)).font(.system(.callout, design: .monospaced))
                    if change.isMajor && change.change != .removed { Text("major").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                    Spacer()
                    Text(change.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
                Text("\(change.path) · \(String(change.commit.prefix(10)))" + (transition.map { " · " + $0.subject } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let transition, !transition.changedModules.isEmpty {
                    Text("Commit touched modules: " + transition.changedModules.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4).textSelection(.enabled)
            Divider()
        }
    }

    private func versionText(_ change: DependencyChange) -> String {
        let from = change.from.map { $0.isEmpty ? "unspecified" : $0 }, to = change.to.map { $0.isEmpty ? "unspecified" : $0 }
        switch change.change {
        case .added: return to ?? ""
        case .removed: return "was " + (from ?? "")
        default: return (from ?? "") + " → " + (to ?? "")
        }
    }

    @ViewBuilder private var usage: some View {
        if summary.kind != .tool {
            Text("Where it is used").font(.headline)
            Text("Import statements whose module name matches this dependency (a heuristic, not a build graph).").font(.caption).foregroundStyle(.secondary)
            if summary.usages.isEmpty { Text("No matching imports at this revision.").foregroundStyle(.secondary) }
            else { Text("Modules: " + summary.modulesUsing.joined(separator: ", ")).font(.callout) }
            if let reference = summary.referenceChange, !summary.staleUsages.isEmpty {
                let removed = reference.change == .removed && !summary.isCurrent
                let message: String = removed
                    ? "Still imported after its removal on \(day(reference.date)) (\(String(reference.commit.prefix(10)))):"
                    : "Files not changed since \(versionText(reference)) on \(day(reference.date)) — review them for old APIs:"
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                ForEach(summary.staleUsages) { usage in UsageRow(usage: usage) { open(usage) } }
                Divider()
            }
            ForEach(summary.usages.prefix(200)) { usage in UsageRow(usage: usage) { open(usage) } }
        }
    }

    private func open(_ usage: DependencyUsage) {
        guard let metrics = model.metrics else { return }
        location = CodeLocation(path: usage.path, line: usage.line, metrics: metrics)
    }
}

struct TransitionInspector: View {
    let transition: DependencyTransition
    @ObservedObject var model: RepositoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var location: CodeLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dependency transition").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            CommitRow(commit: Commit(id: transition.commit, author: transition.author, email: transition.email, date: transition.date, subject: transition.subject, changes: []))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Changes").font(.headline)
                    ForEach(transition.changes) { change in
                        HStack {
                            Text(change.summary).font(.system(.callout, design: .monospaced))
                            if change.isMajor && change.change != .added { Text("major").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                            Spacer()
                            Text("\(change.kind.rawValue) · \(change.path)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Modules touched by this commit").font(.headline)
                    Text(transition.changedModules.joined(separator: " · ")).font(.callout)
                    remaining
                    Text("Files changed in the same commit").font(.headline)
                    ForEach(transition.changedFiles, id: \.self) { path in
                        Button { open(path, nil) } label: {
                            Text(path).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(minWidth: 820, minHeight: 600)
        .sheet(item: $location) { location in CodeInspector(location: location, model: model) }
    }

    @ViewBuilder private var remaining: some View {
        Text("Where the old version is still used").font(.headline)
        Text("For a removed dependency: every import still present. For a major version change: imports in files not changed since this commit. Matching uses import names at the selected revision.")
            .font(.caption).foregroundStyle(.secondary)
        if transition.remainingUsages.isEmpty {
            Text("Nothing remains — or this transition was not a removal or major version change.").foregroundStyle(.secondary)
        }
        ForEach(transition.remainingUsages) { usage in UsageRow(usage: usage) { open(usage.path, usage.line) } }
    }

    private func open(_ path: String, _ line: Int?) {
        guard let metrics = model.metrics else { return }
        location = CodeLocation(path: path, line: line, metrics: metrics)
    }
}

// MARK: - Legacy

struct FindingRow: View {
    let finding: LegacyFinding
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(finding.path + (finding.line.map { ":\($0)" } ?? "")).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text("Module \(finding.module) · score \(finding.score)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) { ForEach(finding.signals, id: \.self) { signal in SignalBadge(kind: signal.kind) } }
                Text(finding.primary.detail).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let text = finding.text, !text.isEmpty {
                    Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct LegacyView: View {
    @ObservedObject var model: RepositoryViewModel
    let metrics: RepositoryMetrics
    @State private var kind: LegacySignalKind?
    @State private var query = ""
    @State private var editingRules = false

    private var legacy: LegacyInsights { metrics.legacy }
    private var filtered: [LegacyFinding] {
        legacy.findings.filter { finding in
            (kind == nil || finding.signals.contains { $0.kind == kind }) && (query.isEmpty || finding.path.localizedCaseInsensitiveContains(query) || finding.module.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Signs of legacy code").font(.title2.bold())
                Spacer()
                Button { editingRules = true } label: { Label("Rules…", systemImage: "slider.horizontal.3") }.disabled(model.isLoading)
            }
            Text("Places where deprecated APIs or removed dependencies remain, code that keeps changing after a migration began, and explicit legacy markers.")
                .foregroundStyle(.secondary)
            ForEach(legacy.warnings, id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, "All", legacy.findings.count)
                    ForEach(LegacySignalKind.allCases, id: \.self) { value in
                        let count = legacy.count(value)
                        if count > 0 { filterChip(value, value.rawValue, count) }
                    }
                }
            }
            TextField("Filter by path or module", text: $query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                ContentUnavailableView("No legacy signals", systemImage: "checkmark.seal",
                                       description: Text("Nothing matches the current rules, shared filters and selection. Add repository-specific rules with Rules…"))
            } else {
                Text("\(filtered.count) findings · ranked by signal strength · showing up to 500").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(500)) { finding in
                        FindingRow(finding: finding) { model.inspect(path: finding.path, line: finding.line) }
                        Divider()
                    }
                }
            }
        }
        .sheet(isPresented: $editingRules) { RuleEditor(settings: model.ruleSettings, apply: model.updateRules) }
    }

    private func filterChip(_ value: LegacySignalKind?, _ title: String, _ count: Int) -> some View {
        Button { kind = value } label: {
            Text("\(title) \(count)").font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(kind == value ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LegacyRuleSettings
    @State private var old = ""
    @State private var replacement = ""
    @State private var extensions = ""
    let apply: (LegacyRuleSettings) -> Void

    init(settings: LegacyRuleSettings, apply: @escaping (LegacyRuleSettings) -> Void) {
        _draft = State(initialValue: settings); self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Legacy rules").font(.title2.bold())
            Form {
                Section("Add a rule for this repository") {
                    TextField("Old API, type or call (literal text), e.g. LegacyClient(", text: $old)
                    TextField("Replacement (optional literal), e.g. APIClient(", text: $replacement)
                    TextField("File extensions (optional, comma-separated), e.g. swift, m", text: $extensions)
                    Button("Add rule") {
                        let rule = LegacyRule.custom(old: old, replacement: replacement, extensions: extensions.split(separator: ",").map { String($0) })
                        draft.custom.removeAll { $0.id == rule.id }
                        draft.custom.append(rule)
                        old = ""; replacement = ""; extensions = ""
                    }.disabled(old.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
                if !draft.custom.isEmpty {
                    Section("Repository rules") {
                        ForEach(draft.custom) { rule in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.title).font(.system(.body, design: .monospaced))
                                    Text((rule.replacement.map { "→ " + $0 } ?? "no replacement") + (rule.extensions.isEmpty ? "" : " · ." + rule.extensions.joined(separator: ", ."))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { draft.custom.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Built-in rules") {
                    ForEach(LegacyRules.builtIn) { rule in
                        Toggle(isOn: binding(for: rule.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                Text(rule.note + (rule.replacement.map { " Replacement: " + $0 + "." } ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Button("Restore defaults") { draft = LegacyRuleSettings() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply and rescan") { apply(draft); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 720)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !draft.disabledBuiltIns.contains(id) },
                set: { enabled in
                    draft.disabledBuiltIns.removeAll { $0 == id }
                    if !enabled { draft.disabledBuiltIns.append(id) }
                })
    }
}
