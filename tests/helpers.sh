#!/usr/bin/env bash
# Shared helpers for gh-pr-contributions tests.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_PATH="$REPO_ROOT/pr-contributions.sh"
FIXTURES_DIR="$TESTS_DIR/fixtures"
GH_STUB="$TESTS_DIR/bin/gh"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-values differ}"
    if [[ "$expected" == "$actual" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS: $msg"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-expected substring}"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS: $msg"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL: $msg"
        echo "    missing: $needle"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-unexpected substring}"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS: $msg"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL: $msg"
        echo "    found: $needle"
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-exit code}"
    assert_eq "$expected" "$actual" "$msg"
}

# Isolate SCRIPT_DIR/data/reports under a temp workspace by running the script
# from a copied tree, or by exporting overrides after sourcing.
make_workspace() {
    local ws
    ws=$(mktemp -d)
    mkdir -p "$ws/data" "$ws/reports" "$ws/bin"
    # Symlink script so SCRIPT_DIR resolves to workspace when we copy it
    cp "$SCRIPT_PATH" "$ws/pr-contributions.sh"
    chmod +x "$ws/pr-contributions.sh"
    ln -s "$GH_STUB" "$ws/bin/gh"
    echo "$ws"
}

use_gh_stub() {
    export PATH="$TESTS_DIR/bin:$PATH"
    export GH_STUB_FIXTURES="$FIXTURES_DIR"
    export GH_STUB_STATE_DIR="${GH_STUB_STATE_DIR:-$(mktemp -d)}"
    mkdir -p "$GH_STUB_STATE_DIR"
}

source_script() {
    # shellcheck source=/dev/null
    source "$SCRIPT_PATH"
}

finish_tests() {
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        return 1
    fi
    return 0
}
