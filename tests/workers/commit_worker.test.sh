#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/helpers.sh"
source_script

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
use_gh_stub
export GH_STUB_STATE_DIR
GH_STUB_STATE_DIR=$(mktemp -d)
export GH_STUB_STATE_DIR

# Short-circuit sleeps during rate-limit retries
export GH_STUB_RATE_RESET
GH_STUB_RATE_RESET=$(( $(date +%s) - 1 ))

create_commit_worker "$TMP/commit_worker.sh"

echo "=== workers: graphql happy path ==="
out="$TMP/ok.tsv"
"$TMP/commit_worker.sh" testorg busy 9001 "$out"
assert_eq "0" "$?" "commit worker exit 0"
line=$(cat "$out")
assert_contains "$line" "busy" "tsv has repo"
assert_contains "$line" "9001" "tsv has number"
assert_not_contains "$line" "{" "no JSON braces in tsv"
fields=$(awk -F'\t' '{print NF}' "$out")
assert_eq "7" "$fields" "tsv has 7 fields (repo num commits pub add del files)"
commits=$(cut -f3 "$out")
assert_eq "3" "$commits" "commits from fixture"

echo "=== workers: rate-limit retries then success ==="
rm -rf "$GH_STUB_STATE_DIR"
mkdir -p "$GH_STUB_STATE_DIR"
export GH_STUB_RATE_LIMIT_PR="busy:9002:2"
out_rl="$TMP/rl.tsv"
# Override sleep to be instant for tests by wrapping — worker sleeps based on reset.
# With reset in the past, wait becomes 45s minimum. That's too slow for unit tests.
# Patch: use a wrapper sleep in PATH.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# no-op sleep for tests
exit 0
EOF
chmod +x "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"

"$TMP/commit_worker.sh" testorg busy 9002 "$out_rl"
assert_eq "0" "$?" "rate-limit worker eventually succeeds"
assert_not_contains "$(cat "$out_rl")" "{" "rate-limit path did not leak JSON"
commits=$(cut -f3 "$out_rl")
assert_eq "1" "$commits" "recovered fixture commits after retries"
unset GH_STUB_RATE_LIMIT_PR

echo "=== workers: failed graphql stdout must not leak into TSV ==="
export GH_STUB_GRAPHQL_FAIL=1
out_fail="$TMP/fail.tsv"
"$TMP/commit_worker.sh" testorg busy 9001 "$out_fail"
assert_not_contains "$(cat "$out_fail")" "{" "fallback TSV has no JSON"
assert_not_contains "$(cat "$out_fail")" "errors" "fallback TSV has no error payload"
# repo, num, 0, empty pub, 0, 0, 0
expected=$'busy\t9001\t0\t\t0\t0\t0'
actual=$(cat "$out_fail")
assert_eq "$expected" "$actual" "fallback row is zeros"
unset GH_STUB_GRAPHQL_FAIL

echo "=== workers: parallel TSV isolation ==="
unset GH_STUB_GRAPHQL_FAIL
rm -rf "$GH_STUB_STATE_DIR"
mkdir -p "$GH_STUB_STATE_DIR"
mkdir -p "$TMP/stats"
pids=()
for n in 9001 9002 9003; do
    (
        "$TMP/commit_worker.sh" testorg busy "$n" "$TMP/stats/busy_${n}.tsv"
    ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
cat "$TMP/stats"/*.tsv > "$TMP/all.tsv"
while IFS= read -r line; do
    nf=$(echo "$line" | awk -F'\t' '{print NF}')
    assert_eq "7" "$nf" "parallel tsv row has 7 fields: $line"
    assert_not_contains "$line" "{" "parallel tsv row clean"
done < "$TMP/all.tsv"
rows=$(wc -l < "$TMP/all.tsv" | tr -d ' ')
assert_eq "3" "$rows" "three parallel stats rows"

finish_tests
