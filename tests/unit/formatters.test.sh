#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../helpers.sh
source "$(cd "$(dirname "$0")/.." && pwd)/helpers.sh"
source_script

echo "=== unit: format_review_time ==="
assert_eq "N/A" "$(format_review_time "null")" "null -> N/A"
assert_eq "N/A" "$(format_review_time "")" "empty -> N/A"
assert_eq "30m" "$(format_review_time "0.5")" "0.5h -> 30m"
assert_eq "2h 0m" "$(format_review_time "2")" "2h"
assert_eq "1d 2h" "$(format_review_time "26")" "26h -> 1d 2h"

echo "=== unit: format_markdown_table ==="
table=$(
    {
        printf 'L\tR\n'
        printf 'User\tTrend\n'
        printf 'alice\t↑ +3\n'
        printf 'bob\t↓ -1\n'
    } | format_markdown_table
)
assert_contains "$table" "| User" "header present"
assert_contains "$table" "| alice" "alice row"
assert_contains "$table" "↑ +3" "unicode arrow preserved"
# Right-aligned numeric-ish column should have a colon on the separator
assert_contains "$table" "---:" "right-align marker on Trend column"

finish_tests
