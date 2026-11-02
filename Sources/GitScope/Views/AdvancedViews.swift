import SwiftUI
import Charts
import GitScopeCore

struct OwnershipView: View {
    let metrics: RepositoryMetrics
    let inspect: (String) -> Void
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Who has changed this code?").font(.title2.bold())
            Text("Historical activity by author email. Commit shares are not a measure of expertise or a verified bus factor. Aliases are not merged through mailmap yet.").foregroundStyle(.secondary)
            if metrics.contributors.isEmpty { ContentUnavailableView("No eligible contributions", systemImage: "person.2") }
            Chart(Array(metrics.contributors.prefix(10))) { author in
                BarMark(x: .value("Commits", author.commits), y: .value("Email", author.email)).foregroundStyle(.teal.gradient)
            }.frame(height: CGFloat(max(1, min(10, metrics.contributors.count))) * 34)
            Text("Contributors").font(.title3.bold())
            ForEach(metrics.contributors) { author in
                HStack {
                    VStack(alignment: .leading) { Text(author.name).fontWeight(.medium); Text(author.email).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(author.commits) commits · \(author.share.formatted(.percent.precision(.fractionLength(1)))) of commits · \(author.churn) churn (\(author.churnShare.formatted(.percent.precision(.fractionLength(1)))))").monospacedDigit()
                }.padding(.vertical, 5)
                Divider()
            }
            Text("Contribution concentration by file").font(.title3.bold())
            Text("The leading author's share of eligible commits touching each file. Select a row to inspect the underlying history.").font(.caption).foregroundStyle(.secondary)
            TextField("Filter file paths", text: $query).textFieldStyle(.roundedBorder)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(metrics.ownership.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }) { file in
                    Button { inspect(file.path) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(file.path).font(.system(.body, design: .monospaced))
                            if let leader = file.contributors.first {
                                HStack { Text(leader.email); Spacer(); Text("\(leader.share.formatted(.percent.precision(.fractionLength(0)))) of commits · \(leader.churnShare.formatted(.percent.precision(.fractionLength(0)))) of churn · \(file.contributors.count) authors") }.font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: leader.share).accessibilityLabel("Leading author's share").accessibilityValue(leader.share.formatted(.percent))
                            }
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}
struct CouplingView: View {
    let metrics: RepositoryMetrics
    let inspect: (CouplingPair) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Files that change together").font(.title2.bold())
            Text("Support = joint commits / all eligible commits. Confidence A → B = joint commits / commits touching A. A pair passes when either direction meets the shared confidence threshold. Co-change suggests an association, not a verified dependency.").foregroundStyle(.secondary)
            if metrics.couplingLimited {
                Label("Coupling was withheld because a commit exceeded 100 scoped files or the run exceeded 100,000 candidate pairs / 1,000,000 pair events. Narrow the shared filters or lower the bulk limit.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if metrics.coupling.isEmpty {
                ContentUnavailableView("No pairs meet these thresholds", systemImage: "link", description: Text("Adjust minimum joint commits or confidence in Shared filters."))
            } else {
                Text("\(metrics.coupling.count) qualifying pairs · showing up to 500").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(metrics.coupling.prefix(500)) { pair in
                        Button { inspect(pair) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(pair.first, systemImage: "a.circle").font(.system(.body, design: .monospaced))
                                Label(pair.second, systemImage: "b.circle").font(.system(.body, design: .monospaced))
                                Text("\(pair.jointCommits) joint commits · Support \(pair.support.formatted(.percent.precision(.fractionLength(1)))) · A → B \(pair.confidenceForward.formatted(.percent.precision(.fractionLength(1)))) · B → A \(pair.confidenceReverse.formatted(.percent.precision(.fractionLength(1))))").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }
}
struct CouplingInspector: View {
    let pair: CouplingPair
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Co-change evidence").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(pair.first + "\n" + pair.second).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("\(pair.jointCommits) eligible commits changed both files.").foregroundStyle(.secondary)
            List(pair.commits) { commit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject).fontWeight(.medium)
                    Text("\(commit.id.prefix(10)) · \(commit.author) <\(commit.email)> · \(commit.date.formatted())").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6).textSelection(.enabled)
            }
        }.padding(24).frame(width: 780, height: 500)
    }
}
