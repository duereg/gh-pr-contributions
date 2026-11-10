#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/.."

echo "Running gh-pr-contributions regression tests"
echo "==========================================="

failed=0
passed=0

while IFS= read -r -d '' test_file; do
    echo ""
    echo ">>> $test_file"
    if bash "$test_file"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done < <(find "$ROOT" -name '*.test.sh' -print0 | sort -z)

echo ""
echo "==========================================="
echo "Suites: $passed passed, $failed failed"

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
exit 0
