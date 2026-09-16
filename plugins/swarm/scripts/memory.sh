#!/usr/bin/env bash
#
# memory.sh — scaffold .claude/swarm/memory/ from a project's roster.json
# (docs/swarm-design.md § Memory tiers). This is /init-swarm's Step 8, moved out of
# skill prose so it has a real test (same precedent as roster.sh).
#
# Usage:
#   bash memory.sh scaffold [project-dir]
#
#   project-dir   defaults to $PWD. Roster:      <project-dir>/.claude/swarm/roster.json
#                 Memory root: <project-dir>/.claude/swarm/memory
#
# Real wilcus-vault, literally `vault init --layout swarm --roster <roster> --vault
# <memory-root>`, runs when `vault` is on PATH AND its --help output names
# `--layout swarm`. A bare `command -v vault` alone would also match HashiCorp Vault,
# a common tool sharing this binary name, and blindly running our init flags against
# a different CLI risks a confusing failure at best and acting for real against an
# unrelated Vault server at worst. Anything that fails this check is treated as
# vault-absent: the same shared/, roles/<role>/, proposals/<role>/ directories are
# made by hand, for every role whose kind is manager or doer, with no
# .vault-policy.json — only vault writes one.
#
# Recovery: vault init refuses a directory that already exists, is non-empty, and has
# no .vault-policy.json of its own (wilcus-vault's cli/init.py, by design — it will
# not silently re-scope an unrelated directory). That is exactly what a previous
# fallback run leaves. If that tree holds no file anywhere (the fallback only ever
# mkdir's, never writes a file), it is safe to clear and let vault init recreate it
# for real. If it holds any file, this refuses and says so instead of guessing.
#
# Exit 0 on success. Exit 1 + "error: ..." on stderr on any usage mistake, a missing
# roster, or a pre-existing memory tree recovery cannot safely clear.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROSTER_SCRIPT="$SCRIPT_DIR/roster.sh"

usage() { echo "error: usage: memory.sh scaffold [project-dir]" >&2; exit 1; }

[ "${1:-}" = "scaffold" ] || usage
shift
[ $# -le 1 ] || usage
PROJECT_DIR="${1:-$PWD}"

ROSTER="$PROJECT_DIR/.claude/swarm/roster.json"
MEMORY="$PROJECT_DIR/.claude/swarm/memory"
POLICY="$MEMORY/.vault-policy.json"

[ -f "$ROSTER" ] || { echo "error: no roster at $ROSTER" >&2; exit 1; }

# A real wilcus-vault names its swarm layout in --help; nothing else on PATH under
# the name `vault` is expected to.
is_wilcus_vault() {
    command -v vault >/dev/null 2>&1 || return 1
    vault --help 2>&1 | grep -q -- "--layout swarm"
}

# Any entry that is not itself a directory (file, symlink, or otherwise) anywhere
# under $1 means real content is in there — never just fallback scaffolding.
has_any_file() {
    find "$1" -mindepth 1 ! -type d -print -quit 2>/dev/null | grep -q .
}

if is_wilcus_vault; then
    if [ -d "$MEMORY" ] && [ ! -e "$POLICY" ]; then
        if has_any_file "$MEMORY"; then
            echo "error: $MEMORY exists, has no .vault-policy.json, and already holds a file" \
                 "— resolve it by hand (vault init refuses a non-empty, unpolicied directory)" >&2
            exit 1
        fi
        find "$MEMORY" -depth -type d -exec rmdir {} +
        echo "cleared the empty plain-fallback tree at $MEMORY so vault init can adopt it"
    fi
    exec vault init --layout swarm --roster "$ROSTER" --vault "$MEMORY"
fi

OWNERS="$( { bash "$ROSTER_SCRIPT" list manager "$PROJECT_DIR" && bash "$ROSTER_SCRIPT" list doer "$PROJECT_DIR"; } 2>/dev/null)" \
    || { echo "error: roster.sh could not read $ROSTER" >&2; exit 1; }

echo "vault not on PATH — wrote the plain directory layout, no policy file (install wilcus-vault to add scoping)"
mkdir -p "$MEMORY/shared"
while IFS= read -r role; do
    [ -n "$role" ] || continue
    mkdir -p "$MEMORY/roles/$role" "$MEMORY/proposals/$role"
done <<< "$OWNERS"
