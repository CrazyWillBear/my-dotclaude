#!/usr/bin/env bash
#
# launch.sh — start an /orchestrate session-lane run: checks, scope, graph, worktree, run.env.
#
# Usage:
#   bash launch.sh <runid> (--prd N | --issues N,N,...) [--max N] [--allow-behind] [--skip-unknown]
#
# Run from the checkout whose current branch the run builds on (the LAUNCH BRANCH). In order:
#   1. dependency checks — the kit links, the three worker boxes, claude, gh, jq, git;
#      codex only when a scoped tier's chain uses it. Any gap: `error: …`, exit 1.
#   2. the allowlist — `--issues` literally, or `--prd N`'s open `ready-for-agent` children
#      (not hitl/prd) via prd-children.sh. Never a repo-wide query (#77 defect A). A PRD whose
#      children are all closed prints `prd #N: 0 open children` and `nothing-to-do: …`, exit 0:
#      the caller offers the PRD close. NO children listed — gh failed, or the PRD is not
#      sliced yet — is an error, never a close offer.
#      With --prd, children an earlier run already merged into this branch (a `merged` event
#      in this repo's run logs whose commit is an ancestor of HEAD) are dropped: `Closes #N`
#      only fires when the PR lands on the default branch, so a merged slice can still be
#      open. An explicit --issues list is never filtered — a reopened issue is built again.
#   3. the graph, fetched once (scope-graph.sh) — tiers come from its `tier` field (the
#      highest `tier:*` label wins). Unlabelled issues: `missing-tier: 12 15`, exit 3, nothing
#      written — the caller backfills with /classify-task and reruns. An unfetchable issue is
#      an error unless --skip-unknown.
#   4. the launch fetch check — merge-fold.sh <launch branch>; exit 2 (base behind upstream)
#      is passed through as exit 2 unless --allow-behind.
#   5. the orchestration worktree — branch orchestrate-<runid> at the launch HEAD, at
#      <repo>/.claude/worktrees/orchestrate-<runid>; the caller enters it with
#      EnterWorktree(path). `.worktrees/` and `.claude/worktrees/` go into the repo's LOCAL
#      exclude (info/exclude), a mutation of the user's repo that outlives the run.
#   6. run-log `scope`, and <runroot>/<runid>/run.env for every later script.
#
# Output: `prd #N: k open children` (with --prd), then ONE line:
#   launch: run <runid> base=<branch>@<sha7> worktree=<path> scope=… tiers=N:t,… source=… upstream=… max=N

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

USAGE="usage: launch.sh <runid> (--prd N | --issues N,N,...) [--max N] [--allow-behind] [--skip-unknown]"
RUNID="${1:-}"; [ $# -gt 0 ] && shift
check_runid "$RUNID"
PRD=""; ISSUES=""; MAX=8; BEHIND=""; SKIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prd)          [ $# -ge 2 ] || die "$USAGE"; PRD="${2#\#}"; shift 2 ;;
        --issues)       [ $# -ge 2 ] || die "$USAGE"; ISSUES="$2"; shift 2 ;;
        --max)          [ $# -ge 2 ] || die "$USAGE"; MAX="$2"; shift 2 ;;
        --allow-behind) BEHIND=--allow-behind; shift ;;
        --skip-unknown) SKIP=1; shift ;;
        *) die "unknown flag $1 — $USAGE" ;;
    esac
done
[ -n "$PRD" ] || [ -n "$ISSUES" ] || die "$USAGE"
[ -z "$PRD" ] || [ -z "$ISSUES" ] || die "--prd and --issues are exclusive — $USAGE"
case "$PRD" in *[!0-9]*) die "--prd must be an issue number, got '$PRD'" ;; esac
case "$MAX" in ''|0|*[!0-9]*) die "--max must be a number of 1 or more, got '$MAX'" ;; esac
RUN_DIR="$RUNROOT/$RUNID"
[ ! -e "$RUN_DIR/run.env" ] || die "run $RUNID was already launched ($RUN_DIR/run.env)"

