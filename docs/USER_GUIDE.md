# GitScope User and Implementation Guide

Version: Milestone 2

Prepared: 1 November 2026

Audience: the project owner, app users and developers reviewing the implementation

This guide explains what has been built, how to run and use GitScope, how its results are calculated, and what remains unfinished. It describes the current implementation rather than every feature proposed in the original project documents.

## Contents

1. What GitScope does
2. What was implemented
3. Requirements and project files
4. Build and launch the app
5. Create a demonstration repository
6. Open and refresh a repository
7. Read the Overview dashboard
8. Explore hotspots
9. Explore ownership
10. Explore change coupling
11. Use shared filters
12. Follow a complete demonstration
13. Understand local storage and privacy
14. Understand the code and algorithms
15. Run tests and understand the evidence
16. Troubleshooting
17. Remaining work and completion estimate
18. Glossary

## 1. What GitScope does

GitScope is a native macOS application written in Swift and SwiftUI. It reads the committed history of a local Git repository and turns it into information about project activity, frequently changed files, contributor activity and files that change together.

The current app has four connected views:

| View | Question it helps answer |
|---|---|
| Overview | How active is this repository, and when did changes happen? |
| Hotspots | Which historical file paths changed most frequently? |
| Ownership | Who contributed to the selected history, and how concentrated was activity? |
| Coupling | Which files were frequently changed in the same commits? |

You can select a local branch and apply one shared set of filters to these views. GitScope reads repository data locally. It does not create commits, switch the working branch, edit source files or push changes.

This is an intermediate development build. It is useful for demonstrations and exploration, but it is not a completed commercial application or a fully evaluated research system.

## 2. What was implemented

### First milestone

The first version established the complete path from selecting a repository to viewing real metrics:

- A real macOS Xcode project and shared GitScope scheme.
- A native SwiftUI interface with sidebar navigation and Swift Charts.
- A folder picker and validation of local working-tree repositories.
- Git CLI execution through Foundation.Process using argument arrays.
- Parsing of commit IDs, author names and emails, committer dates, subjects, changed paths and added/deleted lines.
- Handling of binary changes, unusual filenames and rename events.
- An Overview dashboard and monthly commit activity chart.
- Basic file hotspots with frequency, churn and current byte size.
- A file inspector with supporting commits and rename evidence.
- Background processing, a loading state, cancellation and error messages.
- Separate models, services, analysis logic, view models and views.
- Eight automated tests, including a real Git fixture.

### Second milestone

The second version extended that foundation:

- Local SQLite persistence with versioned snapshot records.
- Cache reuse when the selected revision has not changed.
- Incremental ingestion when a non-shallow branch advances from a cached ancestor.
- Full rebuilds after history rewrites, missing old objects or shallow-status changes.
- Local branch selection without checking out a branch.
- Shared UTC date, author, path and extension filters.
- Configurable path exclusions and bulk-commit suppression.
- Saved analysis options for each repository.
- Recent repositories using read-only security-scoped bookmarks.
- Top-level directory activity on Overview.
- Contributor charts and commit/churn shares.
- Contribution concentration by historical file path.
- Coupling counts, support, directional confidence and an evidence inspector.
- Bounds on coupling work to avoid presenting misleading partial rankings.
- Fourteen more automated tests, bringing the suite to 22.
- A richer demo-repository script and an updated verification script.
- A native UI walkthrough with real interaction, followed by a restart/cache check.

Technical documentation and validation records were also added to the project.

## 3. Requirements and project files

The project targets macOS 14 or later. Development was performed on Apple Silicon with Xcode 27.1 and Swift 6.4. Runtime compatibility with macOS 14 hardware and Intel Macs has not yet been verified.

You need Xcode to use the main development workflow and a working `/usr/bin/git`, normally supplied by Xcode or Command Line Tools. The project uses Apple frameworks and system SQLite; it does not require third-party Swift packages or a server.

Extract `GitScope-Milestone2.zip`. The extracted `GitScope` folder contains:

