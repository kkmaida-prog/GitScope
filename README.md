# GitScope

A native SwiftUI macOS app for exploring local Git history. This second milestone adds persistent SQLite caching, incremental imports, shared filters, branch selection, ownership and change coupling to the original Overview and hotspots.

Requires macOS 14+ and `/usr/bin/git` supplied by Xcode or Command Line Tools. Uses only Apple frameworks and system SQLite; no third-party dependencies, source uploads, network client or telemetry.

Read the [complete user and implementation guide](docs/USER_GUIDE.md) for a step-by-step tutorial, metric explanations, troubleshooting and the full implementation record.

## Run in Xcode

Open `GitScope.xcodeproj`, select the **GitScope** scheme and **My Mac**, then Run. Select a signing team if Xcode requests one. The app target includes App Sandbox, user-selected read-only folder access and security-scoped bookmark entitlements. Choose a repository root with **Open Repository** (⌘O). Bare and empty repositories report errors.

Local `main` is selected by default when present, otherwise the working tree's HEAD. Selecting another local branch reads its commit objects without checking it out. The displayed object ID pins the history and current file sizes to one revision. Merge commits are always excluded, while non-merge commits from merged branches remain eligible.

The commands below invoke scripts with `bash`, so they also work when downloaded files do not retain executable permissions.

## Verify with one command

```sh
bash scripts/verify.sh
```

The script builds the package tests with coverage, runs the XCTest bundle explicitly, then builds the real Xcode macOS app without signing. Explicit XCTest invocation avoids differences in console reporting between Swift build engines. Output defaults to `.build-verification`; `GITSCOPE_BUILD_DIR` can select another writable location. Compiler-plugin sandboxing is disabled only for this restricted build workflow; the application's sandbox entitlements are unchanged. Use Xcode's signed Run workflow to exercise runtime sandbox permissions.

The shared Xcode scheme also includes a native unit-test target. `Package.swift` builds the same production core and tests. `swift run --disable-sandbox GitScope` runs the package executable, which does not use the Xcode app bundle's sandbox entitlements.

## Demo

Run `bash scripts/create-demo.sh` and select the printed disposable repository. It contains two authors, a main branch with three commits across January, February and April, two frequently co-changed Swift files, and a feature branch with an additional commit. No existing repository is modified by the demo script.

1. Overview shows three commits, two author emails, three files and 11 lines of churn on `main`.
2. Ownership shows the first author with two of three commits; file rows show leading author shares by commits and churn.
3. Coupling shows `Counter.swift` and `Report.swift` together in three commits. Select the pair for evidence.
4. Apply an author filter for `second@example.test`; Overview now shows one eligible commit, while Coupling has no pair meeting the default two-commit threshold.
5. Reset filters. Select `feature`: four commits and four current files appear. The working tree stays on `main`.
6. Refresh: the status reports **Cache hit**, with zero newly read commits.
7. Add a commit yourself and refresh: an ancestor-preserving advance uses an incremental import. A rewrite falls back to a full rebuild.

## Shared analysis scope

Use **Shared filters** to set inclusive UTC start/end days, author name/email, path substring, file extension, excluded path globs, bulk-commit size limit and coupling thresholds. These settings update all analytical views together and persist per repository. Default bulk limit: 50 distinct changed paths; zero disables it. This rule runs before path filtering. Globs use `fnmatch` with `*` matching across folders, e.g. `vendor/*`, `*.lock`, `*/generated/*`.

Author/date filters apply to historical activity. The file count and byte sizes describe the selected revision with path/type/exclusion rules, not a historical file-count estimate. Binary changes are counted separately and do not invent line counts. Renames retain old/new path evidence; historical paths are still ranked separately.

## Local storage

SQLite stores versioned snapshots per canonical repository path and reference under the app's Application Support directory (`GitScope/history-v2.sqlite`), inside the app container when sandboxed. A transaction publishes each complete snapshot. Unchanged revisions reuse cached data; a non-shallow ancestor advance reads only new reachable non-merge commits. History rewrites, deleted old objects and shallow-status changes rebuild safely. Cache errors fall back to live extraction with a visible warning where possible.

Analysis options and up to eight recent repositories are stored in UserDefaults. Recents use read-only security-scoped bookmarks; expired access asks the user to select the folder again. No cache or settings are written into analyzed repositories.

See `ARCHITECTURE.md`, `VALIDATION.md` and `MILESTONE_STATUS.md` for implementation details, executed checks and remaining scope.
