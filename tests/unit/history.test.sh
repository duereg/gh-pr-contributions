#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/helpers.sh"
source_script

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA_DIR="$TMP/data"
HISTORY_FILE="$DATA_DIR/history.json"
mkdir -p "$DATA_DIR"

echo "=== unit: load_history empty/corrupt ==="
assert_eq '{"weeks": []}' "$(load_history)" "missing history -> empty weeks"
echo 'not-json' > "$HISTORY_FILE"
assert_eq '{"weeks": []}' "$(load_history)" "corrupt history -> empty weeks"
echo '{"no_weeks": true}' > "$HISTORY_FILE"
assert_eq '{"weeks": []}' "$(load_history)" "missing weeks key -> empty weeks"

echo "=== unit: save_to_history replace + cap ==="
: > "$HISTORY_FILE"
echo '{"weeks": []}' > "$HISTORY_FILE"

make_week() {
    local until_date="$1"
    local merged="$2"
    jq -n --arg until "$until_date" --argjson m "$merged" '{
        period: { since: "2026-01-01", until: $until },
        users: { alice: { prs_merged: $m, prs_opened: $m } },
        summary: {
            total_prs_merged: $m,
            total_prs_opened: $m,
            total_additions: 0,
            total_deletions: 0,
            total_files: 0,
            total_commits: 0,
            repos_scanned: 1,
            active_contributors: 1,
            avg_lines_per_pr: 0,
            avg_review_hours: null
        }
    }'
}

# Seed 12 distinct weeks
for i in $(seq 1 12); do
    day=$(printf '%02d' "$i")
    save_to_history "$(make_week "2026-01-${day}" "$i")" >/dev/null
done
count=$(jq '.weeks | length' "$HISTORY_FILE")
assert_eq "12" "$count" "history capped at 12 after seeding"

# 13th distinct date should drop the oldest
save_to_history "$(make_week "2026-02-01" 100)" >/dev/null
count=$(jq '.weeks | length' "$HISTORY_FILE")
assert_eq "12" "$count" "history still capped at 12 after 13th insert"
newest=$(jq -r '.weeks[0].date' "$HISTORY_FILE")
assert_eq "2026-02-01" "$newest" "newest week is first"
has_jan01=$(jq '[.weeks[].date] | any(. == "2026-01-01")' "$HISTORY_FILE")
assert_eq "false" "$has_jan01" "oldest week dropped"

# Same until replaces in place
save_to_history "$(make_week "2026-02-01" 999)" >/dev/null
count=$(jq '.weeks | length' "$HISTORY_FILE")
assert_eq "12" "$count" "replace does not grow history"
merged=$(jq '.weeks[0].summary.total_prs_merged' "$HISTORY_FILE")
assert_eq "999" "$merged" "same until replaces summary"

echo "=== unit: calculate_trends ==="
# Fresh history with one week -> trends unavailable
echo '{"weeks": []}' > "$HISTORY_FILE"
hist=$(save_to_history "$(make_week "2026-03-01" 10)")
current=$(make_week "2026-03-01" 10)
trends=$(calculate_trends "$current" "$hist")
avail=$(echo "$trends" | jq -r '.trends.available')
assert_eq "false" "$avail" "first week: trends unavailable"

# Two weeks -> WoW available
hist=$(save_to_history "$(make_week "2026-03-08" 25)")
current=$(make_week "2026-03-08" 25)
# history now [Mar8=25, Mar1=10] after replace/add — wait, save already wrote Mar8.
# Recalculate trends using loaded history
hist=$(load_history)
trends=$(calculate_trends "$current" "$hist")
avail=$(echo "$trends" | jq -r '.trends.available')
assert_eq "true" "$avail" "second week: trends available"
pr_change=$(echo "$trends" | jq -r '.trends.pr_change')
assert_eq "15" "$pr_change" "WoW pr_change 25-10=15"
alice_trend=$(echo "$trends" | jq -r '.users.alice.trend')
assert_eq "15" "$alice_trend" "per-user trend"
rolling=$(echo "$trends" | jq -r '.trends.rolling_avg_4week')
assert_eq "17" "$rolling" "rolling avg floor((25+10)/2)=17"

finish_tests
