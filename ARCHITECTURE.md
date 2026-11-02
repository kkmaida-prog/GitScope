# GitScope architecture

## Structure

```text
SwiftUI Views → RepositoryViewModel (MainActor)
                    ↓ asynchronous import / background metrics
             GitRepositoryService
              ↙                 ↘
    GitCommandRunner       RepositoryCache (SQLite)
           ↓ bytes                ↑ atomic snapshot
       HistoryParser → RepositorySnapshot
                              ↓ shared AnalysisOptions
                       AnalysisEngine
                       AdvancedAnalysis
                              ↓ immutable metrics
                 Overview / Hotspots / Ownership / Coupling
```

`Models` contains immutable Sendable data types plus Codable snapshots/options. `Services` validates access, resolves a reference, executes Git, parses output and caches raw history. `Analysis` contains deterministic filters and metrics with no UI or repository writes. `ViewModels` coordinates asynchronous work and publishes complete results. `Views` handles navigation, shared filter editing, branch selection, charts and evidence inspection.

The source documents remain the design basis. This milestone implements a useful subset of their proposed system, not all FR/NFR requirements. SQLite uses a compact snapshot schema rather than the fully normalized schema proposed in the architecture document.

## Git protocol and policies

The service validates a working-tree repository, resolves its top level, enumerates local branches, resolves the selected reference to one immutable object ID and checks shallow status. Only `HEAD` or an enumerated full local branch reference is accepted. The initial UI selects local `main` if present. Switching references never checks out a branch.

`git log --no-merges --numstat -z --find-renames` uses protocol v1: NUL marker `GITSCOPEv1`, object ID, author name, author email, Unix committer timestamp, subject, then NUL numstat records. Metadata is consumed positionally. Each numstat record splits at its first two tabs only; the remaining path may contain tabs/newlines. Rename records preserve separate old/new paths. Binary `-` counts remain unknown. `ls-tree -r -l -z` reads blob paths and bytes at the same pinned revision; submodules are excluded, symlink blobs included.

All reachable non-merge commits are eligible before user filters; merged branch commits remain included. Merge-only conflict resolution is omitted. Dates are committer dates; months and filter day boundaries use UTC Gregorian time. Raw author emails are lowercased for grouping; mailmap and manual aliases are deferred. Malformed output and invalid UTF-8 fail explicitly rather than publishing partial metrics.

## SQLite cache and incremental import

Schema v2: `snapshots(repository TEXT, reference TEXT, version INTEGER, payload BLOB, PRIMARY KEY(repository, reference))`. The payload is a Codable snapshot containing raw commits/change records, revision, shallow state and file sizes. Bound SQL parameters protect path/ref values. A fresh connection belongs to one synchronous worker operation; busy timeout is three seconds.

Read the current pinned revision before consulting the cache. If revision and shallow state match, reuse the snapshot. Otherwise, for two non-shallow snapshots, `merge-base --is-ancestor old new` validates whether incremental import is safe. A successful check imports `old..new`, deduplicates IDs with cached commits and sorts by descending timestamp then ID. The new revision's tree is always re-read. Failed ancestry, missing old objects or changed shallow state causes a full rebuild.

The cache is partitioned by canonical repository root and reference, independent of presentation filters. Filters always operate on the complete raw snapshot, so changing them does not need Git extraction. `BEGIN IMMEDIATE` and `COMMIT` atomically replace a snapshot; any SQL error or observed cancellation rolls back. Corrupt payloads trigger re-import; unavailable storage produces a visible warning without hiding a successful live analysis.

This is incremental **ingestion**, not incremental aggregation or row-level database storage: a changed run still serializes a complete snapshot and recomputes metrics. Snapshot cache versioning invalidates old formats by using a versioned filename/schema predicate. A later normalized event schema should add migrations and query indexes.

## Shared filter pipeline

