# gh-pr-contributions

A bash script that generates PR contribution reports for a GitHub organization — who merged/opened PRs, how much code they shipped, how fast reviews happened, and how it trends week over week.

## What it does

`pr-contributions.sh` uses the [GitHub CLI](https://cli.github.com/) (`gh`) to:

1. List every repo in a GitHub org (or a subset you specify).
2. Pull all PRs from each repo that were **created or merged** within a date window.
3. For each PR, fetch its commit count and `publishedAt` timestamp (used to measure review time).
4. Aggregate everything per-contributor: PRs merged/opened, lines added/removed, files changed, commits, average PR size, and average review time.
5. Compare against saved history to compute week-over-week trends and a 4-week rolling average.
6. Write out `report.csv`, `report.json`, and `report.md` to a reports directory.

Data collection is parallelized (repo fetch and per-PR commit/review lookups both run through `xargs -P`) since orgs with many repos/PRs would otherwise be too slow to query serially.

## Requirements

- [`gh`](https://cli.github.com/) (GitHub CLI), authenticated via `gh auth login`
- [`jq`](https://stedolan.github.io/jq/)
- `bash`, `bc` (for time-math formatting) — standard on macOS/Linux

## Usage

```bash
./pr-contributions.sh --org <organization> [options]
```

### Options

| Flag | Description | Default |
| --- | --- | --- |
| `--org <name>` | GitHub organization name (**required**) | — |
| `--since <date>` | Start date, `YYYY-MM-DD` | `--days` ago |
| `--until <date>` | End date, `YYYY-MM-DD` | today |
| `--repos <list>` | Comma-separated repo names to scan | all repos in the org |
| `--output <dir>` | Output directory for reports | `./reports/<until>` |
| `--days <n>` | Lookback window in days (ignored if `--since` is set) | `7` |
| `--jobs <n>` | Number of parallel `gh` calls | `10` |
| `--details` | Include a per-contributor list of PR titles in the markdown report | off |
| `--debug` | Verbose logging (also dumps worker errors) | off |
| `-h`, `--help` | Show usage | — |

### Examples

```bash
# Last 7 days for an org, using defaults
./pr-contributions.sh --org myorg

# A specific date range
./pr-contributions.sh --org myorg --since 2026-02-12 --until 2026-02-19

# Only specific repos
./pr-contributions.sh --org myorg --repos "repo1,repo2"

# More parallelism (larger orgs / more PRs)
./pr-contributions.sh --org myorg --jobs 20

# Include per-contributor PR titles in the markdown report
./pr-contributions.sh --org myorg --details
```

## How it works internally

The script has three phases per run (see `collect_contribution_data`):

1. **Fetch PRs** — `gh repo list` gets all repo names, then a worker script (`gh pr list ... --json ...`) runs per repo in parallel, filtering PRs whose `mergedAt` (or `createdAt`, if unmerged) falls in `[since, until]`.
2. **Fetch commit counts & review timing** — for every PR found, a second worker script runs a GraphQL query (`gh api graphql`) in parallel to get the commit count and `publishedAt` (when the PR left draft state — used as the start of the "review clock" instead of `createdAt`).
3. **Aggregate** — results are merged and grouped by author with `jq`, computing per-user and org-wide totals/averages. Only **merged** PRs count toward lines/files/commits/review-time metrics; both merged and unmerged PRs count toward "PRs opened."

After aggregation:

- **History** (`data/history.json`) stores the last 12 weekly snapshots (by `until` date) so trends can be computed. This file is git-ignored since it may contain usernames.
- **Trends** are computed by diffing the current run against the most recent previous entry in history (week-over-week PR count change, per-user trend deltas, and a 4-week rolling average).
- **Reports** are written to `reports/<until-date>/` (or `--output`) as `report.csv`, `report.json`, and `report.md`. The reports directory is git-ignored.

## Output

Each run produces (in the output directory):

- `report.csv` — one row per contributor: PRs merged/opened, lines added/removed, files changed, commits, avg PR size, avg review hours, trend.
- `report.json` — the full aggregated data structure (`users`, `summary`, `period`, `trends`), useful for feeding into other tools.
- `report.md` — a human-readable summary with:
  - **Summary** table (org-wide totals for the period)
  - **Trends** section (week-over-week change, 4-week rolling average) — only shown once at least one prior week of history exists
  - **Contributors** table, sorted by PRs merged
  - **PR Details by Contributor** (only with `--details`) — a bulleted list of every merged PR's title and +/- line counts, grouped by author

See `reports/*/report.md` for real examples of the generated output.

## Notes

- "Review time" is measured from when a PR was published (left draft, or created if never drafted) to when it was merged.
- Large numbers (like total lines added/removed) are comma-formatted in the markdown report.
- `data/history.json` is excluded from git (contains contributor usernames); a `.gitkeep` keeps the `data/` directory itself tracked.