```text
GitScope/
├── GitScope.xcodeproj/       Real Xcode project and shared scheme
├── GitScope.entitlements    Sandbox and read-only access settings
├── Package.swift            Alternative Swift package build
├── Sources/
│   ├── GitScope/            App entry point, views and view model
│   └── GitScopeCore/        Models, services and analysis
├── Tests/                   Core unit and integration tests
├── scripts/
│   ├── create-demo.sh       Creates a disposable demo repository
│   └── verify.sh            Builds tests, runs XCTest and builds the app
├── Validation/              Recorded build, test and coverage evidence
├── README.md                Quick start
├── ARCHITECTURE.md          Detailed engineering explanation
├── VALIDATION.md            Executed and outstanding checks
└── MILESTONE_STATUS.md      Completed and remaining scope
```

The archive is a source project. It is not a notarized installer or an App Store release.

## 4. Build and launch the app

1. Open the extracted `GitScope` folder in Finder.
2. Open `GitScope.xcodeproj` in Xcode.
3. Select the **GitScope** scheme in the toolbar.
4. Select **My Mac** as the destination.
5. If Xcode requests signing configuration, open the GitScope app target’s **Signing & Capabilities** settings and select your development team.
6. Choose **Product → Run**, or press **⌘R**.
7. Wait for the app to build and open.

The initial window offers **Choose Repository…**. The toolbar also contains **Open Repository** and **Refresh**. The repository-opening shortcut is **⌘O**.

The Xcode target includes App Sandbox, user-selected read-only file access and bookmark entitlements. Signed sandbox behavior still needs dedicated verification; the completed UI walkthrough used an unsigned development build.

For ordinary use, keep the Xcode project as the primary workflow. The package executable is an alternative development route and does not use the Xcode app bundle’s sandbox entitlements.

## 5. Create a demonstration repository

A small prepared repository is the easiest way to learn the interface and check expected numbers.

1. Open Terminal.
2. Type `cd `, including the trailing space.
3. Drag the extracted `GitScope` folder from Finder into Terminal to insert its path.
4. Press Return.
5. Run:

```sh
bash scripts/create-demo.sh
```

The script prints a newly created temporary folder. Copy that path. The script creates a fresh fixture; it does not change any existing repository.

The fixture contains:

- A `main` branch with three commits in January, February and April 2026.
- Two author identities.
- `Sources/Counter.swift`, `Sources/Report.swift` and `README.md` on main.
- A `feature` branch with one additional commit and `Experiment.txt`.
- A March gap in the activity chart.

The temporary path changes each time the script runs. Temporary folders are not permanent project storage; recreate the fixture if macOS removes it.

## 6. Open and refresh a repository

### Open a local repository

1. Click **Choose Repository…** or **Open Repository**.
2. Select the repository’s root folder: the folder containing its working files and Git metadata.
3. Click **Open**.
4. Wait for analysis to finish.

Choose a repository with at least one commit. Empty and bare repositories are not supported in this milestone. Uncommitted changes are ignored.

A shallow clone produces a visible incomplete-history warning. The app can analyze only the locally available history.

### Understand the selected revision

The header displays a shortened object ID. This is the pinned revision used for the history and current file tree in that analysis.

The initial branch is local `main` when it exists; otherwise GitScope uses the working tree’s `HEAD`. Use the **Branch** picker to analyze another local branch. This reads another revision without changing the branch checked out in your working directory.

### Refresh

Click the circular-arrow **Refresh** toolbar button after you create new commits or change local references outside GitScope.

| Status | Meaning |
|---|---|
| Full import | GitScope read the eligible history again |
| Cache hit | The revision and shallow state match cached data; no commit extraction was needed |
| Incremental import | GitScope imported newly reachable non-merge commits after validating ancestry |

The “commits read” value describes new extraction for that load. It is different from the total and eligible commit counts.

### Recent repositories and cancellation

Successfully opened repositories appear in the sidebar’s recent list, up to eight entries. Clicking one attempts to restore read-only access and open it again.

While analysis is running, **Cancel** requests cancellation. The previous complete result remains available. Git subprocesses are terminated when cancellation is observed. Pure metric computation can finish before the loading overlay disappears; immediate interruption of every computation is not implemented.

## 7. Read the Overview dashboard

### Summary cards

| Card | Meaning |
|---|---|
| Commits | Eligible commits after the active shared filters |
| Authors | Distinct lowercased author emails in those commits |
| Files at revision | Git blobs at the selected revision after path, extension and exclusion rules |
| Line churn | Numeric added lines plus deleted lines in eligible changes |

