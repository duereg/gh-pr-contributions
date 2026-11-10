#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Instant sleeps if rate-limit path is hit
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/sleep"

WS=$(make_workspace)
export GH_STUB_FIXTURES="$FIXTURES_DIR"
export GH_STUB_STATE_DIR="$TMP/gh-state"
mkdir -p "$GH_STUB_STATE_DIR"
export GH_STUB_RATE_RESET=$(( $(date +%s) - 1 ))
export PATH="$TMP/bin:$WS/bin:$PATH"

echo "=== e2e: happy path with pagination + merged-only metrics ==="
set +e
"$WS/pr-contributions.sh" \
    --org testorg \
    --repos "busy,quiet" \
    --since 2026-10-15 \
    --until 2026-11-09 \
    --jobs 4 \
    --details \
    --output "$WS/reports/out" \
    >"$TMP/stdout.txt" 2>"$TMP/stderr.txt"
status=$?
set -e
assert_exit_code "0" "$status" "e2e happy path exit 0"

report="$WS/reports/out/report.json"
md="$WS/reports/out/report.md"
[[ -f "$report" ]]
[[ -f "$md" ]]

merged=$(jq '.summary.total_prs_merged' "$report")
opened=$(jq '.summary.total_prs_opened' "$report")
additions=$(jq '.summary.total_additions' "$report")
deletions=$(jq '.summary.total_deletions' "$report")

# busy: 9001,9002 merged + 9003 open; quiet: 101 merged + 102 open
assert_eq "3" "$merged" "total_prs_merged == 3"
assert_eq "5" "$opened" "total_prs_opened == 5 (includes open)"
# additions only from merged: 50+20+15=85 — excludes open PR 99999/88888
assert_eq "85" "$additions" "merged-only additions exclude open PR diffs"
assert_eq "10" "$deletions" "merged-only deletions"

# Busy page-6 PRs present (pagination regression)
assert_contains "$(jq -c '[.users[].pr_details[].number]' "$report")" "9001" "report includes busy#9001"
assert_contains "$(jq -c '[.users[].pr_details[].number]' "$report")" "9002" "report includes busy#9002"

# Open PRs must not appear in pr_details
details_nums=$(jq -c '[.users[].pr_details[].number]' "$report")
assert_not_contains "$details_nums" "9003" "open busy#9003 not in pr_details"
assert_not_contains "$details_nums" "102" "open quiet#102 not in pr_details"

echo "=== e2e: --details lists only merged titles ==="
assert_contains "$(cat "$md")" "busy in-window merge A" "details has merged title"
assert_not_contains "$(cat "$md")" "busy open draft" "details omits open title"
assert_not_contains "$(cat "$md")" "quiet open with huge diff" "details omits open quiet title"

echo "=== e2e: fail-fast on repo fetch error ==="
export GH_STUB_FAIL_REPOS="busy"
rm -rf "$GH_STUB_STATE_DIR"
mkdir -p "$GH_STUB_STATE_DIR"
WS2=$(make_workspace)
export PATH="$TMP/bin:$WS2/bin:$PATH"
set +e
"$WS2/pr-contributions.sh" \
    --org testorg \
    --repos "busy,quiet" \
    --since 2026-10-15 \
    --until 2026-11-09 \
    --jobs 2 \
    --output "$WS2/reports/out" \
    >"$TMP/fail-out.txt" 2>"$TMP/fail-err.txt"
fail_status=$?
set -e
assert_exit_code "1" "$fail_status" "repo failure exits non-zero"
assert_contains "$(cat "$TMP/fail-err.txt")" "busy" "stderr mentions failed repo"
# Must not write a successful undercount report as the only outcome
if [[ -f "$WS2/reports/out/report.json" ]]; then
    # If report exists from a partial path, merged should not silently look "complete"
    # Prefer: script aborted before generate — file absent is ideal.
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: report.json should not be written after fatal repo fetch failure"
else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS: no report written after fatal failure"
fi
unset GH_STUB_FAIL_REPOS

finish_tests
