#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
REPORTS_DIR="${SCRIPT_DIR}/reports"
HISTORY_FILE="${DATA_DIR}/history.json"
TEMP_DIR=""

# Default values
ORG=""
SINCE=""
UNTIL=""
REPOS=""
OUTPUT_DIR=""
DAYS=7
DEBUG=false
PARALLEL_JOBS=10
SHOW_DETAILS=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat << EOF
Usage: $(basename "$0") --org <organization> [options]

Fetch PR contribution metrics for a GitHub organization.

Required:
    --org <name>        GitHub organization name

Options:
    --since <date>      Start date (YYYY-MM-DD), default: 7 days ago
    --until <date>      End date (YYYY-MM-DD), default: today
    --repos <list>      Comma-separated list of repos (default: all)
    --output <dir>      Output directory (default: ./reports/YYYY-MM-DD)
    --days <n>          Number of days to look back (default: 7, ignored if --since set)
    --jobs <n>          Number of parallel jobs (default: 10)
    --details           Include PR titles grouped by author in the report
    --debug             Enable debug output
    -h, --help          Show this help message

Examples:
    $(basename "$0") --org myorg
    $(basename "$0") --org myorg --since 2026-02-12 --until 2026-02-19
    $(basename "$0") --org myorg --repos "repo1,repo2"
    $(basename "$0") --org myorg --jobs 20
EOF
    exit 0
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1" >&2
    fi
}