The current file count is not the number of files that existed at the end of a selected historical date range. Date and author filters affect activity; the tree and byte sizes remain those of the pinned revision.

An author count is an email-identity count, not a guaranteed count of unique people. One person using multiple emails can appear more than once.

### Monthly activity

The chart counts eligible commits by **committer month in UTC**. Months with no commits are included between the first and last eligible month, making gaps visible.

The chart currently shows monthly commit activity only. It does not show historical lines of code, historical tree size, layered author trends or interactive range dragging.

Below the chart, the app reports total additions, deletions and binary change events. Binary changes contribute no invented line counts.

### Directory activity and hotspots preview

Directory activity groups changes by top-level folder. Files directly in the repository root appear under `(root)`. A commit touching several files in one directory counts once for that directory; churn still sums their changes.

The hotspot preview shows the most frequently changed historical paths. Choose **View all hotspots** for the complete ranking.

## 8. Explore hotspots

1. Select **Hotspots** in the sidebar.
2. Review the file ranking.
3. Optionally enter text in **Filter by path** to search the displayed list.
4. Select a file to open its history inspector.
5. Review its supporting commit subjects, IDs, authors, dates and line changes.
6. Click **Done** to return.

The rows show commit frequency, churn and current size in bytes. Ranking uses:

1. More distinct commits first.
2. Higher churn when frequencies tie.
3. Path order when both values tie.

A frequently changed file is a candidate for investigation. It is not automatically defective, fragile or technical debt.

A dash in the size column means that historical path has no corresponding blob at the selected revision. It does not mean a zero-byte file.

Rename events retain their old and new paths in the evidence, but the ranking does not yet merge stable file identities across renames. An old name and a new name can therefore appear separately.

The Hotspots page’s search field only narrows its displayed rows. Use **Shared filters → Path contains** to change the analysis scope across every view.

## 9. Explore ownership

1. Select **Ownership**.
2. Use the chart to compare the leading contributors by eligible commit count.
3. Read the contributor rows for commit counts, commit shares, churn and churn shares.
4. Review **Contribution concentration by file**.
5. Filter file rows if needed and select a row to inspect its supporting file history.

The chart displays up to the top ten contributors. Contributor rows and file concentration use the same shared analysis scope as Overview.

Commit share is:

```text
Author's eligible commits / all eligible commits
```

Churn share is:

```text
Author's numeric changed lines / all numeric changed lines
```

For a file row, both denominators are restricted to that file. The leading contributor is selected by commit frequency. Their churn share can be different from their commit share.

For example, an author who made two of three file commits has a 66.7% commit share. That does not imply they changed 66.7% of the lines.

These values describe recorded activity. They do not establish expertise, current responsibility or a verified bus factor. Mailmap and manual author-alias merging are not implemented yet.

## 10. Explore change coupling

1. Select **Coupling**.
2. Review pairs of files that passed the current thresholds.
3. Read the joint commit count, support and the two directional confidences.
4. Select a pair to open **Co-change evidence**.
5. Review the commits that changed both files.

Suppose A changed in 10 eligible commits, B in 4, and they changed together in 3 of 20 total eligible commits:

```text
Joint commits       = 3
Support             = 3 / 20 = 15%
Confidence A → B    = 3 / 10 = 30%
Confidence B → A    = 3 / 4  = 75%
```

The different confidences answer different questions. A change to B was more often accompanied by A than a change to A was accompanied by B.

The default thresholds are at least **two joint commits** and **20% confidence in at least one direction**. Adjust them in Shared filters. A pair must satisfy both the joint-count rule and the confidence rule.

No qualifying pairs can be a valid result, especially after applying a narrow date, author or path scope. It does not prove that the code has no dependencies.

The app withholds the entire coupling result when a scoped commit exceeds 100 files, candidate pairs exceed 100,000, or pair events exceed 1,000,000. This avoids publishing partial rankings as though they were complete. Narrow the scope or lower the bulk limit. Other metrics remain available. The interface renders up to 500 qualifying pairs and displays the total count.

Co-change indicates a historical association. It does not prove a static dependency or causal relationship.

## 11. Use shared filters

Click **Shared filters** above the selected view. Change your settings and choose **Apply to all views**. **Cancel** discards edits; **Reset** applies the default analysis settings.

