#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/helpers.sh"
source_script

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
use_gh_stub
GH_STUB_STATE_DIR=$(mktemp -d)
export GH_STUB_STATE_DIR

create_repo_worker "$TMP/repo_worker.sh"

echo "=== workers: date filter + pagination past page 5 ==="
out="$TMP/busy.jsonl"
err="$TMP/errors.log"
: > "$err"
"$TMP/repo_worker.sh" testorg busy 2026-10-15 2026-11-09 "$out" "$err"
assert_eq "0" "$?" "busy worker exit 0"
assert_eq "" "$(cat "$err")" "no errors for busy"

# Must include in-window merges from page 6 (would be missed by --limit 500 of newest-only noise)
numbers=$(jq -s '[.[].number] | sort | @csv' "$out")
assert_contains "$numbers" "9001" "includes page-6 merge 9001"
assert_contains "$numbers" "9002" "includes page-6 merge 9002"
assert_contains "$numbers" "9003" "includes open PR created in window"
# Noise PRs from pages 1-5 are merged Jan 2026 — must not appear
noise_count=$(jq -s '[.[] | select(.number < 9000)] | length' "$out")
assert_eq "0" "$noise_count" "excludes out-of-window noise from early pages"

# Old created_at but merged in window still counts
created=$(jq -s -r '.[] | select(.number==9001) | .created_at' "$out")
assert_eq "2026-09-01T00:00:00Z" "$created" "9001 created before window"
merged_flag=$(jq -s -r '.[] | select(.number==9001) | .merged' "$out")
assert_eq "true" "$merged_flag" "9001 marked merged"

echo "=== workers: quiet repo date filter ==="
out_q="$TMP/quiet.jsonl"
: > "$err"
"$TMP/repo_worker.sh" testorg quiet 2026-10-15 2026-11-09 "$out_q" "$err"
q_nums=$(jq -s '[.[].number] | sort | @csv' "$out_q")
assert_contains "$q_nums" "101" "quiet merged in window"
assert_contains "$q_nums" "102" "quiet open in window"
assert_not_contains "$q_nums" "100" "quiet old merge excluded"

echo "=== workers: fail-repo aborts with error log ==="
export GH_STUB_FAIL_REPOS="boom"
out_f="$TMP/boom.jsonl"
: > "$err"
set +e
"$TMP/repo_worker.sh" testorg boom 2026-10-15 2026-11-09 "$out_f" "$err"
status=$?
set -e
assert_exit_code "1" "$status" "failed repo exits 1"
assert_contains "$(cat "$err")" "FAIL" "errors file has FAIL"
assert_contains "$(cat "$err")" "boom" "errors file names repo"
unset GH_STUB_FAIL_REPOS

echo "=== workers: parallel isolation (no interleaved JSON) ==="
# Generate many quiet-like tiny pages by running busy page-6 style workers in parallel
# on distinct outfiles (the production pattern).
mkdir -p "$TMP/parallel"
: > "$err"
pids=()
for i in $(seq 1 20); do
    (
        "$TMP/repo_worker.sh" testorg quiet 2026-10-15 2026-11-09 "$TMP/parallel/r${i}.jsonl" "$err"
    ) &
    pids+=($!)
done
for p in "${pids[@]}"; do
    wait "$p"
done
cat "$TMP/parallel"/*.jsonl > "$TMP/parallel_all.jsonl"
invalid=0
while IFS= read -r line; do
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        invalid=$((invalid + 1))
    fi
done < "$TMP/parallel_all.jsonl"
assert_eq "0" "$invalid" "all parallel JSONL lines parse"
assert_eq "" "$(cat "$err")" "no parallel worker errors"

finish_tests
