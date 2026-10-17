#!/usr/bin/env bash
#
# end-run.sh — finish an /orchestrate run: review, preview, push, ONE pull request, clean up.
#
# Usage: bash end-run.sh <runid>
#
# In order:
#   1. the integration review (follow-up.sh --integration) of <launch HEAD>..HEAD — cross-issue
#      problems only; high/medium ones become one follow-up issue.
#   2. the end-merge preview (merge-fold.sh --preview) against the launch branch's upstream,
#      or the local branch when it has none.
#   3. `git push -u origin orchestrate-<runid>` and `gh pr create` into the LAUNCH branch. The
#      body is the per-issue table plus one `Closes #N` per merged slice: the slices close when
#      the PR merges. GitHub honours `Closes` only on the DEFAULT branch, so a PR into any other
#      branch (a `dev` workflow) says so loudly, in the body and the output: those slices must
#      be closed by hand after the merge (the next launch skips them either way — launch.sh
#      drops issues already merged into its branch). The run never closes an issue and never
#      merges the PR.
#   4. cleanup: session-gc.sh --run <runid>; every issue's provisioned env file; this run's
#      worker transcripts in the boxes (by the session ids in its event logs).
#
# Nothing merged → nothing pushed and no PR, and it says so.
# Output: the table, the review / preview lines, then `pr: <url>` (or why there is none).

set -uo pipefail
# shellcheck source=run-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-env.sh"

[ $# -eq 1 ] || die "usage: end-run.sh <runid>"
load_run "$1"
cd "$ORCH_WT" || die "no orchestration worktree at $ORCH_WT"
TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "${TMP:?}"' EXIT
HEAD="$(git rev-parse HEAD)"

# --- 1. integration review -----------------------------------------------------------
if [ "$HEAD" = "$BASE_SHA" ]; then
    INTEG="integration review: nothing merged"
elif bash "$WF/follow-up.sh" --integration "$RUNID" "$BASE_SHA" "$HEAD" "$GRAPH" >"$TMP/int.out" 2>"$TMP/int.err"; then
    INTEG="integration review: $(tail -1 "$TMP/int.out" 2>/dev/null)$(tail -1 "$TMP/int.err" 2>/dev/null | sed 's/^/ /')"
else
    INTEG="integration review FAILED: $(tail -1 "$TMP/int.err")"
fi

# --- 2. end-merge preview ------------------------------------------------------------
UP="$(git rev-parse --abbrev-ref --symbolic-full-name "$BASE_BRANCH@{upstream}" 2>/dev/null)" || UP=""
PREVIEW="preview vs ${UP:-$BASE_BRANCH (no upstream)}: $(bash "$WF/merge-fold.sh" --preview "${UP:-$BASE_BRANCH}" 2>&1 | tail -1)"

# --- the table -----------------------------------------------------------------------
runlog replay "$RUNID" >"$TMP/log.jsonl" 2>/dev/null || : >"$TMP/log.jsonl"
python3 - "$GRAPH" "$TMP/log.jsonl" >"$TMP/table.md" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1]))
merged, held, esc, admitted = {}, {}, {}, set()
for line in open(sys.argv[2]):
    try:
        r = json.loads(line)
    except Exception:
        continue
    n, e = r.get("n"), r.get("event")
    if e == "merged": merged[n] = str(r.get("sha") or "")[:7]
    elif e == "held": held[n] = r.get("why") or ""
    elif e == "escalated": esc.setdefault(n, []).append(r.get("reason") or "?")
    elif e == "admitted": admitted.add(n)
print("| # | title | tier | outcome | escalations |")
print("|---|---|---|---|---|")
for i in graph.get("issues") or []:
    n = i.get("n")
    if n in merged: out = "merged %s" % merged[n]
    elif n in held: out = "held: %s" % held[n]
    elif n in admitted: out = "in flight at end"
    else: out = "not built"
    title = (i.get("title") or "").replace("|", "/")
    print("| #%s | %s | %s | %s | %s |" % (n, title, i.get("tier") or "-", out, ", ".join(esc.get(n, [])) or "-"))
PY
MERGED="$(run_state merged)"
DEFAULT="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
NOCLOSE=""
if [ -n "${MERGED// /}" ] && [ -n "$DEFAULT" ] && [ "$DEFAULT" != "$BASE_BRANCH" ]; then
    NOCLOSE="NOTE: this PR targets $BASE_BRANCH, not the default branch $DEFAULT — GitHub will NOT close $(printf '%s' "$MERGED" | xargs | sed 's/[0-9][0-9]*/#&/g; s/ /, /g') when it merges. Close them by hand after merging."
fi
{
    [ -z "$NOCLOSE" ] || { echo "> $NOCLOSE"; echo; }
    cat "$TMP/table.md"
    echo
    echo "- $INTEG"
    echo "- $PREVIEW"
    echo "- \`.worktrees/\` and \`.claude/worktrees/\` were added to this repo's local \`.git/info/exclude\` and stay there."
    echo
    for n in $MERGED; do echo "Closes #$n"; done
} >"$TMP/body.md"

# --- 3. push and the one PR ----------------------------------------------------------
PR="pr: none — nothing merged"
if [ -n "${MERGED// /}" ]; then
    if ! git remote get-url origin >/dev/null 2>&1; then
        PR="pr: none — no origin remote; the work is on $ORCH_BRANCH"
    elif ! git push -q -u origin "$ORCH_BRANCH" >"$TMP/push.out" 2>&1; then
        PR="pr: none — push failed: $(tail -1 "$TMP/push.out")"
    else
        TITLE="orchestrate $RUNID: ${PRD:+PRD #$PRD, }$(printf '%s' "$MERGED" | xargs | sed 's/[0-9][0-9]*/#&/g; s/ /, /g')"
        if URL="$(gh pr create --base "$BASE_BRANCH" --head "$ORCH_BRANCH" --title "$TITLE" --body-file "$TMP/body.md" 2>"$TMP/pr.err")"; then
            PR="pr: $(printf '%s' "$URL" | tail -1)"
        else
            PR="pr: none — gh pr create failed: $(tail -1 "$TMP/pr.err")"
        fi
    fi
fi

# --- 4. cleanup ----------------------------------------------------------------------
GC="$(bash "$INFRA/session-gc.sh" --run "$RUNID" 2>&1 | tail -1)"
find "$RUN_DIR" -mindepth 2 -maxdepth 2 -path '*/issue-*/env' -type f -delete 2>/dev/null
BOXES="${CLAUDE_BOX_ROOT:-${HOME:-/nonexistent}/.claude/kit/boxes}"
GONE=0
for sid in $(cat "$RUN_DIR"/issue-*/events.jsonl 2>/dev/null \
        | jq -rR 'fromjson? | select(type == "object" and .type == "system" and .subtype == "init") | .session_id // empty' \
        | sort -u); do
    case "$sid" in *[!A-Za-z0-9-]*) continue ;; esac
    while IFS= read -r f; do
        rm -rf -- "$f" && GONE=$((GONE + 1))
    done < <(find "$BOXES" -path '*/projects/*' \( -name "$sid.jsonl" -o -name "$sid" \) -prune -print 2>/dev/null)
done

cat "$TMP/table.md"
echo
echo "$INTEG"
echo "$PREVIEW"
echo "cleanup: ${GC:-session-gc gave no output}; env files removed; $GONE worker transcript path(s) removed"
[ -z "$NOCLOSE" ] || echo "$NOCLOSE"
echo "$PR"
