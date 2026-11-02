# Implementation milestone status

This release targets approximately **half of the application implementation**, excluding research and thesis writing. A reasonable planning range is 45–55%; this is an engineering estimate based on working feature groups, not a measured or academically certified percentage. It does not mean that half of every requirement is complete, or that the final system's acceptance criteria have been met.

## Delivered feature groups

| Area | Working scope |
|---|---|
| Native foundation | Real macOS Xcode app, SwiftUI navigation, core framework, shared scheme, Swift package and one-command verification |
| Repository access | Folder picker, validation, recent repositories with read-only bookmarks, local branch selection without checkout, pinned revision and shallow warning |
| Extraction | Commit IDs, author identities, committer dates, subjects, changed paths, numstat, binary handling and rename event evidence |
| Local persistence | Versioned SQLite snapshots, transactions, unchanged-revision cache reuse, ancestor-based incremental import and rewrite/shallow invalidation |
| Shared analysis scope | UTC day range, author/path/extension filters, path exclusion globs and bulk-change suppression; saved per repository |
| Overview and hotspots | Monthly activity, line churn, revision file count/bytes, file ranking, top-level directory activity and file evidence inspector |
| Ownership | Contributor activity, commit/churn shares and leading contributor concentration per historical file |
| Coupling | Joint counts, support, directional confidence, configurable thresholds, bounded pair enumeration and supporting commits |
| Engineering validation | Parser/metric tests and real Git fixtures for caching, rollback, branches, rewrites and shallow history; native UI smoke test |

## Why this is an intermediate release

The ingestion-to-cache-to-analysis-to-interface path now works across four connected views, rather than only a dashboard. The remaining work still includes substantial data correctness, visualization and product hardening. These are not reduced to cosmetic tasks.

## Remaining implementation

- Stable file identities through renames, path reuse and divergent branches; current rankings keep historical paths separate.
- Mailmap/manual author aliases, directory ownership measures, optional blame and cautious bus-factor modeling.
- Historical tree/line-count evolution, day/week/year bucketing and layered timelines.
- Treemap, ownership map, interactive coupling graph and linked graphical range selection.
- Configurable merge policies, repository drag-and-drop, exports and broader native integration.
- Streaming ingestion, normalized/queryable SQLite event tables, incremental aggregates and stronger scaling guarantees. Current incremental import reduces Git extraction, but serializes the complete cache snapshot and recomputes metrics.
- Full cancellation/timeout stress testing, sandbox/bookmark edge cases, macOS minimum-version and Intel checks, accessibility audit and performance engineering.

Usability research and thesis writing are outside this implementation estimate. Runtime security, correctness and performance checks remain engineering work even when research is excluded.
