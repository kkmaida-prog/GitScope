# Validation record

Date: 1 November 2026. Environment: Apple Silicon macOS host, Xcode 27.1 (27A9275), Swift 6.4. Deployment target: macOS 14. No third-party dependencies were installed.

## Final automated verification

`GITSCOPE_BUILD_DIR=<writable build directory> bash scripts/verify.sh` completed successfully after the final Swift source changes.

- **22 XCTest tests passed; 0 failures**, approximately 13.8 seconds in the final coverage-instrumented run.
- **Xcode application Debug arm64 build passed**, without a signing identity.
- Native app target, core framework and test target compile from the same sources as the Swift package.
- Project and entitlements property lists pass `plutil -lint`.
- Compiler macro plugins required `-disable-sandbox` in this restricted agent environment. This is a build-time option; application sandbox entitlements remain enabled in the Xcode project.

The script explicitly invokes `xcrun xctest` on the built package test bundle so test execution and results are visible with both Swift build engines. Raw condensed evidence is in `Validation/build-and-tests.txt`.

## Coverage

Measured with llvm-profdata/llvm-cov on the final coverage-instrumented XCTest binary:

| Production source | Line coverage | Region coverage |
|---|---:|---:|
| AnalysisEngine | 100% | 100% |
| AdvancedAnalysis | 91.53% | 80.52% |
| AnalysisOptions | 92.73% | 91.49% |
| HistoryParser | 96.61% | 82.14% |
| RepositoryCache | 93.26% | 80.95% |
| GitRepositoryService | 83.33% | 71.43% |

`Validation/coverage.txt` contains the full report. Its total includes test and generated sources; it should not be cited as product-wide coverage. Coverage does not establish correctness for untested inputs. UI code was not instrumented by this core test bundle.

## Test coverage by behavior

The original eight tests remain: metadata/unusual paths, binary/rename/empty commits, malformed output, tree sizes/submodules, hotspot/churn/month metrics, empty/tied rankings, real Git read-only integration and invalid repository handling.

Fourteen additional tests check:

1. Shared date boundaries, author, path, extension and exclusion rules; all affected metrics use the same scope.
2. Bulk filtering occurs before path filtering; disabling the bulk rule restores the event.
3. Truly empty commits remain only without path scope.
4. Glob semantics and case-insensitive extension matching.
5. Email grouping, file-local churn, commit/churn ownership shares and directory commit deduplication.
6. Coupling support, directional confidence, thresholds and evidence.
7. Duplicate paths count once; oversized coupling runs withhold partial results.
8. Analysis option Codable persistence.
9. SQLite round trip, repository/reference isolation and transaction rollback after an injected SQL failure.
10. Cancellation leaves the previous cache snapshot intact.
11. Cache hits, incremental/full-import equivalence and safe rebuild after history rewrites.
12. Default-main behavior, independent branch caches and selection without checkout; arbitrary ref arguments rejected.
13. Corrupt cache payload triggers full re-import and recovery.
14. A shallow clone becoming complete invalidates the same-HEAD cache.

All repositories mutated by these tests are newly created disposable fixtures. The shallow test uses a local `file://` clone/fetch solely to prepare the fixture; the application service never fetches. The original integration test verifies that analysis leaves HEAD/status unchanged and does not execute an installed post-checkout hook.

## Native UI smoke test

The application was launched and exercised through native UI automation with a disposable demo repository. Verified:

- Folder selection and successful import on main: three commits, two author emails, three files and 11 churn.
- Overview chart with a zero-activity March, plus directory activity.
- Ownership chart: two commits for the first contributor and one for the second.
- Coupling: the two Swift files co-change in three commits, support and both confidences 100%; inspector shows all three supporting commits.
- Shared author filter: Overview shows one eligible commit; Coupling correctly has no pair meeting the two-commit minimum.
- Filter reset restores all three commits.
- Branch selection switches analysis to feature: four commits/four files, without checkout (also asserted by an automated fixture).
- Refresh displays Cache hit and zero newly read commits.
- Restarting the final build preserves the recent repository; opening it reuses cached analysis.
- Dark-mode overview layout was visually inspected. Final labels clarify revision size versus historical filters, and wildcard examples use verbatim text.

This used an unsigned development app. It does **not** establish signed App Sandbox behavior, bookmark validity across app signing/container changes, or an accessibility audit. The date picker itself and minimum-window-size layouts were not exhaustively tested.

## Blocked and remaining checks

`xcodebuild test` compiled the native test bundle but the test harness could not execute in this environment: access to `com.apple.testmanagerd.control` was denied with a sandbox restriction. The executed XCTest evidence is the direct package test-bundle run, not a passing Xcode test-manager run.

Still unverified: signed sandbox access and bookmark expiry, linked worktrees/external object stores, macOS 14 runtime, Intel build/runtime, light appearance, VoiceOver/keyboard audit, cancellation/timeout stress tests, malicious hooks under signed sandbox, outgoing traffic monitoring and large-repository memory/time benchmarks. The candidate-pair/event overflow paths have guardrails but have not been stress-benchmarked to their maximum limits.

No research evaluation or thesis success thresholds are claimed. The approximately 50% scope estimate in `MILESTONE_STATUS.md` is an implementation planning judgment.