For each raw commit: apply inclusive lower/exclusive upper timestamp bounds, author substring and the original distinct-path bulk limit. Then filter changes by path substring, case-insensitive extension and excluded globs. Asterisk in a glob matches across folders. Drop commits whose changes were all filtered; truly empty commits remain only when there is no path/type/exclusion scope. Zero disables the bulk rule. The default is 50 paths.

Every metric and evidence list receives this same filtered snapshot. File counts/bytes describe the selected revision after path/type/exclusion rules; author and date filters do not turn that revision tree into a historical size estimate. The interface states this distinction. Filter settings persist per repository in UserDefaults, outside the repository.

## Algorithms

Hotspot frequency F(p) is distinct eligible commits touching historical path p. Churn C(p) = additions + deletions from numeric numstat values. Binary events are reported separately. Rank by descending F, then churn, then path ascending. The displayed size is current Git blob bytes, not LOC. Absent historical paths show no current size. Rename events are visible, but stable identities across renames/branches are deferred.

Monthly activity counts commits in UTC buckets and inserts zero-valued months between the first and last eligible month. Directory activity groups by top-level folder (or `(root)`), counts a commit once per directory, and sums scoped churn.

Ownership groups by lowercased author email. Commit share = the author's eligible commits / all eligible commits. Churn share = their numeric changed lines / all numeric changed lines, or zero when the denominator is zero. File ownership recomputes these shares using only that file's changes. Leading share uses commit frequency; it is historical contribution concentration, not expertise or a validated bus factor.

For files A and B, N(A,B) counts distinct eligible commits touching both. Support = N(A,B)/N(total eligible commits). Confidence A→B = N(A,B)/N(A), and B→A similarly. A pair qualifies when its joint count meets the minimum and at least one direction meets the confidence threshold. Default: two joint commits and 20% confidence. Rows open the supporting commits. Co-change is association, not static dependency.

Pairs use sorted distinct paths and commit indices to avoid duplicate counting and large copied commit structures during enumeration. To bound work, withhold the **entire coupling result** if any scoped commit exceeds 100 files, candidate pairs exceed 100,000, or pair events exceed 1,000,000. Other metrics remain available, and the UI explains how to narrow scope. At most 500 qualifying pairs render; the total is shown.

Base aggregation costs approximately O(C + E + F log F + M), plus contributor grouping and deterministic sorting. Coupling adds O(sum k²) pair enumeration for commit path counts k, subject to its limits. All extraction and aggregation are in memory and background tasks; large-repository performance targets have not been demonstrated.

## Read-only execution and lifecycle

Run fixed `/usr/bin/git` using argument arrays, never a shell. The app uses rev-parse, for-each-ref, merge-base, log and ls-tree. It has no fetch, checkout, commit or network client. Disable hooks, fsmonitor, replacement objects, external diffs and textconv; disable prompts, lazy fetch and optional locks; ignore system/global Git configuration. The repository's own configuration and attributes can still affect Git semantics; the cached snapshot is not a substitute for an immutable external analysis provenance archive.

Subprocess output goes to temporary files, avoiding pipe deadlocks. Polling checks cancellation, a 120-second command deadline, 128 MiB stdout and 1 MiB stderr limits. Recheck output size after termination. Cancellation terminates Git and escalates to kill after one second when needed. Temporary files are removed. Output limits do not guarantee a specific peak memory bound during decoding/aggregation.

The Xcode app enables App Sandbox, user-selected read-only access and app-scoped bookmarks. It retains security-scoped access during import and stores up to eight recent read-only bookmarks in UserDefaults. Reopening an expired bookmark reports an error and asks for folder selection. Linked worktrees or external object stores may require access outside the selected root and can fail. These runtime sandbox cases still need dedicated verification.

The last published snapshot remains visible until a new import and metric computation complete. Cancellation suppresses publication; current pure aggregation is allowed to finish before the overlay disappears. Cache writes may complete before aggregation cancellation; only fully extracted raw snapshots are stored.