| Control | How to use it |
|---|---|
| Start day | Enable it to include activity from that UTC day onward |
| End day | Enable it to include activity through that UTC day |
| Author | Match text in an author name or email, case-insensitively |
| Path | Include changed paths containing the entered text |
| File extension | Enter an extension such as `swift`; matching is case-insensitive |
| Bulk limit | Exclude commits whose original changed-path count exceeds the limit; zero disables this rule |
| Excluded path globs | Enter one exclusion pattern per line |
| Minimum joint commits | Set the minimum count for a coupling pair |
| Minimum confidence | Set the required confidence in at least one direction |

Example exclusion patterns:

```text
vendor/*
*.lock
*/generated/*
```

In this implementation, `*` can match across folder separators. Exclusions are evaluated against the changed path recorded for the event; they are not a complete stable-identity filter across renames.

The bulk rule runs **before** path filtering. A commit changing 200 files is excluded by a limit of 50 even if just one of those files matches your path filter. The default bulk limit is 50.

The interface uses inclusive UTC days. Internally, an end day is converted to an exclusive boundary at the start of the next UTC day.

If all of a commit’s changed paths are removed, that commit no longer contributes to activity. Truly empty commits remain only when no path/type/exclusion scope is active.

Settings persist per repository and are reapplied when it is reopened. Always check the visible scope summary before interpreting results.

## 12. Follow a complete demonstration

Use the generated fixture for this walkthrough.

| Step | Action | Expected result |
|---|---|---|
| 1 | Open the printed demo folder | Main branch selected |
| 2 | View Overview | 3 commits, 2 author emails, 3 files, 11 churn |
| 3 | Inspect activity | One commit each in January, February and April; zero in March |
| 4 | Open Hotspots | Both Swift files have 3 commits and 5 churn |
| 5 | Open Ownership | First contributor: 2 commits; second: 1 |
| 6 | Open Coupling | Counter.swift and Report.swift: 3 joint commits, 100% support, 100% both directions |
| 7 | Select that pair | Inspector lists all three supporting commits |
| 8 | Set Author to `second@example.test` | One eligible commit remains |
| 9 | Check Overview and Coupling | Overview: 1 commit and 3 churn; Coupling: no pair meets the default two-commit minimum |
| 10 | Reset filters | Full main-branch metrics return |
| 11 | Select feature | 4 commits, 4 files and 12 churn |
| 12 | Click Refresh | Cache hit; 0 newly read commits |
| 13 | Restart the app and select the recent demo | Cached main analysis opens again |

Changing the analysis branch does not check it out. The generated repository stays on main unless you change it yourself using another tool.

## 13. Understand local storage and privacy

The app has no network client, telemetry or source-upload feature. Its analysis commands are read-only. It does not write its cache or preferences into the selected repository.

The local SQLite cache is stored at the app’s Application Support location under:

```text
GitScope/history-v2.sqlite
```

A sandboxed build uses its application container’s storage. An unsandboxed development executable uses its own normal Application Support context, so exact locations can differ.

Cached metadata includes commit messages, author identities, changed paths, line counts and revision file sizes. Local-only processing does not mean that no metadata is retained on disk.

UserDefaults stores analysis settings and up to eight recent repositories. Recents use read-only security-scoped bookmarks. If access expires, reopen the repository through the folder picker.

Signed sandbox permissions, bookmark expiry and external object-store access still require dedicated testing. No network traffic audit has been completed; the implementation contains no network client, but that is distinct from a measured traffic-monitoring result.

## 14. Understand the code and algorithms

### Separation of responsibilities

```text
SwiftUI views
    ↓ user actions
RepositoryViewModel
    ↓ background import
GitRepositoryService
    ├── GitCommandRunner → fixed Git executable
    ├── HistoryParser → typed commits and changes
    └── RepositoryCache → SQLite snapshots
    ↓ shared filter options
AnalysisEngine and AdvancedAnalysis
    ↓ immutable results
Overview, Hotspots, Ownership and Coupling
```