# Reads TSV from stdin. First line is alignment spec (L/R per column), second line is
# the header, remaining lines are data rows. Outputs a column-aligned markdown table.
format_markdown_table() {
    local -a lines=()
    local -a aligns=()

    while IFS= read -r line; do
        lines+=("$line")
    done

    IFS=$'\t' read -ra aligns <<< "${lines[0]}"
    local num_cols=${#aligns[@]}

    local -a widths=()
    local i j
    for ((i = 1; i < ${#lines[@]}; i++)); do
        IFS=$'\t' read -ra cells <<< "${lines[$i]}"
        for ((j = 0; j < num_cols; j++)); do
            local vlen=${#cells[$j]}
            if [[ ${widths[$j]:-0} -lt $vlen ]]; then
                widths[$j]=$vlen
            fi
        done
    done

    # Print a single cell with proper padding (handles multi-byte UTF-8)
    _fmt_cell() {
        local cell="$1" w="$2" a="$3"
        local vlen=${#cell}
        local ascii_only="${cell//[^[:ascii:]]/}"
        local extra=$(( (vlen - ${#ascii_only}) * 2 ))
        local padded=$((w + extra))
        if [[ "$a" == "R" ]]; then
            printf " %${padded}s |" "$cell"
        else
            printf " %-${padded}s |" "$cell"
        fi
    }

    IFS=$'\t' read -ra cells <<< "${lines[1]}"
    printf "|"
    for ((j = 0; j < num_cols; j++)); do
        _fmt_cell "${cells[$j]}" "${widths[$j]}" "L"
    done
    printf "\n"

    printf "|"
    for ((j = 0; j < num_cols; j++)); do
        local w=${widths[$j]}
        printf " "
        if [[ "${aligns[$j]}" == "R" ]]; then
            printf '%*s' "$((w - 1))" '' | tr ' ' '-'
            printf ":"
        else
            printf '%*s' "$w" '' | tr ' ' '-'
        fi
        printf " |"
    done
    printf "\n"

    for ((i = 2; i < ${#lines[@]}; i++)); do
        IFS=$'\t' read -ra cells <<< "${lines[$i]}"
        printf "|"
        for ((j = 0; j < num_cols; j++)); do
            _fmt_cell "${cells[$j]:-}" "${widths[$j]}" "${aligns[$j]}"
        done
        printf "\n"
    done
}

format_review_time() {
    local hours="$1"
    if [[ "$hours" == "null" || -z "$hours" ]]; then
        echo "N/A"
        return
    fi
    local total_minutes
    total_minutes=$(echo "$hours * 60" | bc 2>/dev/null | cut -d. -f1)
    if [[ "$total_minutes" -lt 60 ]]; then
        echo "${total_minutes}m"
    elif [[ "$total_minutes" -lt 1440 ]]; then
        local h=$((total_minutes / 60))
        local m=$((total_minutes % 60))
        echo "${h}h ${m}m"
    else
        local d=$((total_minutes / 1440))
        local remaining=$((total_minutes % 1440))
        local h=$((remaining / 60))
        echo "${d}d ${h}h"
    fi
}

check_dependencies() {
    local missing=()
    
    if ! command -v gh &> /dev/null; then
        missing+=("gh (GitHub CLI)")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
    
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --org)
                ORG="$2"
                shift 2
                ;;
            --since)
                SINCE="$2"
                shift 2
                ;;
            --until)
                UNTIL="$2"
                shift 2
                ;;
            --repos)
                REPOS="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --days)
                DAYS="$2"
                shift 2
                ;;
            --jobs)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --details)
                SHOW_DETAILS=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    if [[ -z "$ORG" ]]; then
        log_error "Organization name is required (--org)"
        usage
    fi
    
    # Set default dates
    if [[ -z "$SINCE" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            SINCE=$(date -v-${DAYS}d +%Y-%m-%d)
        else
            SINCE=$(date -d "-${DAYS} days" +%Y-%m-%d)
        fi
    fi
    
    if [[ -z "$UNTIL" ]]; then
        UNTIL=$(date +%Y-%m-%d)
    fi
    
    # Set default output directory
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="${REPORTS_DIR}/${UNTIL}"
    fi
}

# Fetch all repositories in the organization
fetch_repos() {
    if [[ -n "$REPOS" ]]; then
        echo "$REPOS" | tr ',' '\n'
    else
        gh repo list "$ORG" --limit 1000 --json name --jq '.[].name' 2>/dev/null || echo ""
    fi
}

# Create helper script for fetching PR details
create_pr_detail_worker() {
    local script_path="$1"
    cat > "$script_path" << 'WORKER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

org="$1"
repo="$2"
pr_num="$3"
debug="$4"

[[ "$debug" == "true" ]] && echo "[DEBUG] Fetching details for $org/$repo#$pr_num" >&2

# Fetch detailed PR info including commits count
pr_data=$(gh api "repos/${org}/${repo}/pulls/${pr_num}" 2>/dev/null || echo "{}")

if [[ -z "$pr_data" || "$pr_data" == "{}" ]]; then
    exit 0
fi

echo "$pr_data" | jq -c --arg repo "$repo" '{
    repo: $repo,
    number: .number,
    author: .user.login,
    state: .state,
    merged: .merged,
    merged_at: .merged_at,
    created_at: .created_at,
    additions: .additions,
    deletions: .deletions,
    changed_files: .changed_files,
    commits: .commits
}' 2>/dev/null || true
WORKER_SCRIPT
    chmod +x "$script_path"
}

# Create helper script for fetching PRs from a repo
create_repo_worker() {
    local script_path="$1"
    cat > "$script_path" << 'WORKER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

org="$1"
repo="$2"
since="$3"
until="$4"
state="$5"

# Fetch PRs for this repo (without commits to avoid GraphQL limits)
gh pr list --repo "${org}/${repo}" \
    --state "$state" \
    --limit 500 \
    --json number,title,author,createdAt,mergedAt,additions,deletions,changedFiles 2>/dev/null | \
    jq -c --arg since "${since}T00:00:00Z" --arg until "${until}T23:59:59Z" --arg repo "$repo" '
        .[] | 
        select(
            (.mergedAt != null and .mergedAt >= $since and .mergedAt <= $until) or
            (.mergedAt == null and .createdAt >= $since and .createdAt <= $until)
        ) |
        {
            repo: $repo,
            number: .number,
            title: .title,
            author: .author.login,
            merged: (.mergedAt != null),
            merged_at: .mergedAt,
            created_at: .createdAt,
            additions: .additions,
            deletions: .deletions,
            changed_files: .changedFiles
        }
    ' 2>/dev/null || true
WORKER_SCRIPT
    chmod +x "$script_path"
}

# Create helper script for fetching commit count and publishedAt for a PR
create_commit_worker() {
    local script_path="$1"
    cat > "$script_path" << 'WORKER_SCRIPT'
#!/usr/bin/env bash
org="$1"
repo="$2"
pr_num="$3"
result=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      commits { totalCount }
      publishedAt
    }
  }
}' -f owner="$org" -f repo="$repo" -F number="$pr_num" \
  --jq '.data.repository.pullRequest | "\(.commits.totalCount)\t\(.publishedAt // "")"' 2>/dev/null || echo "0	")
echo "${repo}	${pr_num}	${result}"
WORKER_SCRIPT
    chmod +x "$script_path"
}

# Main data collection function
collect_contribution_data() {
    TEMP_DIR=$(mktemp -d)
    local pr_data_file="$TEMP_DIR/prs.jsonl"
    local commit_counts_file="$TEMP_DIR/commit_counts.tsv"
    local repo_worker="$TEMP_DIR/repo_worker.sh"
    local commit_worker="$TEMP_DIR/commit_worker.sh"
    local errors_file="$TEMP_DIR/errors.log"
    
    : > "$pr_data_file"
    : > "$commit_counts_file"
    : > "$errors_file"
    
    # Create worker scripts
    create_repo_worker "$repo_worker"
    create_commit_worker "$commit_worker"
    
    log_info "Fetching repositories for organization: $ORG"
    local repos
    repos=$(fetch_repos)
    
    if [[ -z "$repos" ]]; then
        log_error "No repositories found or failed to fetch repos"
        echo '{"users": {}, "summary": {"total_prs_merged": 0, "total_prs_opened": 0, "total_additions": 0, "total_deletions": 0, "total_files": 0, "total_commits": 0, "repos_scanned": 0, "active_contributors": 0, "avg_lines_per_pr": 0, "avg_review_hours": null}, "period": {"since": "'"$SINCE"'", "until": "'"$UNTIL"'"}}'
        return
    fi
    
    local repo_count
    repo_count=$(echo "$repos" | grep -c . || echo "0")
    log_info "Found $repo_count repositories to scan"
    
    # Phase 1: Fetch all PRs from all repos in parallel (without commits to avoid GraphQL limits)
    log_info "Phase 1: Fetching PRs from all repos (parallel with $PARALLEL_JOBS jobs)..."
    
    echo "$repos" | xargs -P "$PARALLEL_JOBS" -I {} "$repo_worker" "$ORG" "{}" "$SINCE" "$UNTIL" "all" >> "$pr_data_file" 2>>"$errors_file"
    
    local total_prs
    total_prs=$(wc -l < "$pr_data_file" | tr -d ' ')
    log_info "Found $total_prs PRs to analyze"
    
    if [[ "$total_prs" -eq 0 ]]; then
        log_debug "No PRs found in date range"
        echo '{"users": {}, "summary": {"total_prs_merged": 0, "total_prs_opened": 0, "total_additions": 0, "total_deletions": 0, "total_files": 0, "total_commits": 0, "repos_scanned": '"$repo_count"', "active_contributors": 0, "avg_lines_per_pr": 0, "avg_review_hours": null}, "period": {"since": "'"$SINCE"'", "until": "'"$UNTIL"'"}}'
        return
    fi
    
    # Phase 2: Fetch commit counts and review timing for each PR in parallel
    log_info "Phase 2: Fetching commit counts and review timing for $total_prs PRs..."
    
    # Extract repo and PR number, then fetch commits
    while IFS= read -r line; do
        repo=$(echo "$line" | jq -r '.repo')
        pr_num=$(echo "$line" | jq -r '.number')
        echo "$ORG $repo $pr_num"
    done < "$pr_data_file" | xargs -P "$PARALLEL_JOBS" -L 1 "$commit_worker" >> "$commit_counts_file" 2>>"$errors_file"
    
    # Merge commit counts back into PR data
    log_info "Phase 3: Aggregating results..."
    
    local result
    if [[ -s "$pr_data_file" ]]; then
        # Build commit and publishedAt lookups from TSV file
        declare -A commit_lookup
        declare -A published_lookup
        while IFS=$'\t' read -r repo pr_num commits published_at; do
            commit_lookup["${repo}_${pr_num}"]="${commits:-0}"
            published_lookup["${repo}_${pr_num}"]="${published_at:-}"
        done < "$commit_counts_file"
        
        # Add commits and published_at to PR data and aggregate
        result=$(cat "$pr_data_file" | while IFS= read -r line; do
            repo=$(echo "$line" | jq -r '.repo')
            pr_num=$(echo "$line" | jq -r '.number')
            commits="${commit_lookup["${repo}_${pr_num}"]:-0}"
            published_at="${published_lookup["${repo}_${pr_num}"]:-}"
            echo "$line" | jq -c --argjson commits "$commits" --arg pub "$published_at" '. + {commits: $commits, published_at: (if $pub == "" then null else $pub end)}'
        done | jq -s --arg since "$SINCE" --arg until "$UNTIL" --argjson repos_scanned "$repo_count" '
            def parse_iso: sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
            # Group by author
            group_by(.author) |
            map({
                user: .[0].author,
                prs_merged: [.[] | select(.merged == true)] | length,
                prs_opened: length,
                # Only count lines/files/commits from MERGED PRs
                additions: ([.[] | select(.merged == true) | .additions] | add // 0),
                deletions: ([.[] | select(.merged == true) | .deletions] | add // 0),
                files_changed: ([.[] | select(.merged == true) | .changed_files] | add // 0),
                commits: ([.[] | select(.merged == true) | .commits] | add // 0),
                repos: [.[] | select(.merged == true) | .repo] | unique,
                pr_details: [.[] | select(.merged == true) | {repo: .repo, number: .number, title: .title, additions: .additions, deletions: .deletions}],
                review_hours_list: [.[] | select(.merged == true and .merged_at != null) |
                    ((.merged_at | parse_iso) - ((.published_at // .created_at) | parse_iso)) / 3600 |
                    if . < 0 then 0 else . end
                ]
            }) |
            # Calculate averages
            map(. + {
                avg_pr_size: (if .prs_merged > 0 then ((.additions + .deletions) / .prs_merged | floor) else 0 end),
                avg_review_hours: (if (.review_hours_list | length) > 0 then (.review_hours_list | add / length * 10 | floor) / 10 else null end),
                total_review_hours: (.review_hours_list | add // 0),
                review_pr_count: (.review_hours_list | length)
            } | del(.review_hours_list)) |
            # Convert to object keyed by user
            reduce .[] as $item ({}; .[$item.user] = ($item | del(.user))) |
            # Build final structure
            {
                users: .,
                summary: {
                    total_prs_merged: ([.[]] | map(.prs_merged) | add // 0),
                    total_prs_opened: ([.[]] | map(.prs_opened) | add // 0),
                    total_additions: ([.[]] | map(.additions) | add // 0),
                    total_deletions: ([.[]] | map(.deletions) | add // 0),
                    total_files: ([.[]] | map(.files_changed) | add // 0),
                    total_commits: ([.[]] | map(.commits) | add // 0),
                    repos_scanned: $repos_scanned,
                    active_contributors: (keys | length),
                    avg_lines_per_pr: (([.[]] | map(.prs_merged) | add // 0) as $m | if $m > 0 then ((([.[]] | map(.additions) | add // 0) + ([.[]] | map(.deletions) | add // 0)) / $m | floor) else 0 end),
                    avg_review_hours: (
                        ([.[]] | map(.total_review_hours) | add // 0) as $th |
                        ([.[]] | map(.review_pr_count) | add // 0) as $tc |
                        if $tc > 0 then ($th / $tc * 10 | floor) / 10 else null end
                    )
                },
                period: {
                    since: $since,
                    until: $until
                }
            }
        ')
    else
        result=$(jq -n --arg since "$SINCE" --arg until "$UNTIL" --argjson repos_scanned "$repo_count" '{
            users: {},
            summary: {
                total_prs_merged: 0,
                total_prs_opened: 0,
                total_additions: 0,
                total_deletions: 0,
                total_files: 0,
                total_commits: 0,
                repos_scanned: $repos_scanned,
                active_contributors: 0,
                avg_lines_per_pr: 0,
                avg_review_hours: null
            },
            period: {
                since: $since,
                until: $until
            }
        }')
    fi
    
    # Check for errors
    if [[ -s "$errors_file" ]] && [[ "$DEBUG" == "true" ]]; then
        log_debug "Errors during processing:"
        head -20 "$errors_file" >&2
    fi
    
    echo "$result"
}

# Load historical data
load_history() {
    if [[ -f "$HISTORY_FILE" ]] && [[ -s "$HISTORY_FILE" ]]; then
        # Validate that it's proper JSON with a weeks array
        if jq -e '.weeks' "$HISTORY_FILE" > /dev/null 2>&1; then
            cat "$HISTORY_FILE"
        else
            echo '{"weeks": []}'
        fi
    else
        echo '{"weeks": []}'
    fi
}

# Save to history
save_to_history() {
    local current_data="$1"
    local hist_data
    hist_data=$(load_history)
    
    local week_entry
    week_entry=$(echo "$current_data" | jq -c '{
        date: .period.until,
        since: .period.since,
        until: .period.until,
        users: .users,
        summary: .summary
    }')
    
    local new_date
    new_date=$(echo "$week_entry" | jq -r '.date')
    
    # Keep last 12 weeks, replacing entry if same date exists
    hist_data=$(echo "$hist_data" | jq --argjson new "$week_entry" --arg new_date "$new_date" '
        .weeks = ([$new] + [.weeks[] | select(.date != $new_date)])[0:12]
    ')
    
    mkdir -p "$DATA_DIR"
    echo "$hist_data" > "$HISTORY_FILE"
    
    echo "$hist_data"
}

# Calculate trends
calculate_trends() {
    local current_data="$1"
    local hist_data="$2"
    
    local prev_week
    prev_week=$(echo "$hist_data" | jq '.weeks[1] // null')
    
    if [[ "$prev_week" == "null" || -z "$prev_week" ]]; then
        echo "$current_data" | jq '.trends = {"available": false, "message": "No previous data for comparison"}'
        return
    fi
    
    local result
    result=$(echo "$current_data" | jq --argjson prev "$prev_week" '
        .trends = {
            "available": true,
            "week_over_week": {}
        } |
        .users = (.users | to_entries | map(
            .value.trend = (
                (.value.prs_merged // 0) - ($prev.users[.key].prs_merged // 0)
            ) |
            .
        ) | from_entries)
    ')
    
    # Calculate team-level trends
    local current_prs prev_prs current_additions prev_additions
    current_prs=$(echo "$current_data" | jq '.summary.total_prs_merged')
    prev_prs=$(echo "$prev_week" | jq '.summary.total_prs_merged // 0')
    current_additions=$(echo "$current_data" | jq '.summary.total_additions')
    prev_additions=$(echo "$prev_week" | jq '.summary.total_additions // 0')
    
    local pr_change pct_change
    pr_change=$((current_prs - prev_prs))
    if [[ $prev_prs -gt 0 ]]; then
        pct_change=$(echo "scale=1; ($pr_change * 100) / $prev_prs" | bc 2>/dev/null || echo "N/A")
    else
        pct_change="N/A"
    fi
    
    result=$(echo "$result" | jq --argjson pr_change "$pr_change" --arg pct "$pct_change" '
        .trends.pr_change = $pr_change |
        .trends.pr_change_pct = $pct
    ')
    
    # Calculate 4-week rolling average
    local rolling_avg
    rolling_avg=$(echo "$hist_data" | jq '
        [.weeks[0:4][].summary.total_prs_merged] | 
        if length > 0 then (add / length | floor) else 0 end
    ')
    
    result=$(echo "$result" | jq --argjson avg "$rolling_avg" '
        .trends.rolling_avg_4week = $avg
    ')
    
    echo "$result"
}

# Generate CSV report
generate_csv() {
    local data="$1"
    local output_file="${OUTPUT_DIR}/report.csv"
    
    echo "User,PRs Merged,PRs Opened,Lines Added,Lines Removed,Files Changed,Commits,Avg PR Size,Avg Review Hrs,Trend" > "$output_file"
    
    echo "$data" | jq -r '
        .users | to_entries | sort_by(-.value.prs_merged) | .[] |
        [
            .key,
            (.value.prs_merged // 0),
            (.value.prs_opened // 0),
            (.value.additions // 0),
            (.value.deletions // 0),
            (.value.files_changed // 0),
            (.value.commits // 0),
            (.value.avg_pr_size // 0),
            (.value.avg_review_hours // "N/A"),
            (.value.trend // 0)
        ] | @csv
    ' >> "$output_file"
    
    log_success "CSV report: $output_file"
}

# Generate JSON report
generate_json() {
    local data="$1"
    local output_file="${OUTPUT_DIR}/report.json"
    
    echo "$data" | jq '.' > "$output_file"
    
    log_success "JSON report: $output_file"
}

# Generate Markdown report
generate_markdown() {
    local data="$1"
    local output_file="${OUTPUT_DIR}/report.md"
    
    local since until total_prs_merged total_prs_opened total_additions total_deletions
    local total_files total_commits active_contributors repos_scanned avg_lines_per_pr
    local avg_review_hours avg_review_time_fmt
    since=$(echo "$data" | jq -r '.period.since')
    until=$(echo "$data" | jq -r '.period.until')
    total_prs_merged=$(echo "$data" | jq -r '.summary.total_prs_merged')
    total_prs_opened=$(echo "$data" | jq -r '.summary.total_prs_opened')
    total_additions=$(echo "$data" | jq -r '.summary.total_additions')
    total_deletions=$(echo "$data" | jq -r '.summary.total_deletions')
    total_files=$(echo "$data" | jq -r '.summary.total_files')
    total_commits=$(echo "$data" | jq -r '.summary.total_commits')
    active_contributors=$(echo "$data" | jq -r '.summary.active_contributors')
    repos_scanned=$(echo "$data" | jq -r '.summary.repos_scanned')
    avg_lines_per_pr=$(echo "$data" | jq -r '.summary.avg_lines_per_pr')
    avg_review_hours=$(echo "$data" | jq -r '.summary.avg_review_hours // "null"')
    avg_review_time_fmt=$(format_review_time "$avg_review_hours")
    
    # Format large numbers with commas
    total_additions_fmt=$(printf "%'d" "$total_additions" 2>/dev/null || echo "$total_additions")
    total_deletions_fmt=$(printf "%'d" "$total_deletions" 2>/dev/null || echo "$total_deletions")
    
    cat > "$output_file" << EOF
# PR Contributions Report: ${since} to ${until}

## Summary

EOF

    {
        printf 'L\tR\n'
        printf 'Metric\tValue\n'
        printf 'Total PRs Merged\t%s\n' "$total_prs_merged"
        printf 'Total PRs Opened\t%s\n' "$total_prs_opened"
        printf 'Lines Added\t%s\n' "$total_additions_fmt"
        printf 'Lines Removed\t%s\n' "$total_deletions_fmt"
        printf 'Files Changed\t%s\n' "$total_files"
        printf 'Total Commits\t%s\n' "$total_commits"
        printf 'Avg Lines Changed/PR\t%s\n' "$avg_lines_per_pr"
        printf 'Avg Review Time\t%s\n' "$avg_review_time_fmt"
        printf 'Active Contributors\t%s\n' "$active_contributors"
        printf 'Repos Scanned\t%s\n' "$repos_scanned"
    } | format_markdown_table >> "$output_file"

    echo "" >> "$output_file"

    local trends_available
    trends_available=$(echo "$data" | jq -r '.trends.available // false')
    
    if [[ "$trends_available" == "true" ]]; then
        local pr_change pr_pct rolling_avg
        pr_change=$(echo "$data" | jq -r '.trends.pr_change')
        pr_pct=$(echo "$data" | jq -r '.trends.pr_change_pct')
        rolling_avg=$(echo "$data" | jq -r '.trends.rolling_avg_4week')
        
        local trend_indicator
        if [[ $pr_change -gt 0 ]]; then
            trend_indicator="↑"
        elif [[ $pr_change -lt 0 ]]; then
            trend_indicator="↓"
        else
            trend_indicator="→"
        fi
        
        cat >> "$output_file" << EOF
## Trends

- **Week-over-Week PRs**: ${trend_indicator} ${pr_change} (${pr_pct}%)
- **4-Week Rolling Average**: ${rolling_avg} PRs/week

EOF
    fi

    echo "## Contributors" >> "$output_file"
    echo "" >> "$output_file"

    {
        printf 'L\tR\tR\tR\tR\tR\tR\tR\tL\tL\n'
        printf 'User\tPRs Merged\tPRs Opened\tLines +\tLines -\tFiles\tCommits\tAvg Size\tReview Time\tTrend\n'
        echo "$data" | jq -r '
            def fmt_review:
                if . == null then "N/A"
                elif . < 1 then ((. * 60 | floor | tostring) + "m")
                elif . < 24 then (((. * 10 | floor) / 10 | tostring) + "h")
                else ((((. / 24) * 10 | floor) / 10 | tostring) + "d")
                end;
            .users | to_entries |
            sort_by(-.value.prs_merged) | .[] |
            [
                .key,
                ((.value.prs_merged // 0) | tostring),
                ((.value.prs_opened // 0) | tostring),
                ((.value.additions // 0) | tostring),
                ((.value.deletions // 0) | tostring),
                ((.value.files_changed // 0) | tostring),
                ((.value.commits // 0) | tostring),
                ((.value.avg_pr_size // 0) | tostring),
                (.value.avg_review_hours | fmt_review),
                ((if (.value.trend // 0) > 0 then "↑ +" elif (.value.trend // 0) < 0 then "↓ " else "→ " end) + ((.value.trend // 0) | tostring))
            ] | @tsv
        '
    } | format_markdown_table >> "$output_file"
    
    # Add PR details section if --details flag is set
    if [[ "$SHOW_DETAILS" == "true" ]]; then
        cat >> "$output_file" << EOF

## PR Details by Contributor

EOF
        echo "$data" | jq -r '
            .users | to_entries | 
            sort_by(-.value.prs_merged) | .[] |
            select(.value.prs_merged > 0) |
            "### " + .key + " (" + (.value.prs_merged | tostring) + " PRs merged)\n" +
            (.value.pr_details | map("- [" + .repo + "#" + (.number | tostring) + "] " + .title + " (+" + (.additions | tostring) + "/-" + (.deletions | tostring) + ")") | join("\n")) +
            "\n"
        ' >> "$output_file"
    fi
    
    cat >> "$output_file" << EOF
---
*Generated on $(date '+%Y-%m-%d %H:%M:%S')*
EOF

    log_success "Markdown report: $output_file"
}

# Main function
main() {
    parse_args "$@"
    check_dependencies
    
    echo "" >&2
    log_info "GitHub PR Contributions Tracker"
    log_info "Organization: $ORG"
    log_info "Period: $SINCE to $UNTIL"
    log_info "Parallel jobs: $PARALLEL_JOBS"
    echo "" >&2
    
    mkdir -p "$OUTPUT_DIR"
    
    log_info "Collecting contribution data..."
    local contribution_data
    contribution_data=$(collect_contribution_data)
    
    log_info "Updating historical data..."
    local hist_data
    hist_data=$(save_to_history "$contribution_data")
    
    log_info "Calculating trends..."
    local data_with_trends
    data_with_trends=$(calculate_trends "$contribution_data" "$hist_data")
    
    echo "" >&2
    log_info "Generating reports..."
    generate_csv "$data_with_trends"
    generate_json "$data_with_trends"
    generate_markdown "$data_with_trends"
    
    echo "" >&2
    log_success "Reports generated in: $OUTPUT_DIR"
    echo "" >&2
    
    # Print quick summary
    local prs_merged prs_opened additions deletions contributors avg_lines
    local avg_review_hrs avg_review_fmt
    prs_merged=$(echo "$data_with_trends" | jq -r '.summary.total_prs_merged')
    prs_opened=$(echo "$data_with_trends" | jq -r '.summary.total_prs_opened')
    additions=$(echo "$data_with_trends" | jq -r '.summary.total_additions')
    deletions=$(echo "$data_with_trends" | jq -r '.summary.total_deletions')
    contributors=$(echo "$data_with_trends" | jq -r '.summary.active_contributors')
    avg_lines=$(echo "$data_with_trends" | jq -r '.summary.avg_lines_per_pr')
    avg_review_hrs=$(echo "$data_with_trends" | jq -r '.summary.avg_review_hours // "null"')
    avg_review_fmt=$(format_review_time "$avg_review_hrs")
    
    echo "Quick Summary:" >&2
    echo "  PRs Merged: $prs_merged" >&2
    echo "  PRs Opened: $prs_opened" >&2
    echo "  Lines Added: $additions" >&2
    echo "  Lines Removed: $deletions" >&2
    echo "  Avg Lines Changed/PR: $avg_lines" >&2
    echo "  Avg Review Time: $avg_review_fmt" >&2
    echo "  Active Contributors: $contributors" >&2
}

main "$@"
