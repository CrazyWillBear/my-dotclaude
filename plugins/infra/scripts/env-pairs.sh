#!/usr/bin/env bash
# One script, not two copies: spawn.sh and worker-resume.sh must refuse exactly the same
# inputs. Shell launch controls, Git routing/configuration, and infra-owned variables are
# reserved because exports also reach the unsandboxed wrapper and reviewer. No error may
# quote an environment value.

set -uo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

for pair in "$@"; do
    case "$pair" in
        *=*) ;;
        *) die "--env expects NAME=VALUE (an argument had no '=')" ;;
    esac

    name="${pair%%=*}"
    case "$name" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) die "--env name '$name' is not a valid variable name" ;;
    esac

    case "$name" in
        BASH_ENV|ENV|PATH|SHELL|SHELLOPTS|BASHOPTS|IFS|CDPATH|HOME|TMPDIR| \
        LD_*|DYLD_*| \
        NODE_OPTIONS|PYTHONHOME|PYTHONPATH|PERL5OPT|RUBYOPT| \
        GIT_*| \
        GH_CONFIG_DIR|XDG_CONFIG_HOME|CODEX_HOME|CODEX_RUN_ROOT|CLAUDE_CONFIG_DIR| \
        INFRA|RUNID|ISSUE|TIER|WORKTREE|BASE|ROUND|ATTEMPT|ROLE|NAME|MODEL|EFFORT| \
        ORCH|BACKEND|CHAIN|BRANCH|TASK|ROSTER|WRITABLE_ROOTS|RUNDIR|THREAD|CMD| \
        REVIEW_CMD|ENVS|EXTRA|ANSWER|ANSWER_SET|DRY|BASE_SHA|CODE|PROMPT|HANDOFF| \
        HANDOFF_BLOCK|PLAN_STEP|HANDOFF_STEP)
            die "--env name '$name' is reserved for the launcher"
            ;;
    esac
done
