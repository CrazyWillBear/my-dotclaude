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
#      the repo's .orchestrate/teardown.sh per issue (the other half of admit.sh's provision.sh);
#      worker transcripts in the boxes (by the session ids in its event logs); every worker
#      worktree and branch (`issue-N`, `prev/issue-N-<runid>`) whose work is already on the run
#      branch. One holding unmerged commits, or a dirty worktree, is kept and counted.
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
    elif e == "released": held.pop(n, None); admitted.discard(n)
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
# Findings a follow-up could not file anywhere: they need a human, so the PR says so.
UNFILED="$(runlog state "$RUNID" 2>/dev/null | sed -n 's/^decision=\(follow-up: .*\)/\1/p')"
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
    [ -z "$UNFILED" ] || printf '%s\n' "$UNFILED" | sed 's/^/- /'
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
# Reported from the command's exit status: a removal that failed is not "done".
GC_OUT="$(bash "$INFRA/session-gc.sh" --run "$RUNID" 2>&1)"; GC_RC=$?
if [ "$GC_RC" -eq 0 ]; then GC="$(printf '%s\n' "$GC_OUT" | tail -1)"
else GC="session-gc FAILED (exit $GC_RC): $(printf '%s\n' "$GC_OUT" | grep '^error:' | tr '\n' ';')"; fi
REAPED="$(bash "$INFRA/reap.sh" "$RUNID/" 2>&1 | tail -1)"
# Test infra the repo's provision.sh stood up (containers, DBs): its teardown.sh, once per issue
# that has a run dir, from the launch commit. Before the env files go — teardown may want them.
TORN=0; TFAIL=0; TEARDOWN=""
if repo_hook teardown "$TMP/teardown.sh"; then
    for d in "$RUN_DIR"/issue-*/; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"; n="${n#issue-}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        if (cd "$BASE_REPO" && timeout "${TEARDOWN_TIMEOUT:-300}" bash "$TMP/teardown.sh" "$RUNID" "$n" "$(worktree_of "$n")" >/dev/null 2>&1 </dev/null); then
            TORN=$((TORN + 1)); else TFAIL=$((TFAIL + 1)); fi
    done
    TEARDOWN="teardown ran for $TORN issue(s)$([ "$TFAIL" -eq 0 ] || echo ", $TFAIL FAILED"); "
fi
# Worker worktrees and branches. Only what the run branch already contains goes: a later run
# on the same issue is otherwise held as "a stale issue-N branch exists". Unmerged work
# (a held slice, a prev/ snapshot) and a dirty worktree stay.
TIDIED=0; KEPT=0
merged_in_run() { git -C "$BASE_REPO" merge-base --is-ancestor "$1" "$ORCH_BRANCH" 2>/dev/null; }
for wt in "$BASE_REPO/.worktrees/$RUNID"/issue-*; do
    [ -d "$wt" ] || continue
    # safe_git: the worker wrote this worktree's git dir; `worktree remove` runs a git status in it.
    if merged_in_run "$(safe_git "$wt" rev-parse HEAD 2>/dev/null)" \
            && git -C "$BASE_REPO" -c core.fsmonitor=false -c core.hooksPath=/dev/null worktree remove "$wt" >/dev/null 2>&1; then TIDIED=$((TIDIED + 1)); else KEPT=$((KEPT + 1)); fi
done
rmdir "$BASE_REPO/.worktrees/$RUNID" 2>/dev/null
for n in $(jq -r '.issues[].n' "$GRAPH"); do   # this run's issues only: a concurrent run's branch is not ours
    for br in "issue-$n" "prev/issue-$n-$RUNID"; do
        git -C "$BASE_REPO" show-ref --verify --quiet "refs/heads/$br" || continue
        [ ! -d "$(worktree_of "$n")" ] || [ "$br" != "issue-$n" ] || continue   # worktree kept → branch stays
        if merged_in_run "$br" && git -C "$BASE_REPO" branch -D "$br" >/dev/null 2>&1; then TIDIED=$((TIDIED + 1)); else KEPT=$((KEPT + 1)); fi
    done
done
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
[ -z "$UNFILED" ] || printf '%s\n' "$UNFILED"
echo "cleanup: ${GC:-session-gc gave no output}; ${REAPED:-reap.sh gave no output}; env files removed; ${TEARDOWN}worktrees/branches: $TIDIED removed, $KEPT kept (unmerged work); $GONE worker transcript path(s) removed"
[ -z "$NOCLOSE" ] || echo "$NOCLOSE"
echo "$PR"
