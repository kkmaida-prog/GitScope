import SwiftUI
import GitScopeCore

struct FilterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AnalysisOptions
    @State private var useStart: Bool
    @State private var useEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var patterns: String
    let apply: (AnalysisOptions) -> Void
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }
    init(options: AnalysisOptions, snapshot: RepositorySnapshot, apply: @escaping (AnalysisOptions) -> Void) {
        _draft = State(initialValue: options); _useStart = State(initialValue: options.since != nil); _useEnd = State(initialValue: options.until != nil)
        _start = State(initialValue: options.since ?? snapshot.commits.map(\.date).min() ?? Date())
        _end = State(initialValue: options.until.map { $0.addingTimeInterval(-1) } ?? snapshot.commits.map(\.date).max() ?? Date())
        _patterns = State(initialValue: options.excludedPatterns.joined(separator: "\n")); self.apply = apply
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared analysis filters").font(.title2.bold())
            Text("Every view uses these rules. Dates use UTC; the end day is included.").font(.caption).foregroundStyle(.secondary)
            Form {
                Section("Time range") {
                    Toggle("Start day", isOn: $useStart)
                    if useStart { DatePicker("From", selection: $start, displayedComponents: .date) }
                    Toggle("End day", isOn: $useEnd)
                    if useEnd { DatePicker("Through", selection: $end, displayedComponents: .date) }
                }
                Section("Scope") {
                    TextField("Author name or email contains", text: $draft.authorQuery)
                    TextField("Path contains", text: $draft.pathQuery)
                    TextField("File extension, e.g. swift", text: $draft.fileExtension)
                    Stepper("Bulk limit: \(draft.maximumFilesPerCommit == 0 ? "disabled" : "\(draft.maximumFilesPerCommit) files")", value: $draft.maximumFilesPerCommit, in: 0...500, step: 10)
                    Text("Commits above the bulk limit are omitted before path filtering. Merge commits are always excluded.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Excluded path globs — one per line") {
                    TextEditor(text: $patterns).font(.system(.body, design: .monospaced)).frame(height: 70)
                    Text(verbatim: "Examples: vendor/*, *.lock, */generated/*. Asterisk matches across folders. Empty means no path exclusions.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Coupling thresholds") {
                    Stepper("Minimum joint commits: \(draft.minimumJointCommits)", value: $draft.minimumJointCommits, in: 1...100)
                    Slider(value: $draft.minimumConfidence, in: 0...1) { Text("Minimum directional confidence") }
                    Text("At least one direction must reach \(draft.minimumConfidence.formatted(.percent.precision(.fractionLength(0)))).").font(.caption)
                }
            }.formStyle(.grouped).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            HStack {
                Button("Reset") { apply(AnalysisOptions()); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to all views") {
                    draft.since = useStart ? Self.utc.startOfDay(for: start) : nil
                    draft.until = useEnd ? Self.utc.date(byAdding: .day, value: 1, to: Self.utc.startOfDay(for: end)) : nil
                    draft.excludedPatterns = patterns.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft.authorQuery = draft.authorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.pathQuery = draft.pathQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    apply(draft); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 740)
    }
}