# --- 1. dependencies -----------------------------------------------------------------
KIT="${HOME:-/nonexistent}/.claude/kit"
BOXES="${CLAUDE_BOX_ROOT:-$KIT/boxes}"
GAPS=()
for c in claude gh jq git python3 flock timeout nohup; do command -v "$c" >/dev/null 2>&1 || GAPS+=("$c not on PATH"); done
[ -f "$INFRA/spawn.sh" ] || GAPS+=("infra scripts missing at $INFRA (start a session so link-kit.sh links ~/.claude/kit/infra)")
[ -d "$KIT/personal-tools/agents" ] || GAPS+=("$KIT/personal-tools missing — the reviewer box loads my-review from it")
for role in implementer planner reviewer; do
    [ -f "$BOXES/$role/CLAUDE.md" ] || GAPS+=("worker box missing: $BOXES/$role")
done
[ "${#GAPS[@]}" -eq 0 ] || die "$(printf '%s; ' "${GAPS[@]}")"

BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || die "not in a git repo"
[ "$BASE_BRANCH" != HEAD ] || die "detached HEAD — check out the branch the run should build on"
BASE_SHA="$(git rev-parse HEAD)"
BASE_REPO="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
ORCH_BRANCH="orchestrate-$RUNID"
ORCH_WT="$BASE_REPO/.claude/worktrees/$ORCH_BRANCH"
! git show-ref --verify --quiet "refs/heads/$ORCH_BRANCH" || die "branch $ORCH_BRANCH already exists"

# --- 2. the allowlist ----------------------------------------------------------------
if [ -n "$PRD" ]; then
    CHILDREN="$(bash "$WF/prd-children.sh" "$PRD")"
    [ -n "$CHILDREN" ] || die "could not list PRD #$PRD's children (gh failed, or it has no slices yet)"
    OPEN="$(printf '%s\n' "$CHILDREN" | awk '$2 == "open"' | grep -c . || true)"
    echo "prd #$PRD: $OPEN open children"
    if [ "$OPEN" -eq 0 ]; then
        echo "nothing-to-do: PRD #$PRD has no open children"
        exit 0
    fi
    SCOPE="$(printf '%s\n' "$CHILDREN" | awk '$2 == "open" {
        n = split($3, l, ","); ok = 0; bad = 0
        for (i = 1; i <= n; i++) { if (l[i] == "ready-for-agent") ok = 1; if (l[i] == "hitl" || l[i] == "prd") bad = 1 }
        if (ok && !bad) print $1 }' | sort -n | tr '\n' ' ')"
else
    SCOPE="$(printf '%s' "$ISSUES" | tr ',' ' ')"
