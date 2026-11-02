#!/bin/bash
set -euo pipefail
# Creates a fresh fixture only; never changes an existing repository.
demo_root="$(mktemp -d "${TMPDIR:-/tmp/}GitScope-demo.XXXXXX")"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="GitScope Demo" GIT_AUTHOR_EMAIL="demo@example.test"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="2026-01-12T12:00:00Z"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
git -C "$demo_root" init -q -b main
mkdir -p "$demo_root/Sources"
printf 'struct Counter {\n    var value = 0\n}\n' > "$demo_root/Sources/Counter.swift"
printf '# Demo\n' > "$demo_root/README.md"
printf 'func report() {}\n' > "$demo_root/Sources/Report.swift"
git -C "$demo_root" add .
git -C "$demo_root" -c core.hooksPath=/dev/null commit -qm 'Create counter'
export GIT_AUTHOR_DATE="2026-02-12T12:00:00Z"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
printf 'struct Counter {\n    var value = 0\n    mutating func increment() { value += 1 }\n}\n' > "$demo_root/Sources/Counter.swift"
printf 'func report() { print("incremented") }\n' > "$demo_root/Sources/Report.swift"
git -C "$demo_root" add .
git -C "$demo_root" -c core.hooksPath=/dev/null commit -qm 'Add increment behavior'
export GIT_AUTHOR_NAME="Second Contributor" GIT_AUTHOR_EMAIL="second@example.test"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="2026-04-12T12:00:00Z"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
printf 'struct Counter {\n    var value = 0\n    mutating func increment() { value += 1 }\n    mutating func reset() { value = 0 }\n}\n' > "$demo_root/Sources/Counter.swift"
printf 'func report() { print("counter updated") }\n' > "$demo_root/Sources/Report.swift"
git -C "$demo_root" add .
git -C "$demo_root" -c core.hooksPath=/dev/null commit -qm 'Add reset behavior'
git -C "$demo_root" checkout -qb feature
printf 'Experimental view\n' > "$demo_root/Experiment.txt"
git -C "$demo_root" add .
git -C "$demo_root" -c core.hooksPath=/dev/null commit -qm 'Explore feature branch'
git -C "$demo_root" checkout -q main
printf '\nSelect this repository in GitScope:\n%s\n' "$demo_root"
