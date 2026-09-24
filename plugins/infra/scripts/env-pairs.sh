#!/usr/bin/env bash
# One script, not two copies: spawn.sh and worker-resume.sh must refuse exactly the same
# inputs. Shell launch controls, Git routing/configuration, and infra-owned variables are
# reserved because exports also reach the unsandboxed wrapper and reviewer. No error may
# quote an environment value.

set -uo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --codex-policy DIR NAME=VALUE... — print the codex `-c` values (one per line) that let
# a provisioned KEY/SECRET/TOKEN name through Codex's default shell-environment filter
# WITHOUT opening that filter for the rest of the host environment: the defaults are
# switched off, and every other name they matched is re-excluded by name — inherited
# names (awk's ENVIRON also lists names that are not identifiers, which compgen -e skips)
# and names Codex loads itself from $CODEX_HOME/.env. `-c ...exclude` may outrank an
# exclude list or `filters` setting in user, system, managed or project Codex config, so that case is refused
# instead. Prints nothing when no provisioned name needs it. Names only, never values.
secretish() { case "$1" in *[Kk][Ee][Yy]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Tt][Oo][Kk][Ee][Nn]*) return 0 ;; esac; return 1; }
if [ "${1:-}" = --codex-policy ]; then
    dir="${2:-}"; shift 2
    provisioned=" "; need=
    for pair in "$@"; do
        provisioned+="${pair%%=*} "
        secretish "${pair%%=*}" && need=1
    done
    [ -n "$need" ] || exit 0
    codex_home="${CODEX_HOME:-${HOME:-/nonexistent}/.codex}"
    etc_dir="${CODEX_ETC_ROOT:-/etc/codex}"
    # ponytail: any `exclude =` or `filters =` line counts, in any table — over-refuses rather than parse TOML.
    for cfg in "$codex_home/config.toml" "$etc_dir/config.toml" \
        "$etc_dir/managed_config.toml" "$dir/.codex/config.toml"; do
        [ -f "$cfg" ] && grep -Eq '(^|[[:space:],{.])(exclude|filters)[[:space:]]*=' "$cfg" \
            && die "$cfg sets shell_environment_policy.exclude or .filters, which a KEY/SECRET/TOKEN --env name would override; rename the variable or drop that setting"
    done
    excl=
    while IFS= read -r name; do
        secretish "$name" || continue
        case "$provisioned" in *" $name "*) continue ;; esac
        case "$name" in *[[:cntrl:]]*) die "an inherited KEY/SECRET/TOKEN name contains a control character" ;; esac
        name="${name//\\/\\\\}"; name="${name//\"/\\\"}"
        case ",$excl," in *",\"$name\","*) continue ;; esac
        excl+="${excl:+,}\"$name\""
    done < <(awk 'BEGIN { for (k in ENVIRON) print k }'
             [ -f "$codex_home/.env" ] && sed -nE \
                 's/^[[:space:]]*(export[[:space:]]+)?([^#=[:space:]]+)[[:space:]]*=.*/\2/p' \
                 "$codex_home/.env")
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
        GH_CONFIG_DIR|XDG_CONFIG_HOME|CODEX_HOME|CODEX_RUN_ROOT|CODEX_ETC_ROOT|CLAUDE_CONFIG_DIR| \
        INFRA|RUNID|ISSUE|TIER|WORKTREE|BASE|ROUND|ATTEMPT|ROLE|NAME|MODEL|EFFORT| \
        ORCH|BACKEND|CHAIN|BRANCH|TASK|ROSTER|WRITABLE_ROOTS|RUNDIR|THREAD|CMD| \
        REVIEW_CMD|ENVS|EXTRA|ANSWER|ANSWER_SET|DRY|BASE_SHA|CODE|PROMPT|HANDOFF| \
        HANDOFF_BLOCK|PLAN_STEP|HANDOFF_STEP)
            die "--env name '$name' is reserved for the launcher"
            ;;
    esac
done