| Component | Responsibility |
|---|---|
| Models | Commit/change/snapshot/options/metric data structures |
| GitCommandRunner | Execute fixed Git commands, collect bounded output and handle cancellation/timeouts |
| HistoryParser | Decode NUL-separated metadata, numstat and tree records |
| GitRepositoryService | Validate repositories, select revisions and coordinate cache/import decisions |
| RepositoryCache | Read and atomically publish versioned SQLite snapshots |
| AnalysisOptions | Apply shared date, author, path, extension, exclusion and bulk rules |
| AnalysisEngine | Overview activity, hotspot frequency, churn and monthly buckets |
| AdvancedAnalysis | Contributors, file concentration, directory activity and coupling |
| RepositoryViewModel | Coordinate background work and publish complete UI state on the main actor |
| Views | Display information and provide native controls and inspectors |

### Why NUL-separated parsing matters

Filenames can contain spaces, Unicode, tabs and newlines. Splitting Git output into ordinary lines would misread some valid paths. GitScope uses a versioned NUL-separated protocol and splits numstat records only at their first two tabs. Rename records preserve separate old/new paths. Binary counts remain unknown rather than becoming false zero-line measurements.

### Cache decisions

1. Resolve the selected reference to a pinned commit ID and check shallow status.
2. Read the cache entry for the repository and reference.
3. Reuse it when the revision and shallow status match.
4. Otherwise, check whether the cached non-shallow revision is an ancestor of the new non-shallow revision.
5. If so, read only newly reachable non-merge commits, deduplicate IDs, and read the new revision’s file tree.
6. If ancestry cannot be established, rebuild the raw snapshot.
7. Save a complete snapshot inside a SQLite transaction.
8. Recompute the filtered metrics and publish them to the UI.

The current database stores a complete Codable snapshot in each versioned row. It is not yet the fully normalized event database proposed in the original architecture document. Incremental ingestion reduces Git extraction, but a changed snapshot is still serialized in full and metrics are recomputed.

### Read-only command execution

GitScope uses a fixed `/usr/bin/git` executable with argument arrays, not a shell command assembled from repository content. Its commands are rev-parse, for-each-ref, merge-base, log and ls-tree.

The runner disables hooks, fsmonitor, external diffs, text conversion, replacement objects, prompts, lazy fetching and optional locks, and ignores system/global Git configuration. Repository-local configuration and attributes can still affect Git semantics.

Subprocess output is written to temporary files to avoid pipe deadlocks. Limits are 120 seconds per command, 128 MiB standard output and 1 MiB standard error. These are guardrails, not a guarantee of a particular peak-memory usage. The current parser and aggregation still hold data in memory.

### Important history policies

- Merge commits are always excluded.
- Non-merge commits from merged branches remain eligible.
- Changes recorded only as merge conflict resolution are omitted.
- Activity uses committer dates; identities use author name/email.
- File sizes are bytes at the selected revision, not lines of code.
- Historical paths remain separate across renames.
- Shallow repositories are visibly marked incomplete.
- Invalid UTF-8 and malformed output fail explicitly instead of publishing partial metrics.

## 15. Run tests and understand the evidence

From the extracted project directory in Terminal, run:

```sh
bash scripts/verify.sh
```

The script builds coverage-instrumented package tests, explicitly executes their XCTest bundle, and builds the native Xcode application without requiring a signing identity. By default, build output goes into `.build-verification`.

The final recorded run on 1 November 2026 passed **22 tests with zero failures** and built the Debug arm64 app successfully.

The tests cover parsing, unusual filenames, binary and rename records, malformed data, tree sizes, metrics, filter boundaries, ownership shares, coupling formulas, SQLite isolation/rollback/cancellation, branch selection, cache reuse, incremental import, history rewrites, corrupt cache payloads and shallow-history changes.

Production line coverage in that run was:

| Component | Line coverage |
|---|---:|
| AnalysisEngine | 100% |
| AdvancedAnalysis | 91.53% |
| AnalysisOptions | 92.73% |
| HistoryParser | 96.61% |
| RepositoryCache | 93.26% |
| GitRepositoryService | 83.33% |

Coverage measures executed code, not correctness for every possible input. The report’s overall total also includes test/generated sources and must not be described as whole-product coverage.

The native UI walkthrough verified repository selection, Overview values, ownership, coupling evidence, shared author filters, branch switching, refresh cache hits and reopening a recent repository after restart.

The Xcode test-manager route compiled the tests but could not execute them because this agent environment denied access to `com.apple.testmanagerd.control`. The successful evidence is the explicitly executed package XCTest bundle, not a passing native Xcode test-manager session.

