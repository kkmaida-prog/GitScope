import SwiftUI
import GitScopeCore

/// A file (optionally a line) to inspect, with the findings and eligible commits for that file.
struct CodeLocation: Identifiable {
    let id = UUID()
    let path: String
    let line: Int?
    let module: String?
    let findings: [LegacyFinding]
    let commits: [Commit]
    let firstSeen: Date?
    let lastChanged: Date?
    init(path: String, line: Int?, metrics: RepositoryMetrics) {
        self.path = path; self.line = line
        let findings = metrics.legacy.findings.filter { $0.path == path }.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
        self.findings = findings
        commits = metrics.hotspots.first { $0.path == path }?.commits ?? findings.first?.commits ?? []
        module = findings.first?.module ?? metrics.structure.modules.filter { $0.root.isEmpty || path.hasPrefix($0.root + "/") }.max { $0.root.count < $1.root.count }?.name
        firstSeen = findings.first?.firstSeen; lastChanged = findings.first?.lastChanged
    }
}

extension LegacySignalKind {
    var color: Color {
        switch self {
        case .deprecatedAPI: return .red
        case .removedDependency: return .pink
        case .changingAfterMigration: return .orange
        case .notRevisitedAfterUpgrade: return .yellow
        case .deprecationMarker: return .purple
        case .legacyMarker: return .indigo
        case .legacyPath: return .blue
        case .fileAge: return .gray
        }
    }
    var icon: String {
        switch self {
        case .deprecatedAPI: return "exclamationmark.octagon"
        case .removedDependency: return "shippingbox"
        case .changingAfterMigration: return "arrow.triangle.2.circlepath"
        case .notRevisitedAfterUpgrade: return "clock.arrow.circlepath"
        case .deprecationMarker: return "tag"
        case .legacyMarker: return "text.bubble"
        case .legacyPath: return "folder"
        case .fileAge: return "hourglass"
        }
    }
}

struct SignalBadge: View {
    let kind: LegacySignalKind
    var body: some View {
        Label(kind.rawValue, systemImage: kind.icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.color.opacity(0.16), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

/// Each signal with its concrete evidence text.
struct SignalList: View {
    let signals: [LegacySignal]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(signals, id: \.self) { signal in
                VStack(alignment: .leading, spacing: 4) {
                    SignalBadge(kind: signal.kind)
                    Text(signal.detail).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

struct CommitRow: View {
    let commit: Commit
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject).fontWeight(.medium).lineLimit(2)
            Text("\(String(commit.id.prefix(10))) · \(commit.author) <\(commit.email)> · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4).textSelection(.enabled)
    }
}

/// Source lines at the pinned revision around a finding, the commit that last changed the line,
/// the file's other findings and its eligible commits.
struct CodeInspector: View {
    let location: CodeLocation
    let model: RepositoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var focus: Int?
    @State private var context: CodeContext?
    @State private var loadError: String?
    @State private var loading = false

    init(location: CodeLocation, model: RepositoryViewModel) {
        self.location = location; self.model = model
        _focus = State(initialValue: location.line)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Code evidence").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(location.path + (focus.map { ":\($0)" } ?? "")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(facts).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        findingsSection
                        commitsSection
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 400)
                Divider()
                codeSection.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(24).frame(minWidth: 1000, minHeight: 640)
        .task(id: focus) { await load() }
    }

    private var facts: String {
        var parts: [String] = []
        if let module = location.module { parts.append("Module " + module) }
        if let first = location.firstSeen { parts.append("first recorded " + first.formatted(date: .abbreviated, time: .omitted)) }
        if let last = location.lastChanged { parts.append("last changed " + last.formatted(date: .abbreviated, time: .omitted)) }
        parts.append("\(location.commits.count) eligible commits")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var findingsSection: some View {
        Text("Findings in this file").font(.headline)
        if location.findings.isEmpty {
            Text("No legacy signals were found in this file with the current rules and filters.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(location.findings) { finding in
            Button { focus = finding.line } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.line.map { "Line \($0)" } ?? "Whole file").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    SignalList(signals: finding.signals)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(finding.line == focus && focus != nil ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var commitsSection: some View {
        Text("Commits that changed this file").font(.headline)
        if location.commits.isEmpty { Text("No eligible commits under the current shared filters.").font(.callout).foregroundStyle(.secondary) }
        ForEach(location.commits.prefix(100)) { commit in
            CommitRow(commit: commit)
            Divider()
        }
        if location.commits.count > 100 { Text("Showing the 100 most recent of \(location.commits.count).").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var codeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(focus == nil ? "Beginning of file at the selected revision" : "Lines around the finding at the selected revision").font(.headline)
            if loading && context == nil { ProgressView().controlSize(.small) }
            if let loadError {
                Label("The file could not be read at this revision: \(loadError)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let context {
                if let blame = context.blame {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Line \(focus ?? 0) was last changed by").font(.caption).foregroundStyle(.secondary)
                        Text(blame.summary).fontWeight(.medium)
                        Text("\(String(blame.commit.prefix(10))) · \(blame.author) <\(blame.email)> · \(blame.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
                }
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(context.lines, id: \.line) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(line.line)").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(.callout, design: .monospaced))
                            .padding(.vertical, 2).padding(.trailing, 12)
                            .background(line.line == focus ? Color.orange.opacity(0.18) : Color.clear)
                        }
                    }.textSelection(.enabled).padding(8)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
        }
    }

    private func load() async {
        loading = true; loadError = nil
        do { context = try await model.context(path: location.path, line: focus) }
        catch is CancellationError { }
        catch { loadError = error.localizedDescription; context = nil }
        loading = false
    }
}
