#!/usr/bin/env bash
# One script, not two copies: spawn.sh and worker-resume.sh must refuse exactly the same
# inputs. Shell launch controls, Git routing/configuration, and infra-owned variables are
# reserved because exports also reach the unsandboxed wrapper and reviewer. No error may
# quote an environment value.

set -uo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --codex-policy NAME=VALUE... — print the codex `-c` values (one per line) that let a
# provisioned KEY/SECRET/TOKEN name through Codex's default shell-environment filter
# WITHOUT opening that filter for the rest of the inherited host environment: the
# defaults are switched off, and every other inherited name they matched is re-excluded
# by name. Prints nothing when no provisioned name needs it. Names only, never values.
secretish() { case "$1" in *[Kk][Ee][Yy]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Tt][Oo][Kk][Ee][Nn]*) return 0 ;; esac; return 1; }
if [ "${1:-}" = --codex-policy ]; then
    shift
    provisioned=" "; need=
    for pair in "$@"; do
        provisioned+="${pair%%=*} "
        secretish "${pair%%=*}" && need=1
    done
    [ -n "$need" ] || exit 0
    excl=
    while IFS= read -r name; do
        secretish "$name" || continue
        case "$provisioned" in *" $name "*) continue ;; esac
        excl+="${excl:+,}\"$name\""
    done < <(compgen -e)
    printf '%s\n' 'shell_environment_policy.ignore_default_excludes=true'
    [ -z "$excl" ] || printf 'shell_environment_policy.exclude=[%s]\n' "$excl"
    exit 0
fi

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