The verification script disables compiler-plugin sandboxing for compatibility with restricted build environments. This does not disable the built application’s sandbox entitlements.

## 16. Troubleshooting

| Symptom | Explanation and next action |
|---|---|
| Xcode requests a signing team | Select your development team in the app target’s Signing & Capabilities settings, then run again |
| Git cannot be launched | Check `/usr/bin/git --version` in Terminal and confirm your Xcode/Command Line Tools setup |
| Folder is rejected | Select a working-tree repository root with at least one readable commit |
| A recent repository cannot reopen | Its bookmark or location may have changed; use Open Repository and select it again |
| History warning appears | The repository is shallow; GitScope cannot analyze history that is not available locally |
| Counts are lower than Git log | Check merge exclusion, the 50-file default bulk limit, date/author/path filters and branch selection |
| Current file count does not change with dates | It describes the selected revision’s tree, not historical size at the selected date |
| Ownership shows the same person twice | Different author emails are not yet merged through mailmap or manual aliases |
| A renamed file appears twice | Stable identity stitching across renames is unfinished; historical paths remain separate |
| No coupling pairs appear | The current scope may not meet joint-count/confidence thresholds; inspect Shared filters |
| Coupling is withheld | Narrow the scope or lower the bulk limit to stay within the stated computation bounds |
| Cache warning appears | Live analysis can still succeed; the app may re-import because cached data is unavailable or invalid |
| A selected branch disappears | Reopen or refresh the repository and select an existing local branch |
| Analysis reaches a limit | Try a smaller repository; the current command/output guardrails are intentionally bounded |
| Cancel takes time during metrics | The result will not be published, but pure aggregation may finish before the overlay clears |
| A linked worktree fails permission checks | Its Git objects may be outside the selected folder; this access case is not fully supported or verified |

When manually checking commit totals, use the same pinned revision and merge policy. A read-only reference command is:

```sh
git -C "/path/to/repository" rev-list --count --no-merges REVISION
```

Replace the example path and `REVISION` with your values. This gives the unfiltered non-merge count; bulk/path/author/date filters can legitimately reduce GitScope’s eligible count.

## 17. Remaining work and completion estimate

The current release is approximately **45–55% of the application implementation**, excluding research and thesis writing. “About 50%” is a planning estimate based on working feature groups. It is not a measured completion percentage, and it does not mean that the original final acceptance criteria have been achieved.

Substantial remaining work includes:

- Stable file identities across renames, path reuse and divergent branches.
- Mailmap/manual aliases, richer ownership and optional blame.
- Historical file/line growth and additional time bucket sizes.
- Layered timelines, treemap, ownership map and interactive coupling graph.
- Linked graphical date-range selection and configurable merge policies.
- Repository drag-and-drop and export features.
- Streaming import, normalized database events and incremental aggregates.
- Large-repository performance and memory engineering.
- Signed sandbox/bookmark edge cases, minimum-version and Intel verification.
- Wider cancellation, accessibility, appearance and regression checks.

The app is currently a working intermediate prototype with a tested core and a demonstrated native workflow. Performance targets, complete security validation and full product readiness remain unproven.

## 18. Glossary

| Term | Meaning in GitScope |
|---|---|
| Repository | A local working directory with Git history |
| Commit | A recorded revision with metadata and changes |
| HEAD | The working tree’s current Git reference |
| Pinned revision | The immutable commit ID chosen for one analysis |
| Eligible commit | A non-merge commit remaining after shared filters |
| Churn | Added lines plus deleted lines; not net code growth |
| Hotspot | A frequently changed historical file path |
| Ownership | Recorded contribution shares, not a verified responsibility assignment |
| Coupling | Files appearing together in eligible commits |
| Support | Joint commits divided by all eligible commits |
| Directional confidence | Joint commits divided by commits touching the source file |
| Shallow clone | A repository containing only part of its history |
| Cache | Locally retained data used to avoid repeated extraction |
| Incremental import | Extracting newly reachable commits after an ancestor-preserving advance |
| Security-scoped bookmark | A macOS mechanism for restoring previously granted folder access |

For the exact implementation, inspect the source under `Sources`. For the recorded evidence and unverified cases, consult `VALIDATION.md`. This guide documents Milestone 2; later changes may alter its behavior.