fi
for n in $SCOPE; do case "${n#\#}" in ''|*[!0-9]*) die "not an issue number: '$n'" ;; esac; done
SCOPE="$(for n in $SCOPE; do printf '%s\n' "${n#\#}"; done | sort -nu | tr '\n' ' ')"
RUNS="$(dirname "$(bash "$WF/run-log.sh" path probe 2>/dev/null)")"
DONE=""
[ -n "$PRD" ] || RUNS=/nonexistent
for n in $SCOPE; do
    for sha in $(cat "$RUNS"/*.jsonl 2>/dev/null | jq -rR --argjson n "$n" \
            'fromjson? | select(type == "object" and .event == "merged" and .n == $n) | .sha // empty'); do
        case "$sha" in ''|*[!0-9a-f]*) continue ;; esac
        if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then DONE="$DONE $n"; break; fi
    done
done
if [ -n "$DONE" ]; then
    echo "already-merged:$DONE"
    SCOPE="$(for n in $SCOPE; do case " $DONE " in *" $n "*) ;; *) printf '%s ' "$n" ;; esac; done)"
fi
[ -n "${SCOPE// /}" ] || die "the allowlist is empty — nothing to build (an empty scope is never widened)"

# --- 3. the graph and the tiers ------------------------------------------------------
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC2086
bash "$WF/scope-graph.sh" $SCOPE >"$TMP/graph.json"
jq -e '.issues | length > 0' "$TMP/graph.json" >/dev/null 2>&1 || die "scope-graph.sh returned no graph (gh failed?) — not degrading into a repo-wide query"
UNKNOWN="$(jq -r '[.issues[] | select(.state == "unknown") | .n] | join(" ")' "$TMP/graph.json")"
[ -z "$UNKNOWN" ] || [ -n "$SKIP" ] || die "could not fetch: $UNKNOWN (rerun with --skip-unknown to skip them)"
MISSING="$(jq -r '[.issues[] | select(.state == "open" and .tier == null) | .n] | join(" ")' "$TMP/graph.json")"
if [ -n "$MISSING" ]; then
    echo "missing-tier: $MISSING"
    exit 3
fi
TIERS="$(jq -r '[.issues[] | select(.tier != null) | "\(.n):\(.tier)"] | join(",")' "$TMP/graph.json")"
for t in $(jq -r '[.issues[].tier // empty] | unique | .[]' "$TMP/graph.json"); do
    chain="$(bash "$INFRA/resolve-tier.sh" "$t" 0 2>/dev/null | sed -n 's/^implementer_chain=//p')"
    a=0
    while [ "$a" -lt "${chain:-1}" ]; do
        # Captured, never `| grep -q`: under pipefail grep's early exit SIGPIPEs the producer
        # and turns a match into a failure.
        backend="$(bash "$INFRA/resolve-tier.sh" "$t" "$a" 2>/dev/null | sed -n 's/^implementer_backend=//p')"
        if [ "$backend" = codex ] && ! command -v codex >/dev/null 2>&1; then
            die "tier '$t' routes to codex but the codex CLI is not installed — write a claude-only table at \${CLAUDE_CONFIG_DIR:-~/.claude}/model-tiers.json"
        fi
        a=$((a + 1))
    done
done
SOURCE="$(bash "$INFRA/resolve-tier.sh" standard 0 2>/dev/null | sed -n 's/^source=//p')"

# --- 4. the launch fetch check -------------------------------------------------------
FOLD="$(bash "$WF/merge-fold.sh" ${BEHIND:+"$BEHIND"} "$BASE_BRANCH" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then
    echo "error: $(printf '%s\n' "$FOLD" | grep -m1 '^behind') — pull first, or rerun with --allow-behind" >&2
    exit 2
fi
[ "$RC" -eq 0 ] || die "the launch fetch check failed: $(printf '%s' "$FOLD" | tail -1)"
UPSTREAM="$(printf '%s\n' "$FOLD" | awk '$1 == "upstream" {print "none"; exit} $1 == "behind" {print "behind:" $3; exit}')"
UPSTREAM="${UPSTREAM:-current}"

# --- 5. the orchestration worktree ---------------------------------------------------
git -C "$BASE_REPO" worktree add -q -b "$ORCH_BRANCH" "$ORCH_WT" "$BASE_SHA" >/dev/null 2>"$TMP/wt.err" \
    || die "could not create the orchestration worktree: $(tail -1 "$TMP/wt.err")"
EXCL="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"
for line in .worktrees/ .claude/worktrees/; do
    grep -qxF "$line" "$EXCL" 2>/dev/null || printf '%s\n' "$line" >>"$EXCL"
done

# --- 6. run state --------------------------------------------------------------------
mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
GRAPH="$RUN_DIR/graph.json"
cp "$TMP/graph.json" "$GRAPH"
{
    # shellcheck disable=SC2034  # read through ${!v} below
    SKIP_UNKNOWN="$SKIP"
    for v in RUNID BASE_SHA BASE_BRANCH BASE_REPO ORCH_BRANCH ORCH_WT GRAPH MAX PRD SKIP_UNKNOWN; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} >"$RUN_DIR/run.env"
runlog append "$RUNID" scope "$(jq -c '{issues: [.issues[].n]}' "$GRAPH")" >/dev/null \
    || die "could not record the scope in the run log"

echo "launch: run $RUNID base=$BASE_BRANCH@${BASE_SHA:0:7} worktree=$ORCH_WT scope=$(printf '%s' "$SCOPE" | xargs | tr ' ' ',') tiers=$TIERS source=${SOURCE:-unknown} upstream=$UPSTREAM max=$MAX"
